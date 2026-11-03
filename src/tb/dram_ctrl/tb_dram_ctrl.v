// tb_dram_ctrl — protocol testbench (step 5, RED-capable: elaborates on the
// skeleton, fails in sim because ack is undriven so every request times out).
// DUT protocol under test: pulse/level req in IDLE latches addr; ack asserts
// exactly LATENCY cycles later for one cycle with the 256-bit line data.
// Addr map: addr[31:5] = 32-byte line index, addr[4:0] ignored. Lines past
// the backing store still ack (spill-miss completes with zero data).
// Default (empty) backing store reads back zero; baked-byte content is
// covered by tb_dram_ctrl_init.
`timescale 1ns / 1ps
module tb_dram_ctrl;
  localparam LAT = 4;

  reg clk = 0;
  always #5 clk = ~clk;

  reg        rst_n;
  reg        req;
  reg [31:0] addr;
  wire [255:0] rdata;
  wire         ack;

  dram_ctrl dut (
    .clk(clk), .rst_n(rst_n), .req(req), .addr(addr),
    .rdata(rdata), .ack(ack)
  );

  integer errs, cycles, i;

  // Issue a line read; returns cycles from req-accept to ack and the data.
  task read_line(input [31:0] a, output integer ncyc, output reg [255:0] d);
    integer c, done;
    begin
      @(negedge clk);
      addr = a; req = 1'b1;
      @(posedge clk); #1;
      c = 0; done = 0;
      while (c < 40 && !done) begin
        if (ack === 1'b1) begin d = rdata; done = 1; end
        else begin @(posedge clk); #1; c = c + 1; end
      end
      if (!done) begin
        $display("FAIL timeout waiting ack addr=%h", a);
        errs = errs + 1; ncyc = -1; d = 256'hx;
      end else ncyc = c;
      @(negedge clk); req = 1'b0;
      @(posedge clk); #1;
      if (ack === 1'b1) begin
        $display("FAIL ack held >1 cycle addr=%h", a); errs = errs + 1;
      end
    end
  endtask

  reg [255:0] d;

  initial begin
    errs = 0; rst_n = 0; req = 0; addr = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // 1. Single read from the empty store: LATENCY-cycle latency, zero data.
    // req accepted at the first posedge, ack visible LAT cycles later.
    read_line(32'd3 * 32, cycles, d);
    if (cycles !== LAT) begin
      $display("FAIL latency got=%0d want=%0d", cycles, LAT); errs = errs + 1;
    end
    if (d !== 256'b0) begin
      $display("FAIL empty-store data got=%h", d); errs = errs + 1;
    end

    // 2. Spill path: out-of-range line still completes, zero data.
    read_line(32'd511 * 32, cycles, d);
    if (cycles !== LAT) begin
      $display("FAIL spill latency got=%0d want=%0d", cycles, LAT);
      errs = errs + 1;
    end
    if (d !== 256'b0) begin
      $display("FAIL spill data got=%h", d); errs = errs + 1;
    end

    // 3. Back-to-back: req held through DONE starts a second burst.
    @(negedge clk);
    addr = 32'd5 * 32; req = 1'b1;
    for (i = 0; i < 2; i = i + 1) begin
      cycles = 0;
      while (cycles < 40 && ack !== 1'b1) begin @(posedge clk); #1; cycles = cycles + 1; end
      if (ack !== 1'b1) begin
        $display("FAIL back-to-back burst %0d no ack", i); errs = errs + 1;
      end else if (rdata !== 256'b0) begin
        $display("FAIL back-to-back data burst %0d", i); errs = errs + 1;
      end
      @(posedge clk); #1; // move past the ack cycle
    end
    @(negedge clk); req = 1'b0;
    @(posedge clk); #1;

    // 4. Reset mid-burst: no ack, controller recovers.
    @(negedge clk);
    addr = 32'd6 * 32; req = 1'b1;
    @(posedge clk); #1;
    @(posedge clk); #1;
    rst_n = 1'b0;
    @(posedge clk); #1;
    @(posedge clk); #1;
    if (ack === 1'b1) begin
      $display("FAIL ack during reset"); errs = errs + 1;
    end
    rst_n = 1'b1; req = 1'b0;
    repeat (2) @(posedge clk);
    read_line(32'd6 * 32, cycles, d);
    if (cycles !== LAT || d !== 256'b0) begin
      $display("FAIL post-reset read cyc=%0d", cycles); errs = errs + 1;
    end

    if (errs == 0) $display("PASS tb_dram_ctrl");
    else begin $display("FAIL tb_dram_ctrl errs=%0d", errs); $fatal; end
    $finish;
  end

  initial begin
    #300000;
    $display("FAIL tb_dram_ctrl watchdog timeout");
    $fatal;
  end
endmodule
