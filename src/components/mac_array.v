// mac_array — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. P-wide parallel MACs.
module mac_array #(
  parameter W = 8,
  parameter P = 32
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             ce,
  input  wire             clr,
  input  wire [P*W-1:0]   avec,
  input  wire [P*W-1:0]   bvec,
  input  wire [31:0]      acc_in,
  output wire [31:0]      acc_out
);
endmodule
