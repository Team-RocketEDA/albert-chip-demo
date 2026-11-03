// loop_mem_seq — L1 stitch (Stage H): 30x decoder-layer loopback.
// Contract: architecture/blocks/08-loop-mem-seq.md + 09-interface.md +
// plans/full-model-stitch-plan.md Stage H. Frame order per layer
// p0->ATTN->p1->RMS1->p2->SILU->p3->RMS2->LOOPBACK (locked, 09-interface);
// phases never overlap (tile_sel one-hot from seq_fsm); almost_full ->
// FSM stall, never a weight fetch (theta_req tied 0: weights stationary).
//
// What this file owns: xbank ping-pong (bankA_p/bankB_p + sel), resid
// snapshot (resid_p: X_l tap for the RMS1 leg; attn_y feeds the RMS2 leg),
// layer/phase sequencing via u_layerseq (seq_fsm: 4 tile-IRQs per layer,
// layer advance exactly on the LOOPBACK pulse, layer_done at l==29),
// per-layer frame step X(l+1) = X(l)+1 per byte (wrap), x_out = X_30 with
// single-cycle x_out_valid, busy-window backpressure on x_in_ready.
//
// Stub-tier note (protocol first): the MAC tiles (u_p0/u_attn/u_p1/u_ffn)
// are sibling-owned stubs whose outputs still float. They are wired with
// real frames + phase strobes (valid/ready activity is live) but the
// loopback datapath does NOT sample their outputs: the +1 step stands in
// for the full layer math until the real tiles land, at which point the
// LOOPBACK tap swaps to the RMS2/narrowed frame. Determinism check
// (loop layer-0 tables twice -> identical out) holds by construction.
// Inferred +,-,* and if/case only; no single-operator modules.
module loop_mem_seq #(
  parameter S  = 64,
  parameter H  = 576,
  parameter FF = 1536,
  parameter C  = 256
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0]  x_in,
  input  wire              x_in_valid,
  input  wire [3:0]        tag_in,      // stream tag (carried, unused)
  output wire              x_in_ready,
  output wire [S*H*8-1:0]  x_out,
  output wire              x_out_valid,
  output wire [4:0]        layer_idx,   // l=0..29
  output wire              layer_done,
  // phase-decoder fanout + top-port handshakes
  output wire [3:0]        tile_sel,
  output wire [5:0]        fifo_lane_en_ilp,
  output wire [5:0]        fifo_lane_en_olp,
  output wire              theta_req,   // to parent store
  input  wire              theta_ack,
  input  wire [576*32-1:0] sw_result_in, // SW-leg re-entry (576xacc)
  input  wire              recal_trig   // periodic coeff rotation
);
  localparam integer N = S * H;

  // ---- FSM: one single-cycle state per pipeline leg + LOAD/DONE/HOLD ----
  localparam [3:0] ST_IDLE = 4'd0,
                   ST_LOAD = 4'd1,
                   ST_P0   = 4'd2,
                   ST_ATTN = 4'd3,
                   ST_P1   = 4'd4,
                   ST_RMS1 = 4'd5,
                   ST_P2   = 4'd6,
                   ST_SILU = 4'd7,
                   ST_P3   = 4'd8,
                   ST_RMS2 = 4'd9,
                   ST_LB   = 4'd10,
                   ST_DONE = 4'd11,
                   ST_HOLD = 4'd12;

  reg [3:0] state;
  reg       sel;            // xbank ping-pong selector
  reg [S*H*8-1:0] bankA_p; // ping frame store (packed)
  reg [S*H*8-1:0] bankB_p; // pong frame store (packed)
  reg [S*H*8-1:0] resid_p; // X_l snapshot: RMS1 leg tap
  reg [S*H*8-1:0] cur_p;   // current layer frame
  reg [S*H*8-1:0] x_out_r; // X_30 hold register
  reg             valid_r; // single-cycle strobe
  reg [31:0]      stall_cnt; // diagnostic: cycles blocked by almost_full
  reg [1023:0]    ilp_chunk; // ILP traffic chunk (128B, X-free pad)
  reg [4095:0]    olp_chunk; // OLP traffic chunk (512B, X-free pad)

  // ---- almost_full -> FSM stall (09-interface trap) ----
  // Packed lane buses (plain-Verilog elab-gate clean, no net arrays).
  wire [5:0] ilp_full, ilp_empty, olp_full, olp_empty;
  wire [6*1024-1:0] ilp_rdata_all;
  wire [6*4096-1:0] olp_rdata_all;
  wire stall = (|ilp_full) | (|olp_full);

  // ---- tile IRQs into the layer sequencer ----
  // 4 tile-IRQs per layer at the end of ATTN/RMS1/SILU/LOOPBACK so the
  // MAC-phase sub-states observe p0/p1/p2/p3 exactly; the LOOPBACK pulse
  // (phase p3) advances the layer, freezing layer_idx==29 + DONE at l==29.
  wire in_phase   = (state == ST_P0)   || (state == ST_ATTN) ||
                    (state == ST_P1)   || (state == ST_RMS1) ||
                    (state == ST_P2)   || (state == ST_SILU) ||
                    (state == ST_P3)   || (state == ST_RMS2) ||
                    (state == ST_LB);
  wire tile_irq   = (state == ST_ATTN) || (state == ST_RMS1) ||
                    (state == ST_SILU) || (state == ST_LB);
  wire row_irq    = in_phase;
  wire tile_irq_g = tile_irq & ~stall;
  wire row_irq_g  = row_irq & ~stall;

  wire seq_fifo_rd;
  assign x_in_ready  = (state == ST_IDLE) & seq_fifo_rd & ~stall;
  assign x_out       = x_out_r;
  assign x_out_valid = valid_r;
  // Weight-stationary: banks host-loaded once; the loop never fetches.
  assign theta_req   = 1'b0;

  wire [S*(H+384)*8-1:0] p0_y;
  wire [S*H*8-1:0] attn_y;
  wire [S*C*8-1:0] p1_slice;
  wire [S*H*16-1:0] ln1_y;
  wire [7:0]       ln1_b0;
  wire [S*H*8-1:0] p3_y;
  wire p_valid;
  wire [3:0]  phase;
  wire [22:0] coeff_addr;
  // ---- next-state (stall freezes everything; IRQs already gated) ----
  reg [3:0] nxt_state;
  always @* begin
    nxt_state = state;
    if (!stall) begin
      case (state)
        ST_IDLE: if (x_in_valid) nxt_state = ST_LOAD;
        ST_LOAD: nxt_state = ST_P0;
        ST_P0:   nxt_state = ST_ATTN;
        ST_ATTN: nxt_state = ST_P1;
        ST_P1:   nxt_state = ST_RMS1;
        ST_RMS1: nxt_state = ST_P2;
        ST_P2:   nxt_state = ST_SILU;
        ST_SILU: nxt_state = ST_P3;
        ST_P3:   nxt_state = ST_RMS2;
        ST_RMS2: nxt_state = ST_LB;
        ST_LB:   nxt_state = (layer_idx == 5'd29) ? ST_DONE : ST_P0;
        ST_DONE: nxt_state = ST_HOLD;
        ST_HOLD: nxt_state = ST_HOLD;
        default: nxt_state = ST_IDLE;
      endcase
    end
  end

  integer n;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state     <= ST_IDLE;
      sel       <= 1'b0;
      bankA_p   <= {S*H*8{1'b0}};
      bankB_p   <= {S*H*8{1'b0}};
      resid_p   <= {S*H*8{1'b0}};
      cur_p     <= {S*H*8{1'b0}};
      x_out_r   <= {S*H*8{1'b0}};
      valid_r   <= 1'b0;
      stall_cnt <= 32'd0;
      ilp_chunk <= 1024'b0;
      olp_chunk <= 4096'b0;
    end else begin
      valid_r <= 1'b0; // single-cycle strobe default
      if (stall) begin
        stall_cnt <= stall_cnt + 32'd1;
      end else begin
        state <= nxt_state;
        case (state)
          ST_IDLE: begin
            if (x_in_valid) begin
              bankA_p <= x_in;
              resid_p <= x_in;
              cur_p   <= x_in;
              sel     <= 1'b0;
              for (n = 0; n < 128; n = n + 1)
                ilp_chunk[n*8 +: 8] <= (n < N) ? x_in[n*8 +: 8] : 8'b0;
              for (n = 0; n < 512; n = n + 1)
                olp_chunk[n*8 +: 8] <= (n < N) ? x_in[n*8 +: 8] : 8'b0;
            end
          end
          ST_LB: begin
            // X(l+1) = X(l)+1 per byte (wrap): stub for the full
            // Layer(Xl) math; resid add folds into the +1 step until
            // the real tiles land on the LOOPBACK tap.
            for (n = 0; n < N; n = n + 1) begin
              if (sel == 1'b0)
                bankB_p[n*8 +: 8] <= cur_p[n*8 +: 8] + 8'd1;
              else
                bankA_p[n*8 +: 8] <= cur_p[n*8 +: 8] + 8'd1;
            end
            for (n = 0; n < 128; n = n + 1)
              ilp_chunk[n*8 +: 8] <= (n < N) ? cur_p[n*8 +: 8] + 8'd1 : 8'b0;
            for (n = 0; n < 512; n = n + 1)
              olp_chunk[n*8 +: 8] <= (n < N) ? cur_p[n*8 +: 8] + 8'd1 : 8'b0;
            resid_p <= cur_p; // X_l snapshot for the next RMS1 leg
            for (n = 0; n < N; n = n + 1)
              cur_p[n*8 +: 8] <= cur_p[n*8 +: 8] + 8'd1;
            sel <= ~sel;
          end
          ST_DONE: begin
            x_out_r <= cur_p; // X_30
            valid_r <= 1'b1;
          end
          default: begin end
        endcase
      end
    end
  end

  // ---- structural children (ports/topology contract) ----
  sram_1r1w #(.W(8), .N(36864)) u_xbank ( // S*H frame bytes, S=64/H=576
    .clk(clk), .ra({11'b0, layer_idx}), .wa(16'd0), .wdata(8'b0),
    .we(1'b0), .rdata()
  );
  sram_1r1w #(.W(16), .N(368640)) u_wcal ( // 720KB: 30 uses x 24KB/use
    .clk(clk), .ra(coeff_addr[18:0]), .wa(19'd0), .wdata(16'b0),
    .we(1'b0), .rdata()
  );
  // 6 ILP + 6 OLP lanes, DEPTH 8 (chunk-group drain at implementation).
  // Lane 0 carries live chunk traffic (wr at P0/P3, rd at ATTN/RMS2);
  // lanes 1..5 idle-empty companions proving the fabric.
  genvar g;
  generate
    for (g = 0; g < 6; g = g + 1) begin : ilp_lanes
      fifo_sync #(.W(1024), .D(8)) u_lane (
        .clk(clk), .rst_n(rst_n),
        .wdata(ilp_chunk), .wr(g == 0 && state == ST_P0 && !stall),
        .rd(g == 0 && state == ST_ATTN && !stall),
        .rdata(ilp_rdata_all[g*1024 +: 1024]),
        .full(ilp_full[g]), .empty(ilp_empty[g])
      );
    end
    for (g = 0; g < 6; g = g + 1) begin : olp_lanes
      fifo_sync #(.W(4096), .D(8)) u_lane (
        .clk(clk), .rst_n(rst_n),
        .wdata(olp_chunk), .wr(g == 0 && state == ST_P3 && !stall),
        .rd(g == 0 && state == ST_RMS2 && !stall),
        .rdata(olp_rdata_all[g*4096 +: 4096]),
        .full(olp_full[g]), .empty(olp_empty[g])
      );
    end
  endgenerate
  inproj_tile #(.S(S), .H(H)) u_p0 (
    .clk(clk), .rst_n(rst_n), .tok_in(cur_p),
    .tok_valid(state == ST_P0 && !stall),
    .cfg_scale(16'd256), .cfg_zero(16'd0),
    .tok_ready(), .y_out(p0_y), .y_valid(p_valid)
  );
  attention_core #(.S(S), .H(H)) u_attn (
    .clk(clk), .rst_n(rst_n),
    .q_in(p0_y[S*H*8-1:0]), .k_in(p0_y[S*H*8+S*192*8-1:S*H*8]),
    .v_in(p0_y[S*(H+384)*8-1:S*(H+192)*8]),
    .qkv_valid(state == ST_ATTN && !stall), .s_cfg(7'd64), .qkv_ready(),
    .y_out(attn_y), .y_valid()
  );
  outproj_tile #(.S(S), .H(H)) u_p1 (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y),
    .z_valid(state == ST_P1 && !stall),
    .z_ready(), .slice_out(p1_slice), .slice_valid()
  );
  rmsnorm_stage #(.S(S), .H(H)) u_ln1 (
    .clk(clk), .rst_n(rst_n), .x_in(cur_p), .resid_in(resid_p),
    .in_valid(state == ST_RMS1 && !stall), .in_ready(), .y_out(ln1_y),
    .y_valid()
  );
  requant #(.W(8)) u_ln1rq (
    .clk(clk), .rst_n(rst_n), .acc_wide(ln1_y[31:0]),
    .scale(16'b0), .zero(16'b0), .act_int(ln1_b0), .valid()
  );
  ffn_tile #(.S(S), .H(H), .FF(FF)) u_ffn (
    .clk(clk), .rst_n(rst_n), .x_in(cur_p),
    .x_valid(state == ST_P2 && !stall),
    .start(state == ST_P0 && !stall), .x_ready(),
    .y_out(p3_y), .y_valid(), .done()
  );
  rmsnorm_stage #(.S(S), .H(H)) u_ln2 (
    .clk(clk), .rst_n(rst_n), .x_in(p3_y), .resid_in(attn_y),
    .in_valid(state == ST_RMS2 && !stall), .in_ready(), .y_out(),
    .y_valid()
  );
  seq_fsm u_layerseq (
    .clk(clk), .rst_n(rst_n), .irq_row_done(row_irq_g),
    .prefill(1'b1),
    .irq_tile_done(tile_irq_g), .irq_frame_done(1'b0),
    .phase_sel(tile_sel), .layer_idx(layer_idx), .cal_addr(coeff_addr),
    .fifo_lane_en_ilp(fifo_lane_en_ilp),
    .fifo_lane_en_olp(fifo_lane_en_olp),
    .fifo_rd(seq_fifo_rd), .layer_done(layer_done)
  );
  seq_fsm u_recalseq (
    .clk(clk), .rst_n(rst_n), .irq_row_done(recal_trig),
    .prefill(1'b1),
    .irq_tile_done(1'b0), .irq_frame_done(layer_done),
    .phase_sel(phase), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(), .layer_done()
  );
  irq_sync u_irq (
    .clk(clk), .irq_async(recal_trig), .irq()
  );
  // mcu_if: hardwired into u_layerseq; golden C in firmware/mcu_fw.c.
  // theta_req/ack + sw_result_in terminate at integration (parent store /
  // SW-leg re-entry); overflow parked.
endmodule
