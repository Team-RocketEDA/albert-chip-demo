// silu_lut — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// SwiGLU activation table (MobileLLM FFN). Retires gelu_lut.v.
module silu_lut #(
  parameter W = 16
)(
  input  wire [W-1:0] x,
  output wire [W-1:0] y
);
endmodule
