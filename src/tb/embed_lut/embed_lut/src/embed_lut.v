// embed_lut — §00-E leaf.
// Contract: blocks/00-primitive-library.md §E + blocks/01-embed.md §2
// (EMB_LUT_BANK). Token embedding lookup: registered 1-cycle ROM read
// over a V-row x H-byte int8 table (MobileLLM vocab 32000, H=576; the
// 15-bit token_id space holds 32768 slots, ids >= V read zero).
// Weight-stationary: the image is host-loaded once via the INIT_FILE
// $readmemh packed-row image (one hex number per line, MSB-first so
// vec[8k+7:8k] == row byte k, i.e. row[0] in the low byte, matching
// testbench/gen_embed_vectors.py). INIT_FILE="" leaves all rows zero.
// Compare + row-select are plain inferred operators: no
// single-operator modules (culled per block-logic-plan step 2).
module embed_lut #(
  parameter E = 128,       // compat: tied-embedding dim (E == H here)
  parameter H = 32,        // row width in bytes
  parameter V = 32000,     // backed vocab rows (token_id < V)
  parameter INIT_FILE = "" // packed-row $readmemh image ("" = all zero)
)(
  input  wire         clk,
  input  wire [14:0]  token_id,
  output wire [H*8-1:0] vec
);
  reg [H*8-1:0] rom [0:V-1];
  reg [H*8-1:0] vec_q;

  assign vec = vec_q;

  integer i;
  initial begin
    for (i = 0; i < V; i = i + 1)
      rom[i] = {H*8{1'b0}};
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, rom);
  end

  always @(posedge clk) begin
    if (token_id < V)
      vec_q <= rom[token_id];
    else
      vec_q <= {H*8{1'b0}};
  end
endmodule
