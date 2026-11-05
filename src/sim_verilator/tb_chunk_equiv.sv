// tb_chunk_equiv.sv — Verilator thin top: monolithic inproj_tile (S=1)
// vs the 2-slice harness layer0_inproj_c2x (emit_chunks.py exhaust).
// The C++ driver presents one activation row and checks all 960 bytes
// EXACTLY. Slices must concat to the monolith bit-for-bit.
`timescale 1ns / 1ps
module tb_chunk_equiv (
  input  wire               clk,
  input  wire               rst_n,
  input  wire [1*576*8-1:0] tok_in,
  input  wire               tok_valid,
  input  wire [15:0]        cfg_scale,
  input  wire [15:0]        cfg_zero,
  output wire [1*960*8-1:0] mono_y,
  output wire               mono_v,
  output wire [1*960*8-1:0] chunk_y,
  output wire               chunk_v
);
  // QKV_SH matches the chunk leaves (emit_chunks.py binds L0's
  // calibrated SC_QKVSH from scales_cal.json; update together).
  inproj_tile #(.S(1), .QKV_SH(5'd19)) u_mono (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in), .tok_valid(tok_valid),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(), .y_out(mono_y), .y_valid(mono_v)
  );
  layer0_inproj_c2x #(.S(1)) u_chunk (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in), .tok_valid(tok_valid),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(), .y_out(chunk_y), .y_valid(chunk_v)
  );
endmodule
