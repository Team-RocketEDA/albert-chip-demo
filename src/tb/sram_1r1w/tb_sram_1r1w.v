// tb_sram_1r1w — protocol testbench (step 5, RED-capable: elaborates on the
// skeleton, fails in sim because rdata is undriven).
// DUT read model under test: synchronous 1-cycle read (ra sampled at posedge,
// rdata valid after that edge), synchronous write, write-first bypass on
// wa==ra. Golden oracle: baked checkpoint bytes via gen_golden.py
// (init.hex = first 64 bytes of layer0_q_proj.hex; expected.hex = image
// after the 32 scripted writes in writes.txt).
`timescale 1ns / 1ps
module tb_sram_1r1w;
  localparam W = 8;
  localparam N = 64;
  localparam AW = 6;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [AW-1:0] ra;
  reg [AW-1:0] wa;
  reg [W-1:0]  wdata;
  reg          we;
  wire [W-1:0] rdata;

  sram_1r1w #(.W(W), .N(N)) dut (
    .clk(clk), .ra(ra), .wa(wa), .wdata(wdata), .we(we), .rdata(rdata)
  );

  reg [W-1:0] init_mem [0:N-1];
  reg [W-1:0] exp_mem [0:N-1];
  reg [W-1:0] got;
  integer i, errs, fd, na, nd, rc;

  task write_word(input [AW-1:0] a, input [W-1:0] d);
    begin
      @(negedge clk);
      wa = a; wdata = d; we = 1'b1;
      @(posedge clk); #1; we = 1'b0;
    end
  endtask

  task read_word(input [AW-1:0] a, output [W-1:0] d);
    begin
      @(negedge clk);
      ra = a; we = 1'b0;
      @(posedge clk); #1; d = rdata;
    end
  endtask

  // Out-of-range guard check on a non-power-of-2 bank (N=100, AW=7).
  localparam ON = 100;
  localparam OAW = 7;
  reg [OAW-1:0] ora, owa;
  reg [W-1:0]   owdata;
  reg           owe;
  wire [W-1:0]  ordata;
  integer oor_errs = 0;
  reg oor_done = 0;
  reg [W-1:0] ogot;

  sram_1r1w #(.W(W), .N(ON)) odut (
    .clk(clk), .ra(ora), .wa(owa), .wdata(owdata), .we(owe), .rdata(ordata)
  );

  task owrite(input [OAW-1:0] a, input [W-1:0] d);
    begin
      @(negedge clk);
      owa = a; owdata = d; owe = 1'b1;
      @(posedge clk); #1; owe = 1'b0;
    end
  endtask

  task oread(input [OAW-1:0] a, output [W-1:0] d);
    begin
      @(negedge clk);
      ora = a; owe = 1'b0;
      @(posedge clk); #1; d = ordata;
    end
  endtask

  initial begin
    ora = 0; owa = 0; owdata = 0; owe = 0;
    repeat (2) @(posedge clk);
    // In-range top edge works.
    owrite(7'd50, 8'h5A); oread(7'd50, ogot);
    if (ogot !== 8'h5A) begin
      $display("FAIL oor in-range got=%h want=5a", ogot); oor_errs = oor_errs + 1;
    end
    owrite(7'd99, 8'hA5); oread(7'd99, ogot);
    if (ogot !== 8'hA5) begin
      $display("FAIL oor N_MAX got=%h want=a5", ogot); oor_errs = oor_errs + 1;
    end
    // Out-of-range write is dropped and reads as zero (no aliasing:
    // addr 50 must keep its value).
    owrite(7'd120, 8'hFF); oread(7'd120, ogot);
    if (ogot !== 8'h00) begin
      $display("FAIL oor write-not-dropped got=%h", ogot); oor_errs = oor_errs + 1;
    end
    oread(7'd50, ogot);
    if (ogot !== 8'h5A) begin
      $display("FAIL oor aliasing got=%h want=5a", ogot); oor_errs = oor_errs + 1;
    end
    oread(7'd127, ogot);
    if (ogot !== 8'h00) begin
      $display("FAIL oor max-addr read got=%h", ogot); oor_errs = oor_errs + 1;
    end
    // Bypass is also guarded: wa==ra out of range forwards nothing.
    @(negedge clk);
    owa = 7'd105; ora = 7'd105; owdata = 8'hFF; owe = 1'b1;
    @(posedge clk); #1; owe = 1'b0;
    if (ordata !== 8'h00) begin
      $display("FAIL oor bypass got=%h want=00", ordata); oor_errs = oor_errs + 1;
    end
    // In-range bypass still forwards.
    @(negedge clk);
    owa = 7'd60; ora = 7'd60; owdata = 8'h3C; owe = 1'b1;
    @(posedge clk); #1; owe = 1'b0;
    if (ordata !== 8'h3C) begin
      $display("FAIL oor in-range bypass got=%h", ordata); oor_errs = oor_errs + 1;
    end
    oor_done = 1'b1;
  end

  initial begin
    $readmemh("src/tb/sram_1r1w/init.hex", init_mem);
    $readmemh("src/tb/sram_1r1w/expected.hex", exp_mem);
    ra = 0; wa = 0; wdata = 0; we = 0; errs = 0;
    repeat (2) @(posedge clk);

    // 1. Load init image through the write port.
    for (i = 0; i < N; i = i + 1) write_word(i[AW-1:0], init_mem[i]);

    // 2. Read back the full image (sync 1-cycle read).
    for (i = 0; i < N; i = i + 1) begin
      read_word(i[AW-1:0], got);
      if (got !== init_mem[i]) begin
        $display("FAIL init readback addr=%0d got=%h want=%h", i, got, init_mem[i]);
        errs = errs + 1;
      end
    end
    $display("sram init-image readback done errs=%0d", errs);

    // 3. Write-first bypass: wa==ra with we=1 reads back wdata next edge.
    @(negedge clk);
    wa = 6'd7; ra = 6'd7; wdata = 8'hA5; we = 1'b1;
    @(posedge clk); #1; we = 1'b0;
    if (rdata !== 8'hA5) begin
      $display("FAIL bypass addr=7 got=%h want=a5", rdata);
      errs = errs + 1;
    end
    // Restore addr 7 to its init value (bypass write stored A5).
    write_word(6'd7, init_mem[7]);

    // 4. Apply the 32 scripted golden writes.
    fd = $fopen("src/tb/sram_1r1w/writes.txt", "r");
    if (fd == 0) begin $display("FAIL cannot open writes.txt"); $fatal; end
    while ($fscanf(fd, "%d %h\n", na, nd) == 2) begin
      write_word(na[AW-1:0], nd[W-1:0]);
    end
    $fclose(fd);

    // 5. Full-dump compare against the python golden image.
    for (i = 0; i < N; i = i + 1) begin
      read_word(i[AW-1:0], got);
      if (got !== exp_mem[i]) begin
        $display("FAIL dump addr=%0d got=%h want=%h", i, got, exp_mem[i]);
        errs = errs + 1;
      end
    end

    wait (oor_done == 1'b1);
    errs = errs + oor_errs;

    if (errs == 0) $display("PASS tb_sram_1r1w");
    else begin $display("FAIL tb_sram_1r1w errs=%0d", errs); $fatal; end
    $finish;
  end

  // Watchdog: the skeleton never drives rdata, so a hung protocol still ends.
  initial begin
    #200000;
    $display("FAIL tb_sram_1r1w watchdog timeout");
    $fatal;
  end
endmodule
