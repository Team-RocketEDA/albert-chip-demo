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

  // row_max/sub_e/exp_sum driven by inferred cmp/-/+ at implementation.
  exp_lut #(.W(W)) u_exp (
    .x(sub_e), .y(exp_e)
  );
  // Row accumulation over S lanes closes at implementation.
  div_unit #(.W(W)) u_recip (
    .clk(clk), .rst_n(rst_n), .start(scores_valid),
    .numer({1'b1, {(W-1){1'b0}}}), .denom(exp_sum),
    .quot(recip), .done()
  );
  // norm_full = exp_e*recip inferred at implementation.
  // Causal mask add (scores + mask_bias) wired at implementation when
  // causal=1. First-lane probability tap; S lanes replicate at implementation.
  // probs driven at implementation from norm_full taps.
endmodule
