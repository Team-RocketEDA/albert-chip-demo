// mac_unit.v — parametric folded MAC: acc_out = acc_in + a*b, 1 MAC/cycle.
// §00-E `mac_unit #(W)`. Weight-stationary: b (weight) held steady by the
// caller SRAM bank; a (activation) streams in. Signed fixed-point throughout.
module mac_unit #(
  parameter W   = 8,    // data_bit_width (activation/weight)
  parameter ACC = 32    // accumulator width
)(
  input  wire                  clk,
  input  wire                  rst_n,
  input  wire                  ce,      // accumulate enable
  input  wire                  clr,     // sync clear of accumulator out
  input  wire signed [W-1:0]   a,
  input  wire signed [W-1:0]   b,
  input  wire signed [ACC-1:0] acc_in,
  output reg  signed [ACC-1:0] acc_out
);
  wire signed [ACC-1:0] prod_ext;
  assign prod_ext = a * b;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      acc_out <= {ACC{1'b0}};
    else if (clr)
      acc_out <= {ACC{1'b0}};
    else if (ce)
      acc_out <= acc_in + prod_ext;
  end
endmodule
