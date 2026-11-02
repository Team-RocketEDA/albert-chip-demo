// alu_bit — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. FSM-adjacent ALU slice.
module alu_bit #(
  parameter W   = 32,
  parameter OPS = 4
)(
  input  wire [W-1:0] a,
  input  wire [W-1:0] b,
  input  wire [$clog2(OPS)-1:0] op,
  output wire [W-1:0] y,
  output wire         flag
);
endmodule
