// mac_unit — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Folded MAC: acc += a*b.
module mac_unit #(
  parameter W   = 8,
  parameter ACC = 32
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             ce,
  input  wire             clr,
  input  wire [W-1:0]     a,
  input  wire [W-1:0]     b,
  input  wire [ACC-1:0]   acc_in,
  output wire [ACC-1:0]   acc_out
);
endmodule
