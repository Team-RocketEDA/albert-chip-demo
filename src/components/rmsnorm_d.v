// rmsnorm_d — mid-level wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM RMSNorm. y = x / sqrt(mean(x^2) + eps) * g.
// One reduction (mean of squares), no mean subtraction, no beta bias.
module rmsnorm_d #(
  parameter W = 16
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire [W-1:0]     x,
  input  wire [W-1:0]     resid,
  input  wire [W-1:0]     gamma,
  output wire [W-1:0]     y,
  output wire             y_valid
);
  wire [W-1:0]     t;
  wire [W-1:0]     var_v;
  wire [W-1:0]     rsqrt;
  wire [W-1:0]     xhat; // normalized lane; driven at implementation
  wire [2*W-1:0]   sq;
  wire [2*W-1:0]   nm;
  wire [2*W-1:0]   af;

  // t/sq/nm/af/y driven by inferred +/-/* at implementation
  // (t = x+resid; sq = t*t; nm = t*rsqrt; af = gamma*xhat).
  // mean(x^2) accumulates over the frame at implementation; seed below taps it.
  exp_lut #(.W(W)) u_seed (.x(var_v), .y(rsqrt));
  // af narrows to y here; full requant wired at implementation.
endmodule
