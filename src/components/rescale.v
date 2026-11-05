// rescale — per-byte static-quant domain rescale (no MAC, no state).
// Contract: residual-stream scale matching between etched layers.
// y[i] = clip8((x[i] * MUL) >>> SH), combinational (zero added latency;
// the downstream norm edges the parent valid, so no handshake here).
// Layer L wiring (see layer_etched): x arrives in s_out(L-1) units,
// the resid adds run in s_R(L) units; RS_MUL/RS_SH = s_out(L-1)/s_R(L).
// Default (256,8) is the exact identity (x*256)>>>8 = x.
module rescale #(
  parameter [15:0] MUL = 16'd256,
  parameter [4:0]  SH  = 5'd8,
  parameter N = 576 // lane count (S*H at the instantiating layer)
)(
  input  wire [N*8-1:0] x, // s8 lanes in the upstream scale domain
  output wire [N*8-1:0] y  // s8 lanes in the local resid domain
);
  genvar i;
  generate
    for (i = 0; i < N; i = i + 1) begin : g_rs
      wire signed [23:0] prod = $signed(x[i*8 +: 8]) * $signed(MUL);
      wire signed [23:0] shr = prod >>> SH;
      assign y[i*8 +: 8] = (shr > 24'sd127) ? 8'sd127 :
                           (shr < -24'sd128) ? 8'sd128 : shr[7:0];
    end
  endgenerate
endmodule
