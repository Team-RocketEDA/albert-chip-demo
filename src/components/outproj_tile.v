// outproj_tile — L1 stitch (logic, proxy): Z[Sx576]s8 -> slice [SxC]s8.
// Contract: architecture/blocks/04-outproj-tile.md (MobileLLM decoder
// out-proj, column-split, digital concat MUX, no cross-tile adder tree).
// Math per element: slice[s][j] = clip8(dot(Z[s], Wrow[j])) over K=H with
// mod-2^32 wrap inside mac_array and a unity requant (scale=256 = Q8.8
// x1.0, SHIFT=8, zero=0) — the same wrap/requant split as inproj_tile:
// the MAC folds the full 32-bit accumulator; requant never sees a
// truncated partial. Proxy unity scale: true per-use
// (act_scale*w_scale/out_scale) coefficients arrive with the parent coeff
// bank at integration — this tile has no cfg_scale/cfg_zero ports
// (frozen), so requant is wired x1.0 and the stitch tb checks
// clip8(psum) bit-exact.
// Datapath (own instances, inproj Stage-B pattern):
//   u_infifo (stop) -> row latch -> K-fold (P=32 passes) through u_mac
//   with acc_in fold via u_accum -> u_requant per output -> u_outfifo ->
//   slice_out; u_ctrl (seq_fsm) sequences IRQs, z_ready = fifo_rd & ~full.
// slice_valid is FRAMED: high iff a completed slice sits in u_outfifo
// (~empty), never the free-running requant valid (integration trap).
// Weight SRAM is one wide-row bank: 32 K-bytes per row at address
// j*(H/32)+p. H%32 tail lanes are zero-padded by the lane MUX below, so
// the loader needs no tail support. Multi-slice column concat
// (2x256+64-tail) happens across time-mux passes at the parent; inside
// this tile the "concat MUX" is the indexed slice assembly (inferred
// case/if on the column index).
module outproj_tile #(
  parameter S = 64,
  parameter H = 576,
  parameter C = 256
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*H*8-1:0] z_in,
  input  wire             z_valid,
  output wire             z_ready,
  output wire [S*C*8-1:0] slice_out,
  output wire             slice_valid
);
  // K chunks of P=32 lanes per dot (H=576 -> NP=18).
  localparam integer NP = (H + 31) / 32;

  localparam [3:0] ST_IDLE = 4'd0,
                   ST_FILL = 4'd1, // pop stale slice + latch fifo head
                   ST_CLR  = 4'd2,
                   ST_RD   = 4'd3, // absorb 1-cycle SRAM read latency
                   ST_MAC  = 4'd4,
                   ST_WB   = 4'd5, // write back mac result
                   ST_RQA  = 4'd6, // point requant read port
                   ST_RQB  = 4'd7, // requant samples full-width acc
                   ST_RQC  = 4'd8, // capture requanted byte
                   ST_DONE = 4'd9; // push completed slice
  reg [3:0] state;

  reg [7:0]  s_c;
  reg [15:0] j_c;
  reg [7:0]  p_c;
  reg [S*H*8-1:0] zrow_r;
  reg [S*C*8-1:0] slice_r;
  reg [$clog2(S*C)-1:0] arb_r;

  // SRAM row j*(H/32)+p; accum cell s*C+j. Both maxima fit by construction
  // (C*NP-1 and S*C-1).
  wire [$clog2(C*NP)-1:0] wra = j_c * NP + p_c;
  wire [$clog2(S*C)-1:0]  aw  = s_c * C + j_c;

  wire [S*H*8-1:0] infifo_rdata;
  wire infifo_full, infifo_empty, out_full, out_empty;

  // ---- combinational controls (inferred case) ----
  reg in_wr, in_rd, out_wr, out_rd, mac_ce, mac_clr, acc_we;
  always @(*) begin
    in_wr = 1'b0; in_rd = 1'b0;
    out_wr = 1'b0; out_rd = 1'b0;
    mac_ce = 1'b0; mac_clr = 1'b0; acc_we = 1'b0;
    case (state)
      ST_IDLE: begin in_wr = z_valid & ~infifo_full; in_rd = ~infifo_empty; end
      ST_FILL: out_rd = ~out_empty;
      ST_CLR:  mac_clr = 1'b1;
      ST_MAC:  mac_ce = 1'b1;
      ST_WB:   acc_we = 1'b1;
      ST_DONE: out_wr = ~out_full;
      default: begin end
    endcase
  end

  // ---- K-chunk lane MUX (inferred if/case on lane index) ----
  wire [255:0] wrow;
  wire [31:0]  acc_rda, acc_rdb;
  wire [31:0]  mac_acc;
  reg  [255:0] avec_c, bvec_c;
  integer li;
  always @(*) begin
    avec_c = 256'b0;
    bvec_c = 256'b0;
    for (li = 0; li < 32; li = li + 1)
      if (p_c * 32 + li < H) begin
        avec_c[li*8 +: 8] = zrow_r[((s_c * H + p_c * 32 + li) * 8) +: 8];
        bvec_c[li*8 +: 8] = wrow[li*8 +: 8];
      end
  end
  // Fold: first chunk starts from 0, later chunks fold the stored partial
  // (full 32-bit, wrap preserved exactly as in mac_array).
  wire [31:0] acc_fold = (p_c == 8'd0) ? 32'd0 : acc_rda;

  wire [7:0] rq_byte;
  wire       ctrl_rd;

  fifo_sync #(.W(S*H*8), .D(8)) u_infifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(z_in), .wr(in_wr), .rd(in_rd),
    .rdata(infifo_rdata), .full(infifo_full), .empty(infifo_empty)
  );
  sram_1r1w #(.W(256), .N(C*NP)) u_wsram (
    .clk(clk),
    .ra(wra), .wa({$clog2(C*NP){1'b0}}), .wdata(256'b0), .we(1'b0),
    .rdata(wrow)
  );
  mac_array #(.W(8), .P(32)) u_mac (
    .clk(clk), .rst_n(rst_n), .ce(mac_ce), .clr(mac_clr),
    .avec(avec_c), .bvec(bvec_c), .acc_in(acc_fold), .acc_out(mac_acc)
  );
  regfile_dp #(.W(32), .N(S*C)) u_accum (
    .clk(clk), .ra(aw), .rb(arb_r), .wa(aw), .wdata(mac_acc), .we(acc_we),
    .rda(acc_rda), .rdb(acc_rdb)
  );
  // Unity requant (x1.0 proxy): full-width acc in, clip to int8 out.
  requant #(.W(8)) u_requant (
    .clk(clk), .rst_n(rst_n), .acc_wide(acc_rdb),
    .scale(16'd256), .zero(16'd0), .act_int(rq_byte), .valid()
  );
  fifo_sync #(.W(S*C*8), .D(8)) u_outfifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(slice_r), .wr(out_wr), .rd(out_rd),
    .rdata(slice_out), .full(out_full), .empty(out_empty)
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(z_valid),
    .prefill(1'b1),
    .irq_tile_done(slice_valid), .irq_frame_done(1'b0),
    .phase_sel(), .layer_idx(), .cal_addr(),
    .fifo_lane_en_ilp(), .fifo_lane_en_olp(),
    .fifo_rd(ctrl_rd), .layer_done()
  );

  // Framed outputs: slice_valid iff a completed slice is buffered;
  // z_ready carries ctrl flow gated by input headroom (no overflow drop).
  assign slice_valid = ~out_empty;
  assign z_ready = ctrl_rd & ~infifo_full;

  // ---- sequencer (sync, async reset) ----
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= ST_IDLE;
      s_c <= 8'd0; j_c <= 16'd0; p_c <= 8'd0;
      zrow_r <= {S*H*8{1'b0}};
      slice_r <= {S*C*8{1'b0}};
      arb_r <= {$clog2(S*C){1'b0}};
    end else begin
      case (state)
        ST_IDLE: if (in_rd) begin
          zrow_r <= infifo_rdata;
          state <= ST_FILL;
        end
        ST_FILL: state <= ST_CLR;
        ST_CLR: begin
          s_c <= 8'd0; j_c <= 16'd0; p_c <= 8'd0;
          state <= ST_RD;
        end
        ST_RD: state <= ST_MAC;
        ST_MAC: state <= ST_WB;
        ST_WB: begin
          if (p_c + 8'd1 < NP) begin
            p_c <= p_c + 8'd1;
            state <= ST_RD;
          end else begin
            p_c <= 8'd0;
            state <= ST_RQA;
          end
        end
        ST_RQA: begin
          arb_r <= aw;
          state <= ST_RQB;
        end
        ST_RQB: state <= ST_RQC;
        ST_RQC: begin
          slice_r[((s_c * C + j_c) * 8) +: 8] <= rq_byte;
          if (j_c + 16'd1 < C) begin
            j_c <= j_c + 16'd1;
            state <= ST_RD;
          end else if (s_c + 8'd1 < S) begin
            j_c <= 16'd0;
            s_c <= s_c + 8'd1;
            state <= ST_RD;
          end else begin
            j_c <= 16'd0;
            s_c <= 8'd0;
            state <= ST_DONE;
          end
        end
        ST_DONE: if (!out_full) state <= ST_IDLE;
        default: state <= ST_IDLE;
      endcase
    end
  end
endmodule
