// requant — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Accum-to-int8 rescale.
module requant #(
  parameter W = 8
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [31:0]      acc_wide,
  input  wire [15:0]      scale,
  input  wire [15:0]      zero,
  output wire [W-1:0]     act_int,
  output wire             valid
);
endmodule
