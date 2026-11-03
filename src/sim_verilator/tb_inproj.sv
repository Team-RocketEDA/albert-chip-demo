// tb_inproj.sv — Verilator thin top: token row in, packed Q|K|V frame out.
// DUT: inproj_tile, single row (S=1): 576 s8 in -> 960 s8 out.
// Weights come from the baked checkpoint images (WQ/WK/WV_FILE default
// to weights/bake/layer0_*_proj.hex, repo-root-relative). The C++ driver
// (tb_inproj.cpp) presents one activation row, pulses tok_valid, waits
// for y_valid, and checks all 960 bytes against a C++ oracle.
`timescale 1ns / 1ps
module tb_inproj (
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire [1*576*8-1:0]     tok_in,
  input  wire                   tok_valid,
  input  wire [15:0]            cfg_scale,
  input  wire [15:0]            cfg_zero,
  output wire                   tok_ready,
  output wire [1*960*8-1:0]     y_out,
  output wire                   y_valid,
  // Second DUT: two packed rows (S=2), exercises the RCAP row-advance
  // path (row 0 -> row 1) that S=1 never touches.
  input  wire [2*576*8-1:0]     tok_in2,
  input  wire                   tok_valid2,
  output wire                   tok_ready2,
  output wire [2*960*8-1:0]     y_out2,
  output wire                   y_valid2
);
  inproj_tile #(.S(1)) u_dut (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in), .tok_valid(tok_valid),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(tok_ready), .y_out(y_out), .y_valid(y_valid)
  );
  inproj_tile #(.S(2)) u_dut2 (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in2), .tok_valid(tok_valid2),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(tok_ready2), .y_out(y_out2), .y_valid(y_valid2)
  );
endmodule
