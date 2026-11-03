// decoder_etched_stack — 30-deep etched decoder chain.
//
// Stitch-only top: x_in -> layer0 -> ... -> layer29 -> x_out.
// Each stage is one layer_etched macro with LAYER tied to its index.
// All seven W-file slots keep the layer0 golden tables (per the
// layer_etched header, per-layer tables for outproj/ffn bind later).
// Frame-valid ripples down the y_valid -> x_valid links; the head
// macro drives the top x_ready, the tail macro drives x_out/y_valid.
// This file holds wires, generate blocks, and macro hooks only.
module decoder_etched_stack #(
  parameter S = 64,
  parameter H = 576,
  parameter KV = 192,
  parameter FF = 1536
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*H*8-1:0] x_in,
  input  wire             x_valid,
  output wire             x_ready,
  output wire [S*H*8-1:0] x_out,
  output wire             y_valid
);

  // Inter-macro links: d[k] feeds macro k+1 from macro k, vld[k] is
  // the frame-valid out of macro k. Edge macros touch the top ports.
  wire [S*H*8-1:0] d [0:28];
  wire [29:0]      vld;

  genvar i;
  generate
    for (i = 0; i < 30; i = i + 1) begin : g_layer
      if (i == 0) begin : g_first
        layer_etched #(
          .S(S), .H(H), .KV(KV), .FF(FF),
          .LAYER(i),
          .WQ_FILE("weights/bake/layer0_q_proj.hex"),
          .WK_FILE("weights/bake/layer0_k_proj.hex"),
          .WV_FILE("weights/bake/layer0_v_proj.hex"),
          .WO_FILE("weights/bake/layer0_o_proj.hex"),
          .WG_FILE("weights/bake/layer0_gate_proj.hex"),
          .WU_FILE("weights/bake/layer0_up_proj.hex"),
          .WD_FILE("weights/bake/layer0_down_proj.hex")
        ) u_layer (
          .clk(clk), .rst_n(rst_n),
          .x_in(x_in), .x_valid(x_valid), .x_ready(x_ready),
          .x_out(d[0]), .y_valid(vld[0])
        );
      end else if (i == 29) begin : g_last
        layer_etched #(
          .S(S), .H(H), .KV(KV), .FF(FF),
          .LAYER(i),
          .WQ_FILE("weights/bake/layer0_q_proj.hex"),
          .WK_FILE("weights/bake/layer0_k_proj.hex"),
          .WV_FILE("weights/bake/layer0_v_proj.hex"),
          .WO_FILE("weights/bake/layer0_o_proj.hex"),
          .WG_FILE("weights/bake/layer0_gate_proj.hex"),
          .WU_FILE("weights/bake/layer0_up_proj.hex"),
          .WD_FILE("weights/bake/layer0_down_proj.hex")
        ) u_layer (
          .clk(clk), .rst_n(rst_n),
          .x_in(d[28]), .x_valid(vld[28]), .x_ready(),
          .x_out(x_out), .y_valid(y_valid)
        );
      end else begin : g_mid
        layer_etched #(
          .S(S), .H(H), .KV(KV), .FF(FF),
          .LAYER(i),
          .WQ_FILE("weights/bake/layer0_q_proj.hex"),
          .WK_FILE("weights/bake/layer0_k_proj.hex"),
          .WV_FILE("weights/bake/layer0_v_proj.hex"),
          .WO_FILE("weights/bake/layer0_o_proj.hex"),
          .WG_FILE("weights/bake/layer0_gate_proj.hex"),
          .WU_FILE("weights/bake/layer0_up_proj.hex"),
          .WD_FILE("weights/bake/layer0_down_proj.hex")
        ) u_layer (
          .clk(clk), .rst_n(rst_n),
          .x_in(d[i-1]), .x_valid(vld[i-1]), .x_ready(),
          .x_out(d[i]), .y_valid(vld[i])
        );
      end
    end
  endgenerate
endmodule
