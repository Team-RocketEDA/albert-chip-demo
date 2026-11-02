// softmax_d — mid-level wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM decoder softmax (max-sub / exp / sum / div + causal).
// Accumulation and NR iteration close at implementation; first-lane taps
// shown, S lanes replicate. causal=1 masks future positions (decode safe).
module softmax_d #(
  parameter W = 16,
  parameter S = 64
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [S*W-1:0]   scores,
  input  wire             scores_valid,
  input  wire             causal,
  output wire [S*W-1:0]   probs,
  output wire             probs_valid
);
  wire [W-1:0] row_max;
  wire [W-1:0] sub_e;
  wire [W-1:0] exp_e;
  wire [W-1:0] exp_sum;
  wire [W-1:0] recip;
  wire [2*W-1:0] norm_full;

  cmp #(.W(W)) u_rowmax (
    .a(scores[W-1:0]), .b(scores[2*W-1:W]), .y(row_max), .gt()
  );
  sub #(.W(W)) u_sub (
    .a(scores[W-1:0]), .b(row_max), .y(sub_e), .sign()
  );
  exp_lut #(.W(W)) u_exp (
    .x(sub_e), .y(exp_e)
  );
  adder #(.W(W)) u_sum (
    .a(exp_e), .b({W{1'b0}}), .y(exp_sum), .cout()
  );
  // Row accumulation over S lanes closes at implementation; u_sum shows
  // one accumulate step.
  div_unit #(.W(W)) u_recip (
    .clk(clk), .rst_n(rst_n), .start(scores_valid),
    .numer({1'b1, {(W-1){1'b0}}}), .denom(exp_sum),
    .quot(recip), .done()
  );
  mult #(.W(W)) u_norm (
    .a(exp_e), .b(recip), .y(norm_full)
  );
  // Causal mask add (scores + mask_bias) wired at implementation when
  // causal=1. First-lane probability tap; S lanes replicate at implementation.
  // probs driven at implementation from norm_full taps.
endmodule
