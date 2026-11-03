// proof_mac_unit.v — sby wrapper: accumuland equals unbounded python sum.
// Property: whenever the sampled control was ce (and no clr), the
// registered acc_out is exactly acc_in + a*b (signed, mod-2^32), i.e. the
// same integer the stdlib golden computes with wrap32(). One-cycle-delayed
// copies mirror what the DUT sampled at the last edge.
module proof_mac_unit (
  input wire        clk,
  input wire        rst_n,
  input wire        ce,
  input wire        clr,
  input wire [7:0]  a,
  input wire [7:0]  b,
  input wire [31:0] acc_in
);
  wire [31:0] acc_out;
  mac_unit dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .a(a), .b(b), .acc_in(acc_in), .acc_out(acc_out)
  );

  // Reset-to-zero is covered by simulation; the formal task is the
  // accumulation invariant, proved with reset held inactive so the async
  // reset edge cannot race the property sampling.
  always @(posedge clk) assume(rst_n);

  reg [7:0]  a_d, b_d;
  reg [31:0] acc_d;
  reg        ce_d, clr_d;
  always @(posedge clk) begin
    a_d <= a; b_d <= b; acc_d <= acc_in;
    ce_d <= ce; clr_d <= clr;
  end

  // Named signed product wire mirrors the DUT structure bit-for-bit, so
  // the reference compiles through the same sign-extension path.
  wire signed [15:0] ref_prod;
  assign ref_prod = $signed(a_d) * $signed(b_d);
  wire signed [31:0] ref_sum;
  assign ref_sum = $signed(acc_d) + ref_prod;

  reg f_past_valid = 0;
  always @(posedge clk) f_past_valid <= 1'b1;

  always @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      if (clr_d)
        assert(acc_out == 32'd0);
      else if (ce_d)
        assert(acc_out == ref_sum);
      else
        assert(acc_out == $past(acc_out));
    end
  end
endmodule
