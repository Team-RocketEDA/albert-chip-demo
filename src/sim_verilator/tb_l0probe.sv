// tb_l0probe.sv — calibrated layer-0 fidelity probe (bit-golden sink).
// DUT: generated layer0_etched (S=1, per-tensor tables + calibrated
// (MUL,SH) points). Flat 4608-bit ports (NOT [575:0][7:0] packed lanes:
// packed arrays reach C++ as raw words, so per-lane C++ indexing would
// scramble the frame). The C++ driver packs one embed row, pulses
// x_valid, waits y_valid; x_out is dumped for golden_l0bit.py.
`timescale 1ns / 1ps
module tb_l0probe (
  input  wire          clk,
  input  wire          rst_n,
  input  wire [4607:0] x_row,
  input  wire          x_valid,
  output wire [4607:0] x_out,
  output wire          y_valid
);
  layer0_etched #(.S(1)) u_lay (
    .clk(clk), .rst_n(rst_n),
    .x_in(x_row), .x_valid(x_valid), .x_ready(),
    .x_out(x_out), .y_valid(y_valid)
  );
endmodule
