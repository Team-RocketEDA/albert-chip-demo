// dotK — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. K-fold MAC loop reuse
// (embed DOT128 = K=128 instance).
module dotK #(
  parameter W = 8,
  parameter K = 128
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             start,
  input  wire [K*W-1:0]   avec,
  input  wire [K*W-1:0]   bvec,
  output wire [31:0]      y,
  output wire             done
);
endmodule
