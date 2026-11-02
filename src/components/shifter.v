// shifter — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Requant scale-by-shift.
module shifter #(
  parameter W = 32
)(
  input  wire [W-1:0] din,
  input  wire [4:0]   shamt,
  output wire [W-1:0] dout
);
endmodule
