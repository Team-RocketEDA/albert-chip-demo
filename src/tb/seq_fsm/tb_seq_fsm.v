// tb_seq_fsm — sequencer testbench (step 6, RED-capable: elaborates on the
// skeleton, fails in sim because outputs are undriven).
// Oracle: expected.hex packed words from gen_golden.py (independent stdlib
// python model seeded by baked checkpoint bytes). Stimulus replayed from
// stim.txt ("rst prefill row tile frame" per step). Per-step invariant
// checks: phase_sel one-hot, layer_idx < 30, cal_addr layer5b format.
`timescale 1ns / 1ps
module tb_seq_fsm;
  localparam MAXSTEPS = 2048;

  reg clk = 0;
  always #5 clk = ~clk;

  reg rst_n;
  reg irq_row_done, irq_tile_done, irq_frame_done, prefill;
  wire [3:0] phase_sel;
  wire [4:0] layer_idx;
  wire [22:0] cal_addr;
  wire [5:0] fifo_lane_en_ilp, fifo_lane_en_olp;
  wire fifo_rd, layer_done;

  seq_fsm dut (
    .clk(clk), .rst_n(rst_n),
    .irq_row_done(irq_row_done), .irq_tile_done(irq_tile_done),
    .irq_frame_done(irq_frame_done), .prefill(prefill),
    .phase_sel(phase_sel), .layer_idx(layer_idx), .cal_addr(cal_addr),
    .fifo_lane_en_ilp(fifo_lane_en_ilp),
    .fifo_lane_en_olp(fifo_lane_en_olp),
    .fifo_rd(fifo_rd), .layer_done(layer_done)
  );

  reg s_rst [0:MAXSTEPS-1];
  reg s_pf [0:MAXSTEPS-1];
  reg s_row [0:MAXSTEPS-1];
  reg s_tile [0:MAXSTEPS-1];
  reg s_frame [0:MAXSTEPS-1];
  reg [39:0] exp_mem [0:MAXSTEPS-1];
  reg [39:0] got;
  integer n, i, errs, fd, rc;
  integer b_rst, b_pf, b_row, b_tile, b_frame;

  initial begin
    $readmemh("src/tb/seq_fsm/expected.hex", exp_mem);
    fd = $fopen("src/tb/seq_fsm/stim.txt", "r");
    if (fd == 0) begin $display("FAIL cannot open stim.txt"); $fatal; end
    n = 0;
    while ($fscanf(fd, "%d %d %d %d %d\n",
                   b_rst, b_pf, b_row, b_tile, b_frame) == 5) begin
      s_rst[n] = b_rst[0]; s_pf[n] = b_pf[0]; s_row[n] = b_row[0];
      s_tile[n] = b_tile[0]; s_frame[n] = b_frame[0];
      n = n + 1;
    end
    $fclose(fd);
    $display("tb_seq_fsm: steps=%0d", n);

    rst_n = 0; prefill = 1;
    irq_row_done = 0; irq_tile_done = 0; irq_frame_done = 0;
    errs = 0;
    for (i = 0; i < n; i = i + 1) begin
      @(negedge clk);
      rst_n = ~s_rst[i];
      prefill = s_pf[i];
      irq_row_done = s_row[i];
      irq_tile_done = s_tile[i];
      irq_frame_done = s_frame[i];
      @(posedge clk); #1;
      got = {3'b0, layer_done, fifo_rd,
             fifo_lane_en_olp, fifo_lane_en_ilp,
             phase_sel, layer_idx, cal_addr[13:0]};
      if (got !== exp_mem[i]) begin
        $display("FAIL step=%0d got=%010h want=%010h (L=%0d P=%b cal=%06h)",
                 i, got, exp_mem[i], layer_idx, phase_sel, cal_addr);
        errs = errs + 1;
        if (errs > 20) begin $display("FAIL too many errors"); $fatal; end
      end
      if (!$onehot(phase_sel)) begin
        $display("FAIL step=%0d phase_sel not one-hot: %b", i, phase_sel);
        errs = errs + 1;
      end
      if (!(layer_idx < 5'd30)) begin
        $display("FAIL step=%0d layer_idx out of range: %0d", i, layer_idx);
        errs = errs + 1;
      end
      if (cal_addr[22:18] !== layer_idx) begin
        $display("FAIL step=%0d cal_addr layer field %h != layer %0d",
                 i, cal_addr[22:18], layer_idx);
        errs = errs + 1;
      end
    end

    if (errs == 0) $display("PASS tb_seq_fsm steps=%0d", n);
    else begin $display("FAIL tb_seq_fsm errs=%0d", errs); $fatal; end
    $finish;
  end

  // Watchdog: the skeleton never drives outputs, so a hung run still ends.
  initial begin
    #5000000;
    $display("FAIL tb_seq_fsm watchdog timeout");
    $fatal;
  end
endmodule
