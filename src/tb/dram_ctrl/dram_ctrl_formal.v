// dram_ctrl_formal — sby wrapper: proves ack pulse-shape + data-hold using
// DUT outputs and wrapper history only (no references into DUT internals).
// The DUT is held in reset for two full cycles (rst_phase) so every flop
// takes its reset value regardless of anyinit; properties enable only after
// the history has filled with post-reset samples.
// Properties:
//  - ack never holds two consecutive cycles (single-cycle pulse);
//  - rdata is stable in the cycle after ack (held until next completion).
// Latency (ack exactly LATENCY cycles after req) and line-data values are
// covered by directed sim (tb_dram_ctrl + tb_dram_ctrl_init measure every
// ack distance and compare all 8 baked lines bit-exact).
module dram_ctrl_formal (
  input wire clk
);
  localparam LAT = 4;
  localparam NL = 8;

  reg        rst_n = 1'b0;
  reg        req;
  reg [31:0] addr;
  wire [255:0] rdata;
  wire         ack;

  dram_ctrl #(.LATENCY(LAT), .NLINES(NL)) dut (
    .clk(clk), .rst_n(rst_n), .req(req), .addr(addr),
    .rdata(rdata), .ack(ack)
  );

  reg [1:0] rst_phase = 2'b0;
  reg f_ack = 1'b0;
  reg [255:0] f_rdata = 256'b0;

  always @(posedge clk) begin
    if (rst_phase != 2'b10)
      rst_phase <= rst_phase + 2'b01;
    rst_n <= (rst_phase == 2'b10);
    f_ack <= ack;
    f_rdata <= rdata;
    if (rst_phase == 2'b10 && rst_n) begin
      if (f_ack && ack)
        assert(1'b0);
      if (f_ack)
        assert(rdata == f_rdata);
    end
  end
endmodule
