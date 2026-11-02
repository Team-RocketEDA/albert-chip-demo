// dram_ctrl — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E + BUILD_MAP (parked: S<=64
// never spills; instantiated only if S outgrows on-chip SRAM).
module dram_ctrl (
  input  wire         clk,
  input  wire         rst_n,
  input  wire         req,
  input  wire [31:0]  addr,
  output wire [255:0] rdata,
  output wire         ack
);
endmodule
