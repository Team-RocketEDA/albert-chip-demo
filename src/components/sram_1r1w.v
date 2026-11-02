// sram_1r1w — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Weight-stationary tile SRAM
// bank: host-loaded once, no write port during inference (we tied low).
module sram_1r1w #(
  parameter W = 8,
  parameter N = 1024
)(
  input  wire         clk,
  input  wire [$clog2(N)-1:0] ra,
  input  wire [$clog2(N)-1:0] wa,
  input  wire [W-1:0] wdata,
  input  wire         we,
  output wire [W-1:0] rdata
);
endmodule
