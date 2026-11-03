// tb_rmsnorm.sv — Verilator thin top: 576-lane RMSNorm frame in, norms out.
// DUT: rmsnorm_d, full MobileLLM config (W=16 Q8.8, D=576).
// The C++ driver (tb_rmsnorm.cpp) streams one baked frame (x + gamma,
// resid=0), collects the 576 y_valid outputs, checks them against the
// baked golden within 3 LSB, and dumps waves_rmsnorm.fst.
`timescale 1ns / 1ps
module tb_rmsnorm (
  input  wire        clk,
  input  wire        rst_n,
  input  wire [15:0] x,
  input  wire [15:0] resid,
  input  wire [15:0] gamma,
  output wire [15:0] y,
  output wire        y_valid
);
  rmsnorm_d #(.W(16), .D(576)) u_dut (
    .clk(clk), .rst_n(rst_n), .x(x), .resid(resid), .gamma(gamma),
    .y(y), .y_valid(y_valid)
  );
endmodule
