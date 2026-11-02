// fifo_sync — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Sync FIFO, DEPTH D, valid/ready.
module fifo_sync #(
  parameter W = 8,
  parameter D = 8
)(
  input  wire         clk,
  input  wire         rst_n,
  input  wire [W-1:0] wdata,
  input  wire         wr,
  input  wire         rd,
  output wire [W-1:0] rdata,
  output wire         full,
  output wire         empty
);
endmodule
