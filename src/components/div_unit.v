// div_unit — §00-E leaf. Unsigned restoring-equivalent divider via an
// inferred `/` operator (00-E implementation rule: plain Verilog operators;
// no single-operator modules). Contract: blocks/03-attention-core.md
// sum_recip (1/s) + 05 MEAN_SUM_DIV / VAR_SSA.
//   quot = all-ones (saturate) when denom == 0, else floor(numer / denom)
//   (unsigned, bit-exact: 0 ulp vs the pure-python golden, within the
//   1-ulp-ish bound per PARAMS step 11).
// Single-shot protocol (matches dotK): present numer/denom with start=1
// for one cycle; at the next posedge quot latches and done pulses for
// exactly one cycle; quot holds and done reads 0 while start=0.
// Softmax wiring note: u_recip drives numer = 2^(W-1) (1.0 in the
// Q-format), so quot = floor(2^(W-1) / exp_sum) is the fixed-point
// reciprocal with 0-ulp error.
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
  reg [W-1:0] quot_r;
  reg         done_r;

  assign quot = quot_r;
  assign done = done_r;

  // Unsigned floor division; divide-by-zero saturates by contract.
  wire [W-1:0] qcomb = (denom == {W{1'b0}}) ? {W{1'b1}} : numer / denom;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      quot_r <= {W{1'b0}};
      done_r <= 1'b0;
    end else begin
      done_r <= start;
      if (start)
        quot_r <= qcomb;
    end
  end
endmodule
