// inproj_tile — L1 wiring + chunk-fold engine (02-inproj-tile.md).
//
// Parent I/O: tok[Sx576]s8 -> y_out[Sx960]s8 packed Q[576]+K[192]+V[192].
// One tile time-muxes the 576-col input in C=256 chunks (2x256 + 64-tail);
// K/V thirds are the same pass, sliced per OLP lane for the ATTN handoff.
//
// Datapath (children are the frozen topology; this file adds the wiring and
// the inferred chunk-fold control — only +,-,*,if/case, no new modules):
//   tok -> u_infifo (4608b single-row skid) -> row latch
//        -> u_mac P=32 K-fold (18 passes of 32 over K=576) with acc_in fold
//           (hold_q feeds back; 32-bit wrap mod-2^32, never saturates here)
//        -> u_accum (960x32s, cleared per row) holds exact s32 psums
//        -> u_requant per output with (cfg_scale,cfg_zero): saturation lives
//           HERE only: y = clip_int8((acc*scale)>>8 + zero)
//        -> packed y_out thirds; u_outfifo carries the low 4096b slice as
//           the OLP skid; u_ctrl sequences chunks (its fifo_rd gates
//           tok_ready; phase/layer/cal/lane taps stay cabled for backend).
// No bias anywhere (MobileLLM dense mats ship none): accum feeds requant
// direct. Weights: host-pinned image (WQ/WK/WV_FILE, repo-root-relative
// $readmemh) models the stationary w_sram bank contents for sim; u_wsram
// stays instantiated as the 4KB tile bank footprint (host-loaded, we=0 in
// inference; INDEX bank map: Q 81 tiles / K,V 27 tiles of 4096 B).
// y_valid pulses exactly one cycle per packed frame (per packed row when S=1).
module inproj_tile #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  parameter C = 256,
  parameter WQ_FILE = "weights/bake/layer0_q_proj.hex",
  parameter WK_FILE = "weights/bake/layer0_k_proj.hex",
  parameter WV_FILE = "weights/bake/layer0_v_proj.hex"
)(
  input  wire                clk,
  input  wire                rst_n,
  input  wire [S*H*8-1:0]    tok_in,
  input  wire                tok_valid,
  input  wire [15:0]         cfg_scale, // per-chunk requant scale (Q8.8)
  input  wire [15:0]         cfg_zero,  // per-chunk requant zero
  output wire                tok_ready,
  output wire [S*(H+2*KV)*8-1:0] y_out,
  output wire                y_valid
);
  localparam NO = H + 2*KV;          // 960 packed outputs per row
  localparam NF = (H + 32 - 1) / 32; // 18 K-folds of P=32 over K=576

  // ---- pinned weight image (stationary W sim proxy, row-major) ----
  reg [7:0] wq_img [0:H*H-1];
  reg [7:0] wk_img [0:KV*H-1];
  reg [7:0] wv_img [0:KV*H-1];
  initial begin
    $readmemh(WQ_FILE, wq_img);
    $readmemh(WK_FILE, wk_img);
    $readmemh(WV_FILE, wv_img);
  end

  // ---- engine state ----
  localparam ST_IDLE = 4'd0, ST_POPW = 4'd1, ST_POPC = 4'd2,
             ST_MSET = 4'd3, ST_MCAP = 4'd4, ST_AWR = 4'd5,
             ST_RSET = 4'd6, ST_RSAMP = 4'd7, ST_RCAP = 4'd8,
             ST_DONE = 4'd9;
  reg [3:0] state_q;
  reg [7:0] row_q;    // token row 0..S-1
  reg [9:0] j_q;      // packed output 0..959
  reg [4:0] f_q;      // K-fold 0..17
  reg [31:0] hold_q;  // acc_in fold register (wraps mod-2^32)
  reg [7:0] xbuf_q [0:S*H-1]; // latched frame rows
  reg [7:0] xrow_q [0:H-1];   // current row under the K-fold
  reg [S*NO*8-1:0] y_out_q;
  reg y_valid_q;
  // mac ce/clr are COMBINATIONAL (not regs): the mac samples avec/bvec/
  // acc_in at posedges, so ce must be high DURING each MSET fold cycle and
  // clr during the single POPC/row-advance cycle that precedes the next
  // MSET. Registered versions arrive one cycle late, which silently drops
  // every odd K-fold (proven: accum held only even folds).
  // Row-advance clear: RCAP last-lane of a non-final row (S>1 path).
  wire mac_ce  = (state_q == ST_MSET);
  wire mac_clr = (state_q == ST_POPC) ||
                 (state_q == ST_RCAP && j_q == NO-1 && row_q != S-1);
  reg [9:0] acc_ra_q, acc_wa_q;
  reg [31:0] acc_wdata_q;
  reg acc_we_q;
  reg inf_wr_q, inf_rd_q, out_wr_q;
  reg [255:0] mac_avec_q, mac_bvec_q; // K-fold lane mux (drives u_mac)
  reg [7:0] wb; // weight byte select

  assign y_out = y_out_q;
  assign y_valid = y_valid_q;

  // ---- child interconnect ----
  wire [4607:0] inf_rdata;
  wire inf_full, inf_empty;
  wire [31:0] mac_psum;
  wire [31:0] acc_rda, acc_rdb;
  wire [7:0] req_byte;
  wire req_valid_unused;
  wire [4095:0] out_rdata;
  wire out_full, out_empty;
  wire [7:0] wsram_rdata_unused;
  wire [3:0] phase_unused;
  wire [4:0] layer_unused;
  wire [22:0] cal_unused;
  wire [5:0] ilp_unused, olp_unused, ctrl_rd_w;
  wire ctrl_done_unused;

  fifo_sync #(.W(4608), .D(8)) u_infifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(tok_in[4607:0]), .wr(inf_wr_q),
    .rd(inf_rd_q), .rdata(inf_rdata),
    .full(inf_full), .empty(inf_empty)
  );
  // Stationary tile bank footprint: host-loaded, no write port in inference.
  sram_1r1w #(.W(8), .N(4096)) u_wsram (
    .clk(clk), .ra(), .wa(), .wdata(8'b0), .we(1'b0),
    .rdata(wsram_rdata_unused)
  );
  mac_array #(.W(8), .P(32)) u_mac (
    .clk(clk), .rst_n(rst_n), .ce(mac_ce), .clr(mac_clr),
    .avec(mac_avec_q), .bvec(mac_bvec_q), .acc_in(hold_q),
    .acc_out(mac_psum)
  );
  regfile_dp #(.W(32), .N(960)) u_accum (
    .clk(clk), .ra(acc_ra_q), .rb(10'd0),
    .wa(acc_wa_q), .wdata(acc_wdata_q), .we(acc_we_q),
    .rda(acc_rda), .rdb(acc_rdb)
  );
  // No bias: psum flows direct into requant; saturation lives here only.
  requant #(.W(8)) u_requant (
    .clk(clk), .rst_n(rst_n), .acc_wide(acc_rda),
    .scale(cfg_scale), .zero(cfg_zero),
    .act_int(req_byte), .valid(req_valid_unused)
  );
  fifo_sync #(.W(4096), .D(8)) u_outfifo (
    .clk(clk), .rst_n(rst_n),
    .wdata(y_out_q[4095:0]), .wr(out_wr_q),
    .rd(1'b0), .rdata(out_rdata), .full(out_full), .empty(out_empty)
  );
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(tok_valid),
    .prefill(1'b1),
    .irq_tile_done(y_valid_q), .irq_frame_done(1'b0),
    .phase_sel(phase_unused), .layer_idx(layer_unused),
    .cal_addr(cal_unused),
    .fifo_lane_en_ilp(ilp_unused), .fifo_lane_en_olp(olp_unused),
    .fifo_rd(ctrl_rd_w[0]), .layer_done(ctrl_done_unused)
  );
  assign ctrl_rd_w[5:1] = 5'b0;
  assign tok_ready = ctrl_rd_w[0] & (state_q == ST_IDLE);

  // ---- K-fold lane mux (inferred if/case over the stationary image) ----
  integer p;
  always @(*) begin
    mac_avec_q = 256'b0;
    mac_bvec_q = 256'b0;
    for (p = 0; p < 32; p = p + 1) begin
      mac_avec_q[p*8 +: 8] = xrow_q[f_q*32+p];
      if (j_q < H)
        wb = wq_img[j_q*H+f_q*32+p];
      else if (j_q < H+KV)
        wb = wk_img[(j_q-H)*H+f_q*32+p];
      else
        wb = wv_img[(j_q-H-KV)*H+f_q*32+p];
      mac_bvec_q[p*8 +: 8] = wb;
    end
  end

  // ---- chunk-fold sequencer ----
  integer b, r;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      row_q <= 8'd0; j_q <= 10'd0; f_q <= 5'd0;
      hold_q <= 32'd0;
      y_out_q <= {S*NO*8{1'b0}};
      y_valid_q <= 1'b0;
      acc_ra_q <= 10'd0; acc_wa_q <= 10'd0;
      acc_wdata_q <= 32'd0; acc_we_q <= 1'b0;
      inf_wr_q <= 1'b0; inf_rd_q <= 1'b0; out_wr_q <= 1'b0;
    end else begin
      acc_we_q <= 1'b0;
      inf_wr_q <= 1'b0; inf_rd_q <= 1'b0; out_wr_q <= 1'b0;
      y_valid_q <= 1'b0;
      case (state_q)
        ST_IDLE: begin
          if (tok_valid) begin
            inf_wr_q <= 1'b1; // skid the first row slice
            row_q <= 8'd0;
            state_q <= ST_POPW;
          end
        end
        // POPW: the IDLE-issued push lands in u_infifo at this edge; raise
        // rd so the FWFT head (our row) is stable through the next cycle.
        ST_POPW: begin
          inf_rd_q <= 1'b1;
          state_q <= ST_POPC;
        end
        // POPC: capture the skid head (row 0) + tok_in rows; the pop takes
        // effect at this edge, so pre-edge rdata is still our row.
        ST_POPC: begin
          hold_q <= 32'd0; j_q <= 10'd0; f_q <= 5'd0;
          for (b = 0; b < H; b = b + 1)
            xrow_q[b] <= inf_rdata[b*8 +: 8];
          for (r = 0; r < S; r = r + 1)
            for (b = 0; b < H; b = b + 1)
              xbuf_q[r*H+b] <= (r == 0)
                ? inf_rdata[b*8 +: 8]
                : tok_in[(r*H+b)*8 +: 8];
          state_q <= ST_MSET;
        end
        ST_MSET: begin
          // mac samples avec/bvec/acc_in=hold at the MSET->MCAP edge;
          // ce is combinational (high throughout MSET), clr in POPC.
          state_q <= ST_MCAP;
        end
        ST_MCAP: begin
          hold_q <= mac_psum; // fold captured (mod-2^32, no saturation)
          if (f_q == NF-1)
            state_q <= ST_AWR;
          else begin
            f_q <= f_q + 5'd1;
            state_q <= ST_MSET;
          end
        end
        ST_AWR: begin
          acc_wa_q <= j_q; acc_wdata_q <= hold_q; acc_we_q <= 1'b1;
          hold_q <= 32'd0; // fresh fold chain for the next output
          f_q <= 5'd0;
          if (j_q == NO-1) begin
            j_q <= 10'd0;
            state_q <= ST_RSET;
          end else begin
            j_q <= j_q + 10'd1;
            state_q <= ST_MSET;
          end
        end
        ST_RSET: begin
          acc_ra_q <= j_q; // rda settles combinationally into requant
          state_q <= ST_RSAMP;
        end
        ST_RSAMP: begin
          state_q <= ST_RCAP; // requant samples acc at this edge
        end
        ST_RCAP: begin
          y_out_q[(row_q*NO+j_q)*8 +: 8] <= req_byte; // packed thirds byte
          if (j_q == NO-1) begin
            if (row_q == S-1) begin
              state_q <= ST_DONE;
            end else begin
              row_q <= row_q + 8'd1;
              for (b = 0; b < H; b = b + 1)
                xrow_q[b] <= xbuf_q[(row_q+1)*H+b];
              hold_q <= 32'd0; j_q <= 10'd0; f_q <= 5'd0;
              state_q <= ST_MSET;
            end
          end else begin
            j_q <= j_q + 10'd1;
            state_q <= ST_RSET;
          end
        end
        ST_DONE: begin
          y_valid_q <= 1'b1; // exactly one cycle per packed frame
          out_wr_q <= 1'b1;
          state_q <= ST_IDLE;
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end
endmodule
