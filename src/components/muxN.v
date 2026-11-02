// muxN — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Datapath steering.
module muxN #(
  parameter W = 8,
  parameter N = 2
)(
  input  wire [$clog2(N)-1:0] sel,
  input  wire [N*W-1:0] din,
  output wire [W-1:0] dout
);
endmodule
