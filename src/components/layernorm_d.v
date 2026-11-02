// layernorm_d — mid-level wiring, STRUCTURAL ONLY (children + wires, no logic).
// Contract: MobileLLM RMSNorm. y = x / sqrt(mean(x^2) + eps) * g.
// One reduction (mean of squares), no mean subtraction, no beta bias.
// Same sqrt/divide core as before, fewer reductions.
module layernorm_d #(
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

  adder #(.W(W)) u_resadd (.a(x), .b(resid), .y(t), .cout());
  mult  #(.W(W)) u_square (.a(t), .b(t), .y(sq));
  // mean(x^2) accumulates over the frame at implementation; seed below taps it.
  exp_lut #(.W(W)) u_seed (.x(var_v), .y(rsqrt));
  mult  #(.W(W)) u_norm   (.a(t), .b(rsqrt), .y(nm));
  mult  #(.W(W)) u_affm   (.a(gamma), .b(xhat), .y(af));
  // af narrows to y here; full requant wired at implementation.
  adder #(.W(W)) u_affa   (.a(af[W-1:0]), .b({W{1'b0}}), .y(y), .cout());
endmodule
