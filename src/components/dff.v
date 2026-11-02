// dff — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Pipeline regs; toggle chain =
// div-2N clock divider (wiring pattern, not implemented here).
module dff #(
  parameter W = 8
)(
  input  wire         clk,
  input  wire         rst_n,
  input  wire [W-1:0] d,
  output wire [W-1:0] q
);
endmodule
