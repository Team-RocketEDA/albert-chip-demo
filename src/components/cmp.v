// cmp — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Compare / max trees.
module cmp #(
  parameter W = 16
)(
  input  wire [W-1:0] a,
  input  wire [W-1:0] b,
  output wire [W-1:0] y,
  output wire         gt
);
endmodule
