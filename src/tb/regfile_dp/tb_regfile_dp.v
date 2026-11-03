// tb_regfile_dp — protocol testbench (step 5, RED-capable: elaborates on the
// skeleton, fails in sim because rda/rdb are undriven).
// DUT read model under test: asynchronous dual read with same-cycle
// write-forward bypass (we && wa==ra -> rda/rdb == wdata), synchronous write.
// Golden oracle: baked checkpoint bytes via gen_golden.py (init.hex packs the
// first 256 bytes of layer0_q_proj.hex little-endian into 64x32b words).
`timescale 1ns / 1ps
module tb_regfile_dp;
  localparam W = 32;
  localparam N = 64;
  localparam AW = 6;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [AW-1:0] ra, rb, wa;
  reg [W-1:0]  wdata;
  reg          we;
  wire [W-1:0] rda, rdb;

  regfile_dp #(.W(W), .N(N)) dut (
    .clk(clk), .ra(ra), .rb(rb), .wa(wa), .wdata(wdata), .we(we),
    .rda(rda), .rdb(rdb)
  );

  reg [W-1:0] init_mem [0:N-1];
  reg [W-1:0] exp_mem [0:N-1];
  integer i, errs, fd, na;
  reg [W-1:0] nd;
  integer rc;

  task write_word(input [AW-1:0] a, input [W-1:0] d);
    begin
      @(negedge clk);
      wa = a; wdata = d; we = 1'b1;
      @(posedge clk); #1; we = 1'b0;
    end
  endtask

  // Out-of-range guard check on a non-power-of-2 file (N=100, AW=7).
  localparam ON = 100;
  localparam OAW = 7;
  reg [OAW-1:0] ora, orb, owa;
  reg [W-1:0]   owdata;
  reg           owe;
  wire [W-1:0]  orda, ordb;
  integer oor_errs = 0;
  reg oor_done = 0;

  regfile_dp #(.W(W), .N(ON)) odut (
    .clk(clk), .ra(ora), .rb(orb), .wa(owa), .wdata(owdata), .we(owe),
    .rda(orda), .rdb(ordb)
  );

  task owrite(input [OAW-1:0] a, input [W-1:0] d);
    begin
      @(negedge clk);
      owa = a; owdata = d; owe = 1'b1;
      @(posedge clk); #1; owe = 1'b0;
    end
  endtask

  initial begin
    ora = 0; orb = 0; owa = 0; owdata = 0; owe = 0;
    repeat (2) @(posedge clk);
    // In-range top edge works on both ports.
    owrite(7'd99, 32'hDEAD_BEEF);
    ora = 7'd99; orb = 7'd99; #2;
    if (orda !== 32'hDEAD_BEEF || ordb !== 32'hDEAD_BEEF) begin
      $display("FAIL oor in-range got=%h/%h", orda, ordb);
      oor_errs = oor_errs + 1;
    end
    // Out-of-range write is dropped; both ports read zero.
    owrite(7'd120, 32'hFFFFFFFF);
    ora = 7'd120; orb = 7'd120; #2;
    if (orda !== 32'h0 || ordb !== 32'h0) begin
      $display("FAIL oor write-not-dropped got=%h/%h", orda, ordb);
      oor_errs = oor_errs + 1;
    end
    // No aliasing: addr 99 keeps its value.
    ora = 7'd99; #2;
    if (orda !== 32'hDEAD_BEEF) begin
      $display("FAIL oor aliasing got=%h", orda);
      oor_errs = oor_errs + 1;
    end
    // Bypass is guarded out of range (must read zero, not wdata)...
    @(negedge clk);
    owa = 7'd105; owdata = 32'hCAFEBABE; owe = 1'b1;
    ora = 7'd105; orb = 7'd105; #2;
    if (orda !== 32'h0 || ordb !== 32'h0) begin
      $display("FAIL oor bypass got=%h/%h", orda, ordb);
      oor_errs = oor_errs + 1;
    end
    // ...and still forwards in range.
    owa = 7'd60; owdata = 32'h12345678;
    ora = 7'd60; orb = 7'd60; #2;
    if (orda !== 32'h12345678 || ordb !== 32'h12345678) begin
      $display("FAIL oor in-range bypass got=%h/%h", orda, ordb);
      oor_errs = oor_errs + 1;
    end
    @(posedge clk); #1; owe = 1'b0;
    oor_done = 1'b1;
  end

  initial begin
    $readmemh("src/tb/regfile_dp/init.hex", init_mem);
    $readmemh("src/tb/regfile_dp/expected.hex", exp_mem);
    ra = 0; rb = 0; wa = 0; wdata = 0; we = 0; errs = 0;
    repeat (2) @(posedge clk);

    // 1. Load init image through the write port.
    for (i = 0; i < N; i = i + 1) write_word(i[AW-1:0], init_mem[i]);

    // 2. Dual-port async readback: both ports see the same word at once.
    for (i = 0; i < N; i = i + 1) begin
      ra = i[AW-1:0]; rb = i[AW-1:0]; #2;
      if (rda !== init_mem[i]) begin
        $display("FAIL rda addr=%0d got=%h want=%h", i, rda, init_mem[i]);
        errs = errs + 1;
      end
      if (rdb !== init_mem[i]) begin
        $display("FAIL rdb addr=%0d got=%h want=%h", i, rdb, init_mem[i]);
        errs = errs + 1;
      end
    end
    $display("regfile dual-read init check done errs=%0d", errs);

    // 3. Same-cycle write-forward bypass on both ports (no clock edge).
    @(negedge clk);
    wa = 6'd9; wdata = 32'hDEADBEEF; we = 1'b1;
    ra = 6'd9; rb = 6'd9; #2;
    if (rda !== 32'hDEADBEEF) begin
      $display("FAIL bypass rda got=%h", rda); errs = errs + 1;
    end
    if (rdb !== 32'hDEADBEEF) begin
      $display("FAIL bypass rdb got=%h", rdb); errs = errs + 1;
    end
    @(posedge clk); #1; we = 1'b0; // let the bypassed write commit
    // Non-bypassed port still shows stored data during a write elsewhere.
    @(negedge clk);
    wa = 6'd10; wdata = 32'h12345678; we = 1'b1;
    ra = 6'd11; #2;
    if (rda !== init_mem[11]) begin
      $display("FAIL concurrent read got=%h want=%h", rda, init_mem[11]);
      errs = errs + 1;
    end
    @(posedge clk); #1; we = 1'b0;

    // 4. Write-disabled: we=0 must not modify storage.
    @(negedge clk);
    wa = 6'd12; wdata = 32'hAAAAAAAA; we = 1'b0;
    @(posedge clk); #1;
    ra = 6'd12; #2;
    if (rda !== init_mem[12]) begin
      $display("FAIL we=0 wrote addr=12 got=%h", rda); errs = errs + 1;
    end

    // 5. Apply the 16 scripted golden writes (overwrites addrs 9..12 too,
    //    so the final image must equal expected.hex regardless).
    fd = $fopen("src/tb/regfile_dp/writes.txt", "r");
    if (fd == 0) begin $display("FAIL cannot open writes.txt"); $fatal; end
    while ($fscanf(fd, "%d %h\n", na, nd) == 2) begin
      write_word(na[AW-1:0], nd);
    end
    $fclose(fd);

    // 6. Full-dump compare against the python golden image.
    for (i = 0; i < N; i = i + 1) begin
      ra = i[AW-1:0]; #2;
      if (rda !== exp_mem[i]) begin
        $display("FAIL dump addr=%0d got=%h want=%h", i, rda, exp_mem[i]);
        errs = errs + 1;
      end
    end

    wait (oor_done == 1'b1);
    errs = errs + oor_errs;

    if (errs == 0) $display("PASS tb_regfile_dp");
    else begin $display("FAIL tb_regfile_dp errs=%0d", errs); $fatal; end
    $finish;
  end

  initial begin
    #200000;
    $display("FAIL tb_regfile_dp watchdog timeout");
    $fatal;
  end
endmodule
