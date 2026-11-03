// irq_sync_formal — sby wrapper (plan step 4). Proves irq is exactly the
// async input delayed by 2 clocks, against an independent 2-stage model
// kept in the wrapper. Guarded by a settle counter (init 0, honored as the
// formal initial state): after 2 real samples both the DUT flops and the
// model hold genuine history from ANY DUT start state, so the check is
// sound with no reset assumption.
`timescale 1ns / 1ps
module irq_sync_formal (
  input wire clk,
  input wire irq_async
);
  wire irq;

  irq_sync dut (.clk(clk), .irq_async(irq_async), .irq(irq));

  reg [1:0] age = 2'b00;
  reg       s1 = 1'b0;
  reg       s2 = 1'b0;

  always @(posedge clk) begin
    if (age != 2'b10) age <= age + 1'b1;
    s1 <= irq_async;
    s2 <= s1;
    if (age == 2'b10)
      two_cycle_delay: assert(irq == s2);
  end

  always @(posedge clk) begin
    if (age == 2'b10) begin
      cov_low:  cover(!irq);
      cov_high: cover(irq);
      cov_edge: cover(irq != $past(irq));
    end
  end
endmodule
