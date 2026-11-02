// embed_lut — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E. Token embedding lookup.
module embed_lut #(
  parameter E = 128,
  parameter H = 32
)(
  input  wire         clk,
  input  wire [14:0]  token_id,
  output wire [H*8-1:0] vec
);
endmodule
