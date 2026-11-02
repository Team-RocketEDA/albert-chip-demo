// regfile_dp — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Dual-port scratch (accumulators).
module regfile_dp #(
  parameter W = 32,
  parameter N = 256
)(
  input  wire         clk,
  input  wire [$clog2(N)-1:0] ra,
  input  wire [$clog2(N)-1:0] rb,
  input  wire [$clog2(N)-1:0] wa,
  input  wire [W-1:0] wdata,
  input  wire         we,
  output wire [W-1:0] rda,
  output wire [W-1:0] rdb
);
endmodule
