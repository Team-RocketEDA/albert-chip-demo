// mult — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E.
module mult #(
  parameter W = 16
)(
  input  wire [W-1:0] a,
  input  wire [W-1:0] b,
  output wire [2*W-1:0] y
);
endmodule
