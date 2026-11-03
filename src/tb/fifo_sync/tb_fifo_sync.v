// tb_fifo_sync — RED/GREEN unit bench for fifo_sync (plan step 4).
// Oracle: vectors_fifo.txt from the independent pure-python golden
// gen_golden.py (never the RTL). Cycle discipline: drive (wr,rd,wdata) at
// negedge, sample (full,empty,rdata) #1 after posedge = post-update state.
// Run: iverilog -g2012 -o /tmp/fifo_sim src/components/fifo_sync.v
//        src/tb/fifo_sync/tb_fifo_sync.v && vvp /tmp/fifo_sim +VEC=<vectors>
`timescale 1ns / 1ps

module tb_fifo_sync;
  parameter W = 8;
  parameter D = 8;

  reg             clk = 1'b0;
  reg             rst_n = 1'b0;
  reg  [W-1:0]   wdata = {W{1'b0}};
  reg             wr = 1'b0;
  reg             rd = 1'b0;
  wire [W-1:0]   rdata;
  wire            full;
  wire            empty;

  always #5 clk = ~clk;

  fifo_sync #(.W(W), .D(D)) dut (
    .clk(clk), .rst_n(rst_n), .wdata(wdata), .wr(wr), .rd(rd),
    .rdata(rdata), .full(full), .empty(empty)
  );

  // Second instance: degenerate DEPTH 1 / W 4, directed checks inline.
  reg  [3:0] wdata1 = 4'h0;
  reg        wr1 = 1'b0;
  reg        rd1 = 1'b0;
  wire [3:0] rdata1;
  wire       full1;
  wire       empty1;

  fifo_sync #(.W(4), .D(1)) dut1 (
    .clk(clk), .rst_n(rst_n), .wdata(wdata1), .wr(wr1), .rd(rd1),
    .rdata(rdata1), .full(full1), .empty(empty1)
  );

  integer fd, nvec, i, mism;
  integer v_wr, v_rd, v_wdata, v_full, v_empty, v_rdata;
  string vecpath;

  // One op per call: drive at negedge, sample #1 after the next posedge.
  task apply1(input w, input r, input [3:0] wd,
              input exp_full, input exp_empty, input [3:0] exp_rdata);
    begin
      @(negedge clk);
      wdata1 = wd; wr1 = w; rd1 = r;
      @(posedge clk); #1;
      if (full1 !== exp_full || empty1 !== exp_empty || rdata1 !== exp_rdata) begin
        mism = mism + 1;
        $display("D1 MISMATCH: op wr=%b rd=%b wd=%h -> got f=%b e=%b d=%h, want f=%b e=%b d=%h",
                 w, r, wd, full1, empty1, rdata1, exp_full, exp_empty, exp_rdata);
      end
    end
  endtask

  initial begin
    mism = 0;
    // Reset: hold 3 clocks, then check the reset state.
    rst_n = 1'b0;
    repeat (3) @(posedge clk); #1;
    if (full !== 1'b0 || empty !== 1'b1 || rdata !== {W{1'b0}}) begin
      mism = mism + 1;
      $display("RESET MISMATCH: full=%b empty=%b rdata=%h", full, empty, rdata);
    end
    if (full1 !== 1'b0 || empty1 !== 1'b1 || rdata1 !== 4'h0) begin
      mism = mism + 1;
      $display("RESET MISMATCH D1: full=%b empty=%b rdata=%h", full1, empty1, rdata1);
    end
    rst_n = 1'b1;

    // Main instance vs golden vectors.
    if (!$value$plusargs("VEC=%s", vecpath)) vecpath = "vectors_fifo.txt";
    fd = $fopen(vecpath, "r");
    if (fd == 0) begin
      $display("FATAL: cannot open %s (pass +VEC=path)", vecpath);
      $fatal(1);
    end
    if ($fscanf(fd, "%d", nvec) != 1) begin
      $display("FATAL: bad vector count");
      $fatal(1);
    end
    for (i = 0; i < nvec; i = i + 1) begin
      if ($fscanf(fd, "%d %d %x %d %d %x",
                  v_wr, v_rd, v_wdata, v_full, v_empty, v_rdata) != 6) begin
        $display("FATAL: short vectors file at row %0d", i);
        $fatal(1);
      end
      @(negedge clk);
      wr = v_wr[0]; rd = v_rd[0]; wdata = v_wdata[W-1:0];
      @(posedge clk); #1;
      if (full !== v_full[0] || empty !== v_empty[0] ||
          rdata !== v_rdata[W-1:0]) begin
        mism = mism + 1;
        if (mism < 20)
          $display("MISMATCH row %0d: op wr=%b rd=%b wd=%h -> got f=%b e=%b d=%h, want f=%b e=%b d=%h",
                   i, v_wr[0], v_rd[0], v_wdata[W-1:0],
                   full, empty, rdata, v_full[0], v_empty[0], v_rdata[W-1:0]);
      end
    end
    $fclose(fd);
    wr = 1'b0; rd = 1'b0;

    // Degenerate D=1 directed sequence on dut1 (idle until now: still empty).
    apply1(1'b1, 1'b0, 4'hA, 1'b1, 1'b0, 4'hA);   // write -> full, FWFT head
    apply1(1'b1, 1'b0, 4'hB, 1'b1, 1'b0, 4'hA);   // write into full: ignored
    apply1(1'b1, 1'b1, 4'hC, 1'b0, 1'b1, 4'h0);   // simul at full: pop only
    apply1(1'b1, 1'b1, 4'hD, 1'b1, 1'b0, 4'hD);   // simul on empty: write wins
    apply1(1'b0, 1'b1, 4'h0, 1'b0, 1'b1, 4'h0);   // drain -> empty, rdata 0
    apply1(1'b0, 1'b1, 4'h0, 1'b0, 1'b1, 4'h0);   // read from empty: ignored
    apply1(1'b0, 1'b0, 4'h0, 1'b0, 1'b1, 4'h0);   // idle holds state

    $display("FIFO_TB vectors=%0d mismatches=%0d", nvec, mism);
    if (mism != 0) $fatal(1, "FIFO_TB FAIL");
    else $display("FIFO_TB PASS");
    $finish;
  end
endmodule
