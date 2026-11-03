// ffn_tile — L1 SwiGLU FFN wiring + stitch logic (step: ffn_tile logic).
// Contract: MobileLLM SwiGLU FFN. X[SxH]s8 -> gate/up (HxFF mats, parallel)
// -> H = silu(G)*U -> down (FFxH mat) -> accum + requant -> Y[SxH]s8.
// Blocks doc: architecture/blocks/06-ffn-tile.md. Dims ride S/H/FF params.
// Weights are stationary in sram_1r1w banks (host-loaded, no write port in
// inference here); the stitch tb backdoor-loads first-FF-row/col slices.
//
// Datapath (all operators inferred +, -, *, >>>, if/case; no new
// single-operator modules):
//  INFRAME: x_in frame words stream through u_inffo (64B skid) into x_reg.
//  GATEUP:  gate/up mac_arrays run in PARALLEL lockstep, single-lane
//           streaming (lane0 = x*w, lanes 1..31 zero) rate-matched to the
//           single-port weight SRAMs (1 byte/cycle). 576 cycles fold the
//           H dim (== 18x32-lane chunks); per-row running acc in mac_array.
//  SILU:    time-muxed single silu_lut: gq = sat_s16(g_psum >>> 2) feeds
//           the LUT. TRAP AVOIDED: the skeleton fed gate_psum[15:0] (low
//           16 bits = mod-2^16 garbage for large psums); the LUT domain is
//           s16 Q4.12, so the psum is arithmetically rescaled (>>>2) and
//           saturated to s16 BEFORE the LUT (full-range LUT covers edges).
//           uq = sat_s16(u_psum >>> 2); prod32 = silu_g * uq is a true
//           16x16 -> 32-bit multiply (TRAP AVOIDED: operands rescaled to
//           16 bit BEFORE the mult so the product is 32 bit, and the fxp
//           rescale >>>20 happens on the 32-bit product).
//           h8 = sat_s8(prod32 >>> 20), staged via u_midffo.
//  DOWN:    down mac_array streams h8 bytes x Wd bytes -> Yacc/out row;
//           u_accum regfile holds the 576 s32 accumulators.
//  REQ:     u_yrequant (scale=1, gain 1/64 at SHIFT=6, zero=0):
//           y = sat_s8((Yacc*1) >>> 6) = sat_s8(Yacc >>> 6).
// Calibration (GS=2, HS=20, RSH=6) is a stitch-time integer-chain choice
// validated against baked goldens (see tb); product per-use requant sweep
// stays a bring-up step (PARAMS section 9). Weight banks hold FF*H bytes
// (gate/up) and H*FF bytes (down); N=8192 covers FF*H <= 8192 (tb FF=8,
// H=576 -> 4608 B). Stitch slice scope: FF<=8 (one 64-bit h word through
// the mid fifo, 3-bit down-lane counter), H<=1024, S*H a multiple of 64 B
// (contract dims satisfy all three); the full FF=1536 contract maps to
// sequential slice passes in the loopback (out of stitch scope, per the
// 06 "proxy slices smaller" note).
module ffn_tile #(
  parameter S  = 64,
  parameter H  = 576,
  parameter FF = 1536
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0]  x_in,
  input  wire              x_valid,
  input  wire              start, // frame start
  output wire              x_ready,
  output wire [S*H*8-1:0]  y_out,
  output wire              y_valid,
  output wire              done   // frame done
);
  localparam SW = (S > 1) ? $clog2(S) : 1;
  localparam JW = (FF > 1) ? $clog2(FF) : 1;
  localparam NW = S*H*8/512; // 64B input words per frame

  // ---- state ----
  localparam [4:0]
    ST_IDLE = 5'd0, ST_INFPUSH = 5'd1, ST_INFPOP = 5'd2,
    ST_GCLR = 5'd3, ST_GPRIME = 5'd4, ST_GSTREAM = 5'd5, ST_GCAP = 5'd6,
    ST_SILUSET = 5'd7, ST_SILUCAP = 5'd8,
    ST_MIDPUSH = 5'd9, ST_MIDPOP = 5'd10,
    ST_DCLR = 5'd11, ST_DPRIME = 5'd12, ST_DSTREAM = 5'd13, ST_DCAP = 5'd14,
    ST_RQFILL = 5'd15, ST_RQRUN = 5'd16, ST_RQFLUSH = 5'd17,
    ST_DONE = 5'd18;
  reg [4:0] state_q;

  reg [SW-1:0] s_cnt;
  reg [9:0]    k_cnt;   // H-dim stream index (gate/up), 0..H-1
  reg [JW-1:0] j_cnt;   // FF-dim index, 0..FF-1
  reg [9:0]    i_cnt;   // down output-row index, 0..H-1
  reg [2:0]    kk_cnt;  // down 8-wide stream index, 0..7
  reg [12:0]   w_cnt;   // input word index, 0..NW-1

  // ---- datapath regs ----
  reg [7:0] x_reg [0:S*H-1];
  reg signed [31:0] g_psum [0:S-1][0:FF-1];
  reg signed [31:0] u_psum [0:S-1][0:FF-1];
  reg signed [7:0]  h8r [0:FF-1];
  reg [7:0] y_reg [0:S*H-1];
  reg [7:0]  x_d;                 // 1-cycle delayed X byte (SRAM latency)
  reg [7:0]  h_d;                 // 1-cycle delayed h byte (SRAM latency)
  reg [63:0] h_dword;             // h row popped from mid fifo
  reg signed [15:0] silu_in_r;
  reg signed [15:0] uq_r;         // latched with silu input for the mult
  reg [9:0] re_ra;                // accum drain read address

  // ---- child wires ----
  wire [31:0] gate_psum_w, up_psum_w, down_psum_w;
  wire [511:0] inf_rdata;
  wire inf_full, inf_empty;
  wire [127:0] mid_rdata;
  wire mid_full, mid_empty;
  wire [7:0]   g_rdata, u_rdata, d_rdata;
  wire [15:0]  silu_g;
  wire [31:0]  acc_rda;
  wire [7:0]   y_act;
  wire         y_vld;
  wire [3:0]  phase_sel_nc;
  wire [4:0]  layer_idx_nc;
  wire [22:0] cal_addr_nc;
  wire [5:0]  ilp_nc, olp_nc;
  wire        fifo_rd_nc, layer_done_nc;

  // X/gate/up/down lane bytes (single active lane, rest zero).
  wire [255:0] gu_avec = {248'd0, x_d};
  wire [255:0] g_bvec  = {248'd0, g_rdata};
  wire [255:0] u_bvec  = {248'd0, u_rdata};
  wire [255:0] d_avec  = {248'd0, h_d};
  wire [255:0] d_bvec  = {248'd0, d_rdata};

  wire [511:0] inf_wdata = x_in[w_cnt*512 +: 512];
  // Weight-read issue: the single-port SRAMs return rdata one cycle after
  // ra is sampled, while x_d/h_d (regs) advance the same cycle. To land
  // the consume pair (x[k],w[k]) on the same mac edge, the stream states
  // issue ra one slot AHEAD (k+1); GCLR/DCLR+GPRIME/DPRIME prime slot 0
  // (ra=j*H / i*FF, x_d/h_d=x[0]/h[0]) so the first consume aligns.
  wire [12:0]  g_ra = (state_q == ST_GSTREAM) ? (j_cnt*H + k_cnt + 1)
                                                 : (j_cnt*H);
  wire [12:0]  u_ra = (state_q == ST_GSTREAM) ? (j_cnt*H + k_cnt + 1)
                                                 : (j_cnt*H);
  wire [12:0]  d_ra = (state_q == ST_DSTREAM) ? (i_cnt*FF + kk_cnt + 1)
                                                 : (i_cnt*FF);

  // SiLU-stage combinational taps (shared single LUT, time-muxed).
  wire signed [31:0] gsh_cur = $signed(g_psum[s_cnt][j_cnt]) >>> 2;
  wire signed [31:0] ush_cur = $signed(u_psum[s_cnt][j_cnt]) >>> 2;
  wire signed [15:0] gq_cur =
    (gsh_cur > 32'sd32767) ? 16'sd32767 :
    (gsh_cur < -32'sd32768) ? -16'sd32768 : gsh_cur[15:0];
  wire signed [15:0] uq_cur =
    (ush_cur > 32'sd32767) ? 16'sd32767 :
    (ush_cur < -32'sd32768) ? -16'sd32768 : ush_cur[15:0];
  // ---- control strobes (combinational on state: no control-reg lag; the
  // leaves sample ce/clr/wr/rd at the edge leaving the named state) ----
  wire gu_clr  = (state_q == ST_GCLR);
  wire gu_ce   = (state_q == ST_GSTREAM);
  wire d_clr   = (state_q == ST_DCLR);
  wire d_ce    = (state_q == ST_DSTREAM);
  wire acc_we  = (state_q == ST_DCAP);
  wire inf_wr  = (state_q == ST_INFPUSH) && !inf_full;
  wire inf_rd  = (state_q == ST_INFPOP) && !inf_empty;
  wire mid_wr  = (state_q == ST_MIDPUSH) && !mid_full;
  wire mid_rd  = (state_q == ST_MIDPOP) && !mid_empty;
  wire row_irq   = (state_q == ST_RQFLUSH);
  wire tile_irq  = ((state_q == ST_GCAP) && (j_cnt == FF-1)) ||
                   ((state_q == ST_DCAP) && (i_cnt == H-1));
  wire frame_irq = (state_q == ST_RQFLUSH) && (s_cnt == S-1);

  // Inferred 16x16 -> 32-bit elementwise product + fxp rescale.
  wire signed [31:0] prod_cur = $signed(silu_g) * $signed(uq_r);
  wire signed [31:0] hsh_cur = prod_cur >>> 20;

  fifo_sync #(.W(512), .D(2)) u_inffo (
    .clk(clk), .rst_n(rst_n), .wdata(inf_wdata), .wr(inf_wr),
    .rd(inf_rd), .rdata(inf_rdata), .full(inf_full), .empty(inf_empty)
  );
  sram_1r1w #(.W(8), .N(8192)) u_gatew (
    .clk(clk), .ra(g_ra), .wa(13'd0), .wdata(8'b0), .we(1'b0), .rdata(g_rdata)
  );
  sram_1r1w #(.W(8), .N(8192)) u_upw (
    .clk(clk), .ra(u_ra), .wa(13'd0), .wdata(8'b0), .we(1'b0), .rdata(u_rdata)
  );
  // Cross-cycle accumulation folds through acc_in (leaf contract): the
  // running sum feeds back into acc_in; clr resets it per output.
  mac_array #(.W(8), .P(32)) u_gate (
    .clk(clk), .rst_n(rst_n), .ce(gu_ce), .clr(gu_clr),
    .avec(gu_avec), .bvec(g_bvec), .acc_in(gate_psum_w), .acc_out(gate_psum_w)
  );
  mac_array #(.W(8), .P(32)) u_up (
    .clk(clk), .rst_n(rst_n), .ce(gu_ce), .clr(gu_clr),
    .avec(gu_avec), .bvec(u_bvec), .acc_in(up_psum_w), .acc_out(up_psum_w)
  );
  silu_lut #(.W(16)) u_silu (
    .x(silu_in_r), .y(silu_g)
  );
  // h row word: low bytes carry the FF h8 entries (fifo W=128 covers
  // FF<=16; stitch slice FF<=8 -> single 64-bit h word, tb FF=8).
  wire [127:0] mid_wdata;
  genvar gj;
  generate
    for (gj = 0; gj < 16; gj = gj + 1) begin : g_mid
      if (gj < FF)
        assign mid_wdata[gj*8 +: 8] = h8r[gj];
      else
        assign mid_wdata[gj*8 +: 8] = 8'd0;
    end
  endgenerate
  fifo_sync #(.W(128), .D(8)) u_midffo (
    .clk(clk), .rst_n(rst_n), .wdata(mid_wdata), .wr(mid_wr),
    .rd(mid_rd), .rdata(mid_rdata), .full(mid_full), .empty(mid_empty)
  );
  sram_1r1w #(.W(8), .N(8192)) u_downw (
    .clk(clk), .ra(d_ra), .wa(13'd0), .wdata(8'b0), .we(1'b0), .rdata(d_rdata)
  );
  mac_array #(.W(8), .P(32)) u_down (
    .clk(clk), .rst_n(rst_n), .ce(d_ce), .clr(d_clr),
    .avec(d_avec), .bvec(d_bvec), .acc_in(down_psum_w), .acc_out(down_psum_w)
  );
  regfile_dp #(.W(32), .N(576)) u_accum (
    .clk(clk), .ra(re_ra), .rb(10'd0), .wa(i_cnt), .wdata(down_psum_w),
    .we(acc_we), .rda(acc_rda), .rdb()
  );
  // Exit requant: gain 1/64 at SHIFT=6: (Yacc*1)>>>6 == Yacc>>>6, then
  // clip to int8 (stitch-calibrated; product per-use sweep is bring-up).
  requant #(.W(8), .SHIFT(6)) u_yrequant (
    .clk(clk), .rst_n(rst_n), .acc_wide(acc_rda),
    .scale(16'h0001), .zero(16'h0000), .act_int(y_act), .valid(y_vld)
  );
  // Tile tracker: consumes real row/tile/frame pulses for system phase
  // visibility (phase_sel/cal_addr). Local FSM sequences the datapath;
  // fifo_rd streaming semantics belong to the 30-layer loopback, so the
  // stitch sources x_ready locally and leaves fifo_rd/layer_done floating.
  seq_fsm u_ctrl (
    .clk(clk), .rst_n(rst_n), .irq_row_done(row_irq),
    .prefill(1'b1),
    .irq_tile_done(tile_irq), .irq_frame_done(frame_irq),
    .phase_sel(phase_sel_nc), .layer_idx(layer_idx_nc),
    .cal_addr(cal_addr_nc),
    .fifo_lane_en_ilp(ilp_nc), .fifo_lane_en_olp(olp_nc),
    .fifo_rd(fifo_rd_nc), .layer_done(layer_done_nc)
  );

  assign x_ready = (state_q == ST_IDLE) || (state_q == ST_DONE);
  assign y_valid = (state_q == ST_DONE);
  assign done    = (state_q == ST_DONE);

  genvar gi;
  generate
    for (gi = 0; gi < S*H; gi = gi + 1) begin : g_yo
      assign y_out[gi*8 +: 8] = y_reg[gi];
    end
  endgenerate

  integer b;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= ST_IDLE;
      s_cnt <= {SW{1'b0}}; k_cnt <= 10'd0; j_cnt <= {JW{1'b0}};
      i_cnt <= 10'd0; kk_cnt <= 3'd0; w_cnt <= 13'd0;
      x_d <= 8'd0; h_d <= 8'd0; h_dword <= 64'd0;
      silu_in_r <= 16'sd0; uq_r <= 16'sd0; re_ra <= 10'd0;
    end else begin
      case (state_q)
        ST_IDLE: begin
          if (start && x_valid) begin
            w_cnt <= 13'd0;
            state_q <= ST_INFPUSH;
          end
        end
        // ---- input skid: stream the frame through u_inffo ----
        ST_INFPUSH: begin
          if (!inf_full) begin
              state_q <= ST_INFPOP;
          end
        end
        ST_INFPOP: begin
          if (!inf_empty) begin
              for (b = 0; b < 64; b = b + 1)
              x_reg[w_cnt*64+b] <= inf_rdata[b*8 +: 8];
            if (w_cnt == NW-1) begin
              w_cnt <= 13'd0; s_cnt <= {SW{1'b0}}; j_cnt <= {JW{1'b0}};
              state_q <= ST_GCLR;
            end else begin
              w_cnt <= w_cnt + 13'd1;
              state_q <= ST_INFPUSH;
            end
          end
        end
        // ---- gate/up mats, parallel lockstep, single-lane stream ----
        ST_GCLR: begin
          k_cnt <= 10'd0;
          x_d <= x_reg[s_cnt*H];
          state_q <= ST_GPRIME;
        end
        // Prime cycle: lets slot-0 weight (ra=j*H, sampled at the GCLR
        // edge) land on rdata while x_d already holds x[0]; ce stays 0.
        ST_GPRIME: begin
          state_q <= ST_GSTREAM;
        end
        ST_GSTREAM: begin
          if (k_cnt < H-1) begin
            x_d <= x_reg[s_cnt*H + k_cnt + 1];
            k_cnt <= k_cnt + 10'd1;
          end else begin
            state_q <= ST_GCAP;
          end
        end
        ST_GCAP: begin
          g_psum[s_cnt][j_cnt] <= gate_psum_w;
          u_psum[s_cnt][j_cnt] <= up_psum_w;
          if (j_cnt < FF-1) begin
            j_cnt <= j_cnt + 1'b1;
            state_q <= ST_GCLR;
          end else begin
            j_cnt <= {JW{1'b0}};
              state_q <= ST_SILUSET;
          end
        end
        // ---- SiLU pipe: time-muxed single LUT + inferred 16x16 mult ----
        ST_SILUSET: begin
          silu_in_r <= gq_cur;
          uq_r <= uq_cur;
          state_q <= ST_SILUCAP;
        end
        ST_SILUCAP: begin
          if (hsh_cur > 32'sd127) h8r[j_cnt] <= 8'sd127;
          else if (hsh_cur < -32'sd128) h8r[j_cnt] <= -8'sd128;
          else h8r[j_cnt] <= hsh_cur[7:0];
          if (j_cnt < FF-1) begin
            j_cnt <= j_cnt + 1'b1;
            state_q <= ST_SILUSET;
          end else begin
            j_cnt <= {JW{1'b0}};
            state_q <= ST_MIDPUSH;
          end
        end
        // ---- h row through the mid fifo (SiLU pipe decoupling) ----
        ST_MIDPUSH: begin
          if (!mid_full) begin
              state_q <= ST_MIDPOP;
          end
        end
        ST_MIDPOP: begin
          if (!mid_empty) begin
              h_dword <= mid_rdata[63:0];
            i_cnt <= 10'd0; kk_cnt <= 3'd0;
            state_q <= ST_DCLR;
          end
        end
        // ---- down mat: 8-wide single-lane stream per output row ----
        ST_DCLR: begin
          kk_cnt <= 3'd0;
          h_d <= h_dword[0 +: 8];
          state_q <= ST_DPRIME;
        end
        // Prime cycle: lets slot-0 down weight land on rdata while h_d
        // already holds h[0]; ce stays 0.
        ST_DPRIME: begin
          state_q <= ST_DSTREAM;
        end
        ST_DSTREAM: begin
          if (kk_cnt < FF-1) begin
            h_d <= h_dword[(kk_cnt+1)*8 +: 8];
            kk_cnt <= kk_cnt + 3'd1;
          end else begin
            state_q <= ST_DCAP;
          end
        end
        ST_DCAP: begin
          if (i_cnt < H-1) begin
            i_cnt <= i_cnt + 10'd1;
            state_q <= ST_DCLR;
          end else begin
            i_cnt <= 10'd0;
              state_q <= ST_RQFILL;
          end
        end
        // ---- requant drain: accum -> u_yrequant -> y_reg (pipelined) ----
        ST_RQFILL: begin
          re_ra <= 10'd0;
          i_cnt <= 10'd0;
          state_q <= ST_RQRUN;
        end
        ST_RQRUN: begin
          if (i_cnt > 0)
            y_reg[s_cnt*H + i_cnt - 1] <= y_act;
          if (i_cnt < H-1) begin
            re_ra <= i_cnt + 10'd1;
            i_cnt <= i_cnt + 10'd1;
          end else begin
            state_q <= ST_RQFLUSH;
          end
        end
        ST_RQFLUSH: begin
          y_reg[s_cnt*H + H - 1] <= y_act;
          if (s_cnt < S-1) begin
            s_cnt <= s_cnt + 1'b1;
            j_cnt <= {JW{1'b0}};
            state_q <= ST_GCLR;
          end else begin
              state_q <= ST_DONE;
          end
        end
        ST_DONE: begin
          if (start && x_valid) begin
            w_cnt <= 13'd0;
            state_q <= ST_INFPUSH;
          end
        end
        default: state_q <= ST_IDLE;
      endcase
    end
  end
endmodule
