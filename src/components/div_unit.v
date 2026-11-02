// div_unit — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/03-attention-core.md (sum_recip 1/s) + blocks/05
// (MEAN_SUM_DIV / VAR_SSA). Restoring/NR divider, integer-emulated in Py.
module div_unit #(
  parameter W = 32
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             start,
  input  wire [W-1:0]    numer,
  input  wire [W-1:0]    denom,
  output wire [W-1:0]    quot,
  output wire             done
);
endmodule
