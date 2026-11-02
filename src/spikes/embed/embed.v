// embed.v — token IDs -> E-dim embed -> int8 row (X[Sx768] slice).
// Weight-stationary: Wemb/PROJ/bias pinned, tokens stream in.
// Full size: V=30000, E=128, H=768. Demo/sim size via parameters.
module embed #(
  parameter V     = 16,
  parameter E     = 8,
  parameter H     = 8,
  parameter SHIFT = 4   // requant: acc >>> SHIFT, clip to s8
)(
  input  wire          clk,
  input  wire          rst_n,
  input  wire [7:0]   tok_id,
  input  wire         tok_valid,
  output wire         tok_ready,
  output reg  [H*8-1:0] row_out,   // packed s8 row, row[0] in low byte
  output reg          row_valid
);
  reg signed [7:0] wemb  [0:V*E-1];
  reg signed [7:0] wproj [0:H*E-1];
  reg signed [7:0] bias  [0:H-1];

  initial begin
    $readmemh("wemb.hex",  wemb);
    $readmemh("wproj.hex", wproj);
    $readmemh("bias.hex",  bias);
  end

  assign tok_ready = 1'b1;   // always sinks (backpressure at loop FIFOs)

  integer j, k;
  reg signed [31:0] acc;
  reg [H*8-1:0]     packed;
  reg signed [7:0]  y;
  reg [7:0]         yb;   // unsigned byte lane for packing

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row_out   <= {H*8{1'b0}};
      row_valid <= 1'b0;
    end else begin
      row_valid <= tok_valid;
      if (tok_valid) begin
        packed = {H*8{1'b0}};
        for (j = H-1; j >= 0; j = j - 1) begin
          acc = bias[j];
          for (k = 0; k < E; k = k + 1)
            acc = acc + wemb[tok_id*E+k] * wproj[j*E+k];
          acc = acc >>> SHIFT;
          if      (acc >  127) y =  127;
          else if (acc < -128) y = -128;
          else                 y = acc[7:0];
          yb = y;
          packed = (packed << 8) | yb;   // row[0] ends in low byte
        end
        row_out <= packed;
      end
    end
  end
endmodule
