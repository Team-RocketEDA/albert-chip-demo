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
// Transform note: tile hookup (QKV part-selects, resid taps) is copied
// verbatim from loop_mem_seq's structural children; the loop's X+1 stub
// counter and ping-pong banks are gone, inter-layer buses replace them.
// Demo-slice caveat: only inproj_tile takes W-file params today, so all
// 30 macros bind the layer-0 goldens until the --emit-verilog step binds
// per-layer tables to outproj/ffn (which are SRAM-banked inside).
// Known open items carried over from the loop design, NOT solved here:
// outproj 3-slice (2x256+64) concat and ln1 requant width — the top bench
// stays structural smoke until those close.
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
  parameter WD_FILE = "weights/bake/layer0_down_proj.hex"
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

  // QKV packed frame from inproj, split exactly as the loop wired u_attn.
  wire [S*(H+2*KV)*8-1:0] p0_y;
  wire                    p_valid;
  wire [S*H*8-1:0]        attn_y;
  wire                    attn_valid;
  wire [S*C*8-1:0]        p1_slice;
  wire                    p1_valid;
  wire [S*H*8-1:0]        ffn_y;
  wire                    ffn_valid;

  inproj_tile #(
    .S(S), .H(H), .KV(KV),
    .WQ_FILE(WQ_FILE), .WK_FILE(WK_FILE), .WV_FILE(WV_FILE)
  ) u_p0 (
    .clk(clk), .rst_n(rst_n), .tok_in(x_in),
    .tok_valid(x_valid),
    .cfg_scale(16'd256), .cfg_zero(16'd0),
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

  outproj_tile #(.S(S), .H(H), .C(C)) u_p1 (
    .clk(clk), .rst_n(rst_n), .z_in(attn_y),
    .z_valid(attn_valid),
    .z_ready(), .slice_out(p1_slice), .slice_valid(p1_valid)
  );

  // Slice-concat open item (see header): the FFN leg runs on x_in until
  // the concat closes, mirroring the loop's stub maturity.
  ffn_tile #(.S(S), .H(H), .FF(FF)) u_ffn (
    .clk(clk), .rst_n(rst_n), .x_in(x_in),
    .x_valid(p1_valid),
    .start(x_valid), .x_ready(),
    .y_out(ffn_y), .y_valid(ffn_valid), .done()
  );

  rmsnorm_stage #(.S(S), .H(H)) u_ln2 (
    .clk(clk), .rst_n(rst_n), .x_in(ffn_y), .resid_in(attn_y),
    .in_valid(ffn_valid), .in_ready(), .y_out(x_out),
    .y_valid(y_valid)
  );
endmodule
