// silu_lut_formal — sby wrapper: exact zero at x=0 and SiLU image bounds.
// Bounds [-1143, 32758] are the float image [round(min)*, round(max)*] =
// [-1141, 32756] plus 2 LSB of table+interp slack (tb proves <= 1 LSB).
module silu_lut_formal (
  input wire clk
);
  reg [15:0] x;
  wire [15:0] y;

  silu_lut #(.W(16)) dut (.x(x), .y(y));

  reg f_valid = 1'b0;

  always @(posedge clk) begin
    f_valid <= 1'b1;
    if (f_valid) begin
      if (x == 16'h0000)
        assert(y == 16'h0000);
      assert($signed(y) >= -1143 && $signed(y) <= 32758);
    end
  end
endmodule
