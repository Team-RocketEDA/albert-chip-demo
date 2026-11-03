// tb_irq_sync — RED/GREEN unit bench for irq_sync (plan step 4).
// Oracle: vectors_irq.txt from the independent pure-python golden
// gen_golden.py (never the RTL). Each cycle: TB waits for negedge, delays
// offset_ns (1..9, genuinely async to clk), drives irq_async, then samples
// irq #1 after the next posedge. Expected = async from 2 cycles earlier.
// Run: iverilog -g2012 -o /tmp/irq_sim src/components/irq_sync.v
//        src/tb/irq_sync/tb_irq_sync.v && vvp /tmp/irq_sim +VEC=<vectors>
`timescale 1ns / 1ps

module tb_irq_sync;
  reg  clk = 1'b0;
  reg  irq_async = 1'b0;
  wire irq;

  always #5 clk = ~clk;

  irq_sync dut (.clk(clk), .irq_async(irq_async), .irq(irq));

  integer fd, nvec, i, mism;
  integer v_val, v_off, v_exp;
  string vecpath;

  initial begin
    mism = 0;
    irq_async = 1'b0;
    // Two idle clocks so the flops settle to the known 0 state.
    repeat (2) @(posedge clk); #1;
    if (irq !== 1'b0) begin
      mism = mism + 1;
      $display("SETTLE MISMATCH: irq=%b, want 0", irq);
    end

    if (!$value$plusargs("VEC=%s", vecpath)) vecpath = "vectors_irq.txt";
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
      if ($fscanf(fd, "%d %d %d", v_val, v_off, v_exp) != 3) begin
        $display("FATAL: short vectors file at row %0d", i);
        $fatal(1);
      end
      @(negedge clk);
      #(v_off[31:0]);               // async w.r.t. clk: 1..9 ns after negedge
      irq_async = v_val[0];
      @(posedge clk); #1;
      if (irq !== v_exp[0]) begin
        mism = mism + 1;
        if (mism < 20)
          $display("MISMATCH row %0d: async=%b off=%0d -> irq=%b, want %b",
                   i, v_val[0], v_off[31:0], irq, v_exp[0]);
      end
    end
    $fclose(fd);

    $display("IRQ_TB vectors=%0d mismatches=%0d", nvec, mism);
    if (mism != 0) $fatal(1, "IRQ_TB FAIL");
    else $display("IRQ_TB PASS");
    $finish;
  end
endmodule
