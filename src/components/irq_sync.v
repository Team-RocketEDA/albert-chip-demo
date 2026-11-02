// irq_sync — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. 2-flop synchronizer into seq_fsm.
module irq_sync (
  input  wire clk,
  input  wire irq_async,
  output wire irq
);
endmodule
