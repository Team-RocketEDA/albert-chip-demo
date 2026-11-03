// irq_sync — §00-E leaf, 2-flop synchronizer into seq_fsm.
// Contract: blocks/00-primitive-library.md §E. Ports/topology frozen
// (no reset port on purpose: the async line has no reset domain).
// irq is irq_async delayed by exactly 2 clk edges; flops init 0 so sim
// starts settled. Consumers must treat irq as a 2-cycle-delayed level.
module irq_sync (
  input  wire clk,
  input  wire irq_async,
  output wire irq
);
  reg [1:0] sync_q = 2'b00;

  always @(posedge clk)
    sync_q <= {sync_q[0], irq_async};

  assign irq = sync_q[1];
endmodule
