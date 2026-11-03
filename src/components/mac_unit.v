// mac_unit — §00-E leaf. Folded MAC: acc += a*b, 1 MAC/cycle.
// Signed fixed-point throughout: a/b are signed W-bit, acc is signed
// ACC-bit with two's-complement wrap (exact mod-2^ACC, no saturation;
// requant/saturation lives in `requant`, never here).
// Registered output: async reset (rst_n) or sync clr -> 0; else if ce ->
// acc_in + a*b; else hold. acc_in lets callers chain/fold accumulation
// across cycles and tiles.
module mac_unit #(
  parameter W   = 8,
  parameter ACC = 32
)(
  input  wire             clk,
  input  wire             rst_n,
  input  wire             ce,
  input  wire             clr,
  input  wire [W-1:0]     a,
  input  wire [W-1:0]     b,
  input  wire [ACC-1:0]   acc_in,
  output wire [ACC-1:0]   acc_out
);
  reg signed [ACC-1:0] acc_r;
  assign acc_out = acc_r;

  wire signed [2*W-1:0] prod;
  assign prod = $signed(a) * $signed(b);

  // prod (2W-bit signed) intentionally sign-extends into the ACC-bit add;
  // exact mod-2^ACC wrap. Proven by src/tb/mac_unit.sby.
  /* verilator lint_off WIDTHEXPAND */
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_r <= {ACC{1'b0}};
    else if (clr)
      acc_r <= {ACC{1'b0}};
    else if (ce)
      acc_r <= $signed(acc_in) + prod;
  end
  /* verilator lint_on WIDTHEXPAND */
endmodule
