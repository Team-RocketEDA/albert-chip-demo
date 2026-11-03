// tb_embed.sv — Verilator thin top: real token ids -> baked embed vectors.
// DUT: embed_lut, full MobileLLM config (32000 x 576 int8, sparse init:
// 8 tested rows hold checkpoint bytes, the rest read zero).
// The C++ driver (tb_embed.cpp) feeds token ids, prints each id with the
// first vector bytes vs the baked golden, and dumps waves_embed.fst.
`timescale 1ns / 1ps
module tb_embed (
  input  wire            clk,
  input  wire [14:0]     token_id,
  output wire [576*8-1:0] vec
);
  embed_lut #(
    .E(576), .H(576), .V(32000),
    .INIT_FILE("src/tb/embed_lut/dut_init_full.hex")
  ) u_dut (
    .clk(clk), .token_id(token_id), .vec(vec)
  );
endmodule
