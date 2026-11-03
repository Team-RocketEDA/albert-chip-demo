// tb_dram_ctrl_init — INIT_FILE acceptance (GREEN-only): the backing store
// preloads 8 lines from baked checkpoint bytes (dram_init.hex packs the
// first 256 bytes of weights/bake/layer0_q_proj.hex, byte0 = LSB) and every
// line reads back bit-exact with LATENCY-cycle ack timing (spill path).
`timescale 1ns / 1ps
module tb_dram_ctrl_init;
  localparam LAT = 4;
  localparam NL = 8;

  reg clk = 0;
  always #5 clk = ~clk;

  reg        rst_n;
  reg        req;
  reg [31:0] addr;
  wire [255:0] rdata;
  wire         ack;

  dram_ctrl #(.LATENCY(LAT), .NLINES(NL),
              .INIT_FILE("src/tb/dram_ctrl/dram_init.hex")) dut (
    .clk(clk), .rst_n(rst_n), .req(req), .addr(addr),
    .rdata(rdata), .ack(ack)
  );

  reg [255:0] want [0:NL-1];
  integer i, errs, cyc, c;

  initial begin
    $readmemh("src/tb/dram_ctrl/dram_init.hex", want);
    errs = 0; rst_n = 0; req = 0; addr = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    for (i = 0; i < NL; i = i + 1) begin
      @(negedge clk);
      addr = i * 32; req = 1'b1;
      @(posedge clk); #1;
      cyc = 0;
      while (cyc < 40 && ack !== 1'b1) begin
        @(posedge clk); #1; cyc = cyc + 1;
      end
      if (ack !== 1'b1) begin
        $display("FAIL line %0d no ack", i); errs = errs + 1;
      end else begin
        if (cyc !== LAT) begin
          $display("FAIL line %0d latency got=%0d want=%0d", i, cyc, LAT);
          errs = errs + 1;
        end
        if (rdata !== want[i]) begin
          $display("FAIL line %0d data got=%h want=%h", i, rdata, want[i]);
          errs = errs + 1;
        end
      end
      @(negedge clk); req = 1'b0;
      @(posedge clk); #1;
    end
    if (errs == 0) $display("PASS tb_dram_ctrl_init");
    else begin $display("FAIL tb_dram_ctrl_init errs=%0d", errs); $fatal; end
    $finish;
  end

  initial begin
    #300000;
    $display("FAIL tb_dram_ctrl_init watchdog timeout");
    $fatal;
  end
endmodule
