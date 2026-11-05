// layer_etched — one UNROLLED decoder-layer macro with baked weights.
//
// NO LOOPBACK: the top instantiates 30 of these in a direct n -> n+1
// etched array (layer_idx carried as the LAYER parameter, not a runtime
// counter). Each macro declares exactly how many weights it holds:
//
//   Q    576x576   = 331,776  (WQ_FILE)
//   K    192x576   = 110,592  (WK_FILE)
//   V    192x576   = 110,592  (WV_FILE)
//   O    576x576   = 331,776  (WO_FILE, bound at emit time)
//   GATE 1536x576  = 884,736  (WG_FILE, bound at emit time)
//   UP   1536x576  = 884,736  (WU_FILE, bound at emit time)
//   DOWN 576x1536  = 884,736  (WD_FILE, bound at emit time)
//   per-layer dense total = 3,538,944 INT8 bytes (+ 2x576 norms).
//
// Model graph (MobileLLM pre-norm, cf. the finetuned checkpoint):
//   xr   = Rs(x)                         (u_rs: s_out(L-1) -> s_R(L))
//   h    = RMSNorm(xr, input_ln)         (u_ln0, GN1)
//   qkv  = inproj(h)                     (u_p0, SC_QKV)
//   a    = O(proj(attn(qkv)))            (u_attn + 3 outproj slices, SC_O)
//   r1   = xr + a                        (sat8, both in s_R units)
//   f    = RMSNorm(r1, post_attn_ln)     (u_ln1, GN2)
//   m    = FFN(f)                        (u_ffn, calibrated G/U/P/RQ)
//   r2   = r1 + m                        (sat8; x_out, NO third norm —
//                                        the model applies model.norm once
//                                        after all 30 layers)
// Static-quant scale discipline (see weights/bake/calibrate.py): norms
// erase upstream scale, so only the two residual adds need matched
// scales; calibration constrains s_O == s_D == s_R(layer) with
// s_R(0) = s_embed and s_O(L) = s_R(L-1). All (MUL,SH) points are
// compile-time params (constant-folded, ~free in synthesis); defaults
// reproduce the legacy stitch-time behavior.
//
// Transform note: tile hookup (QKV part-selects, resid taps) is copied
// verbatim from loop_mem_seq's structural children; the loop's X+1 stub
// counter and ping-pong banks are gone, inter-layer buses replace them.
// All weight tables bind here (emit_layers.py fixes per-layer files).
module layer_etched #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  parameter FF = 1536,
  parameter C = 256,
  parameter LAYER = 0,
  parameter WQ_FILE = "weights/bake/layer0_q_proj.hex",
  parameter WK_FILE = "weights/bake/layer0_k_proj.hex",
  parameter WV_FILE = "weights/bake/layer0_v_proj.hex",
  parameter WO_FILE = "weights/bake/layer0_o_proj.hex",
  parameter WG_FILE = "weights/bake/layer0_gate_proj.hex",
  parameter WU_FILE = "weights/bake/layer0_up_proj.hex",
  parameter WD_FILE = "weights/bake/layer0_down_proj.hex",
  parameter WQ_WIDE_FILE = "weights/bake/layer0_q_proj_w32.hex",
  parameter WK_WIDE_FILE = "weights/bake/layer0_k_proj_w32.hex",
  parameter WV_WIDE_FILE = "weights/bake/layer0_v_proj_w32.hex",
  parameter WO_WIDE_FILE = "weights/bake/layer0_o_proj_w32.hex",
  parameter GN1_FILE = "weights/bake/layer0_input_layernorm_q88.hex",
  parameter GN2_FILE = "weights/bake/layer0_post_attention_layernorm_q88.hex",
  // Static-quant scale points (calibrate.py emits per-layer values).
  // inproj/outproj requant: y = clip((acc*MUL) >>> SH). Defaults keep
  // the legacy x1.0 (256,8) chain.
  parameter [15:0] SC_QKVM = 16'd256,
  parameter [4:0]  SC_QKVSH = 5'd8,
  parameter [15:0] SC_OM = 16'd256,
  parameter [4:0]  SC_OSH = 5'd8,
  // FFN scale points (see ffn_tile): defaults keep the legacy chain.
  parameter [15:0] G_MUL = 16'd1,
  parameter [4:0]  G_SH  = 5'd2,
  parameter [15:0] U_MUL = 16'd1,
  parameter [4:0]  U_SH  = 5'd2,
  parameter [15:0] P_MUL = 16'd1,
  parameter [4:0]  P_SH  = 5'd20,
  parameter [15:0] RQ_MUL = 16'd1,
  parameter [4:0]  RQ_SH  = 5'd6,
  // Norm re-entry domain: yq = clip((y*1) >>> YQ_SHIFT). Default 8
  // keeps stitch behavior; etched layers use 4 (x16, 4 frac bits).
  parameter [4:0] YQ_SHIFT = 5'd8,
  // Entry rescale: x arrives in s_out(L-1) units, resid adds run in
  // s_R(L). RS = s_out(L-1)/s_R(L); L0 default (256,8) = identity
  // (embed is re-baked at s_R(0), so s_out(-1) = s_R(0)).
  parameter [15:0] RS_MUL = 16'd256,
  parameter [4:0]  RS_SH  = 5'd8
)(
  input  wire              clk,
  input  wire              rst_n,
  input  wire [S*H*8-1:0]  x_in,
  input  wire              x_valid,
  output wire              x_ready,
  output wire [S*H*8-1:0]  x_out,
  output wire              y_valid
);
  // Backpressure is an open item (tiles self-sequence on valid); the
  // macro accepts every frame. See the header caveat.
  assign x_ready = 1'b1;

  // Entry rescale + pre-attention norm: xr = Rs(x) in s_R(L) units,
  // h = RMSNorm(xr, input_ln). in_valid edges the parent frame pulse
  // (rmsnorm re-arms on level); yq_valid is sticky exactly like the old
  // inter-layer valid, so inproj's protocol is unchanged (it previously
  // ate the previous layer's ln2 yq_valid).
  wire [S*H*8-1:0] xr;
  rescale #(.MUL(RS_MUL), .SH(RS_SH), .N(S*H)) u_rs (
    .x(x_in), .y(xr)
  );
  reg x_valid_d;
  wire ln0_start = x_valid & ~x_valid_d;
  wire [S*H*8-1:0] n0_out;
  wire             n0_valid;
  rmsnorm_stage #(.S(S), .H(H), .GN_FILE(GN1_FILE), .YQ_SHIFT(YQ_SHIFT)) u_ln0 (
    .clk(clk), .rst_n(rst_n), .x_in(xr),
    .resid_in({S*H*8{1'b0}}), .in_valid(ln0_start),
    .in_ready(), .y_out(), .y_valid(),
    .yq_out(n0_out), .yq_valid(n0_valid)
  );

  // QKV packed frame from inproj, split exactly as the loop wired u_attn.
  wire [S*(H+2*KV)*8-1:0] p0_y;
  wire                    p_valid;
  wire [S*H*8-1:0]        attn_y;
  wire                    attn_valid;

  // Inproj re-fires on valid LEVEL (it re-arms to IDLE while the
  // upstream frame is still held), so edge ln0's sticky yq_valid into
  // a 1-cycle frame pulse — same pulse shape the old tb-driven port had.
  reg n0_valid_d;
  wire p0_start = n0_valid & ~n0_valid_d;
  inproj_tile #(
    .S(S), .H(H), .KV(KV),
    .WQ_FILE(WQ_FILE), .WK_FILE(WK_FILE), .WV_FILE(WV_FILE),
    .WQ_WIDE_FILE(WQ_WIDE_FILE), .WK_WIDE_FILE(WK_WIDE_FILE),
    .WV_WIDE_FILE(WV_WIDE_FILE),
    .QKV_SH(SC_QKVSH)
  ) u_p0 (
    .clk(clk), .rst_n(rst_n), .tok_in(n0_out),
    .tok_valid(p0_start),
    .cfg_scale(SC_QKVM), .cfg_zero(16'd0),
    .tok_ready(), .y_out(p0_y), .y_valid(p_valid)
  );

  attention_core #(.S(S), .H(H), .KV(KV)) u_attn (
    .clk(clk), .rst_n(rst_n),
    .q_in(p0_y[S*H*8-1:0]),
    .k_in(p0_y[S*H*8+S*192*8-1:S*H*8]),
    .v_in(p0_y[S*(H+384)*8-1:S*(H+192)*8]),
    .qkv_valid(p_valid), .s_cfg(7'd64), .qkv_ready(),
    .y_out(attn_y), .y_valid(attn_valid)
  );

  // Saturating int8 residual add (inferred +/compare; this module is
  // wiring + closeout arithmetic, same class as its existing assigns).
  function [7:0] sat8add(input [7:0] a, input [7:0] b);
    integer s;
    begin
      s = $signed(a) + $signed(b);
      if (s > 127) sat8add = 8'h7f;
      else if (s < -128) sat8add = 8'h80;
      else sat8add = s[7:0];
    end
  endfunction

  // Outproj spans the full 576 via 3 slices (256+256+64-tail); the parent
  // concatenates LSB-first to the monolithic frame.
  wire [S*256*8-1:0] o_a, o_b;
  wire [S*64*8-1:0]  o_c;
  wire               va, vb, vc;
  outproj_tile #(.S(S), .H(H), .C(256), .O_OFF(0), .WO_FILE(WO_FILE),
    .WO_WIDE_FILE(WO_WIDE_FILE), .O_SH(SC_OSH)) u_p1a (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y), .z_valid(attn_valid),
    .cfg_scale(SC_OM), .cfg_zero(16'd0),
    .z_ready(), .slice_out(o_a), .slice_valid(va)
  );
  outproj_tile #(.S(S), .H(H), .C(256), .O_OFF(256), .WO_FILE(WO_FILE),
    .WO_WIDE_FILE(WO_WIDE_FILE), .O_SH(SC_OSH)) u_p1b (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y), .z_valid(attn_valid),
    .cfg_scale(SC_OM), .cfg_zero(16'd0),
    .z_ready(), .slice_out(o_b), .slice_valid(vb)
  );
  outproj_tile #(.S(S), .H(H), .C(64), .O_OFF(512), .WO_FILE(WO_FILE),
    .WO_WIDE_FILE(WO_WIDE_FILE), .O_SH(SC_OSH)) u_p1c (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y), .z_valid(attn_valid),
    .cfg_scale(SC_OM), .cfg_zero(16'd0),
    .z_ready(), .slice_out(o_c), .slice_valid(vc)
  );
  wire [S*H*8-1:0] o_full;
  assign o_full = {o_c, o_b, o_a};
  wire o_valid = va & vb & vc;

  // Resid 1: r1 = xr + a (model graph; both in s_R(L) units —
  // xr is the rescaled entry, o_full targets s_R via SC_O).
  wire [S*H*8-1:0] o_res1;
  wire [S*H*8-1:0] ffn_in;
  wire             ffn_inv;
  genvar gr1;
  generate
    for (gr1 = 0; gr1 < S*H; gr1 = gr1 + 1) begin : g_res1
      assign o_res1[gr1*8 +: 8] = sat8add(xr[gr1*8 +: 8], o_full[gr1*8 +: 8]);
    end
  endgenerate
  // Frame-start pulse for ln1/ffn (o_start). Downstream valids are
  // framed (sticky), so edge them into 1-cycle starts (tiles re-arm on
  // level, would re-fire). The ffn_start sampler sits after the ffn
  // wires below — iverilog needs declaration before use.
  reg o_valid_d;
  wire o_start = o_valid & ~o_valid_d;
  // Post-attention norm: f = RMSNorm(r1, post_attn_ln).
  rmsnorm_stage #(.S(S), .H(H), .GN_FILE(GN2_FILE), .YQ_SHIFT(YQ_SHIFT)) u_ln1 (
    .clk(clk), .rst_n(rst_n), .x_in(o_res1),
    .resid_in({S*H*8{1'b0}}), .in_valid(o_start),
    .in_ready(), .y_out(), .y_valid(),
    .yq_out(ffn_in), .yq_valid(ffn_inv)
  );

  // FFN start rendezvous: o_start (outproj done) arrives ~1k cycles
  // before ln1's frame is ready, so latch it; fire ffn on the meet of
  // latched-outproj-done AND ln1-valid (fresh frame data guaranteed —
  // ffn_inv clears when ln1 re-arms). o_got clears at frame-done.
  reg o_got, meet_d;
  wire meet = o_got & ffn_inv;
  wire ffn_start = meet & ~meet_d;
  // FFN leg runs on ln1's frame (the x_in stub is closed).
  wire [S*H*8-1:0] ffn_y;
  wire             ffn_valid;
  reg ffn_valid_d;
  wire ln2_start = ffn_valid & ~ffn_valid_d;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_valid_d <= 1'b0;
      n0_valid_d <= 1'b0;
      o_valid_d <= 1'b0;
      ffn_valid_d <= 1'b0;
      o_got <= 1'b0;
      meet_d <= 1'b0;
    end else begin
      x_valid_d <= x_valid;
      n0_valid_d <= n0_valid;
      o_valid_d <= o_valid;
      ffn_valid_d <= ffn_valid;
      if (o_start) o_got <= 1'b1;
      else if (y_valid) o_got <= 1'b0;
      meet_d <= meet;
    end
  end
  ffn_tile #(.S(S), .H(H), .FF(FF),
    .WG_FILE(WG_FILE), .WU_FILE(WU_FILE), .WD_FILE(WD_FILE),
    .G_MUL(G_MUL), .G_SH(G_SH), .U_MUL(U_MUL), .U_SH(U_SH),
    .P_MUL(P_MUL), .P_SH(P_SH), .RQ_MUL(RQ_MUL), .RQ_SH(RQ_SH)) u_ffn (
    .clk(clk), .rst_n(rst_n), .x_in(ffn_in),
    .x_valid(ffn_inv),
    .start(ffn_start), .x_ready(),
    .y_out(ffn_y), .y_valid(ffn_valid), .done()
  );

  // Resid 2 + layer output: r2 = r1 + m (model graph, NO third norm —
  // the model applies model.norm once after all 30 layers). f_res is
  // combinational on the two held frames; capture it one cycle after
  // the ffn frame lands (ln2_s1) and raise the sticky frame valid one
  // cycle later (ln2_s2), mirroring the old ln2 yq_valid protocol
  // (sticky until the next frame starts).
  wire [S*H*8-1:0] f_res;
  genvar gr2;
  generate
    for (gr2 = 0; gr2 < S*H; gr2 = gr2 + 1) begin : g_res2
      assign f_res[gr2*8 +: 8] = sat8add(o_res1[gr2*8 +: 8], ffn_y[gr2*8 +: 8]);
    end
  endgenerate
  reg [S*H*8-1:0] x_out_r;
  reg             y_valid_r, ln2_s1, ln2_s2;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x_out_r <= {S*H*8{1'b0}};
      y_valid_r <= 1'b0;
      ln2_s1 <= 1'b0;
      ln2_s2 <= 1'b0;
    end else begin
      ln2_s1 <= ln2_start;
      ln2_s2 <= ln2_s1;
      if (ln2_s1) x_out_r <= f_res;
      if (ln2_start) y_valid_r <= 1'b0;
      else if (ln2_s2) y_valid_r <= 1'b1;
    end
  end
  assign x_out = x_out_r;
  assign y_valid = y_valid_r;
endmodule
