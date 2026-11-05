// tb_codec.sv — single-layer token codec bench (hardware token loop).
// ids -> embed_lut (full 32k table) -> layer0_etched (S=1, TRUE layer-0
// baked tables) -> lm_head (VROWS=32000, tied embed copy) -> pred id.
// The C++ driver loops tokens (chat-style) and reports cycles + tokens/s
// measured from the sim (25 ns clock). Single-layer proof: the numbers
// are MEASURED for one macro; full-stack cost projects x30 (labeled).
// Full 30-layer bound stack (emit_stack.py) is GDS-stitch territory;
// its overnight Verilator run is a user-side campaign, not this bench.
`timescale 1ns / 1ps
module tb_codec (
  input  wire          clk,
  input  wire          rst_n,
  input  wire [14:0]   token_id,
  input  wire          id_valid,
  output wire [14:0]   pred_out,
  output wire          pred_done
);
  wire [576*8-1:0] evec;
  // Calibrated tied table (per-tensor, scale s_R(0)): the layer input
  // must arrive in s_R(0) units, and the head reuses this copy (tied).
  embed_lut #(
    .E(576), .H(576), .V(32000),
    .INIT_FILE("weights/bake/embed_full_pt.packed.hex")
  ) u_emb (
    .clk(clk), .token_id(token_id), .vec(evec)
  );

  wire [1*576*8-1:0] ly_out;
  wire               ly_valid;
  layer0_etched #(.S(1)) u_lay (
    .clk(clk), .rst_n(rst_n),
    .x_in(evec), .x_valid(id_valid), .x_ready(),
    .x_out(ly_out), .y_valid(ly_valid)
  );

  lm_head #(
    .H(576), .V(32000), .VROWS(32000),
    .WLM_FILE("weights/bake/embed_full_pt.hex")
  ) u_head (
    .clk(clk), .rst_n(rst_n),
    .x_last_in(ly_out), .x_valid(ly_valid),
    .pred_out(pred_out), .done(pred_done)
  );
endmodule
