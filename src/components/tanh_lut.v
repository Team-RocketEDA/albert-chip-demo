// tanh_lut — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Pooler tanh table.
module tanh_lut #(
  parameter W = 16
)(
  input  wire [W-1:0] x,
  output wire [W-1:0] y
);
endmodule
