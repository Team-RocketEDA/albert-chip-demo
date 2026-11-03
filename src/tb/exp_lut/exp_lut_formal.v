// exp_lut_formal — sby wrapper: exp(0) tap, positive-input clamp, and the
// exp image [1, 4096] over the whole table domain.
module exp_lut_formal (
  input wire clk
);
  reg [15:0] x;
  wire [15:0] y;

  exp_lut #(.W(16)) dut (.x(x), .y(y));

  reg f_valid = 1'b0;

  always @(posedge clk) begin
    f_valid <= 1'b1;
    if (f_valid) begin
      if (x == 16'h0000)
        assert(y == 16'h1000);
      if ($signed(x) > 0)
        assert(y == 16'h1000);
      assert($signed(y) >= 1 && $signed(y) <= 4096);
    end
  end
endmodule
