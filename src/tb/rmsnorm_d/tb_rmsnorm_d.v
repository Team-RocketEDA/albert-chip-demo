// tb_rmsnorm_d — self-checking unit test for rmsnorm_d.
// Oracle: weights/bake/tv_rmsnorm_golden.hex (baked checkpoint bytes,
// seed 0xB0C9, resid=0, eps=1e-5, gamma=baked dequant; cross-checked by
// src/tb/rmsnorm_d/gen_golden.py). Stimulus Q8.8 (PARAMS boundary rule).
// RED-capable: on the skeleton y is undriven (X) -> FAIL.
// Protocol: the DUT resets into end-of-frame, so every frame (including
// the first) presents lane0 exactly one clock after its boundary: one
// dead negedge, then lane0, then lanes 1..575 at one per negedge.
// LOAD takes 576 clocks, CALC+NR+DENORM 6, OUT streams 576 y with
// y_valid. Frames run back-to-back with no idle.
// Run from repo root:
//   iverilog -o /tmp/tb_rmsnorm_d src/components/rmsnorm_d.v src/tb/rmsnorm_d/tb_rmsnorm_d.v && vvp /tmp/tb_rmsnorm_d
`timescale 1ns / 1ps
module tb_rmsnorm_d;
  localparam D = 576;
  localparam TOL = 3; // LSB; measured worst 1 (gamma-quant 0.8 + rtl 1)

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [15:0] x = 0, resid = 0, gamma = 0;
  wire [15:0] y;
  wire        y_valid;

  rmsnorm_d #(.W(16)) dut (
    .clk(clk), .rst_n(rst_n), .x(x), .resid(resid),
    .gamma(gamma), .y(y), .y_valid(y_valid)
  );

  reg [15:0] sx [0:D-1];
  reg [15:0] sg [0:D-1];
  reg [15:0] golden [0:D-1];
  reg [15:0] sdx [0:D-1];
  reg [15:0] sdr [0:D-1];
  reg [15:0] sdg [0:D-1];
  reg [15:0] goldd [0:D-1];
  reg [15:0] got0 [0:D-1];
  reg [15:0] got1 [0:D-1];
  integer i, errs, diff, pulses, cyc;

  // One lane per negedge. The DUT resets into end-of-frame and the
  // OUT->LOAD edge cycle samples nothing, so lane0 of every frame is
  // simply the first drive after the boundary (reset release or the
  // previous collect loop's exit, both at a negedge).
  task drive_lane(input [15:0] tx, input [15:0] tr, input [15:0] tg);
    begin
      @(negedge clk);
      x = tx; resid = tr; gamma = tg;
    end
  endtask

  initial begin
    $readmemh("src/tb/rmsnorm_d/stim_x.hex", sx);
    $readmemh("src/tb/rmsnorm_d/stim_g.hex", sg);
    $readmemh("weights/bake/tv_rmsnorm_golden.hex", golden);
    $readmemh("src/tb/rmsnorm_d/stim_d_x.hex", sdx);
    $readmemh("src/tb/rmsnorm_d/stim_d_r.hex", sdr);
    $readmemh("src/tb/rmsnorm_d/stim_d_g.hex", sdg);
    $readmemh("src/tb/rmsnorm_d/gold_d.hex", goldd);
    errs = 0;
    @(negedge clk);
    rst_n = 1;

    // Phase A: golden frame, resid=0.
    for (i = 0; i < D; i = i + 1) drive_lane(sx[i], 16'h0000, sg[i]);
    pulses = 0; cyc = 0;
    while (pulses < D && cyc < 2000) begin
      @(negedge clk);
      cyc = cyc + 1;
      x = 16'h0000; resid = 16'h0000; gamma = 16'h0000;
      if (y_valid === 1'b1) begin
        got0[pulses] = y;
        pulses = pulses + 1;
      end
    end
    if (pulses !== D) begin
      $display("FAIL phaseA: y_valid pulses=%0d want=%0d", pulses, D);
      errs = errs + 1000;
    end
    for (i = 0; i < D; i = i + 1) begin
      if (^got0[i] === 1'bx) begin
        if (errs < 5)
          $display("FAIL phaseA lane%0d y undriven (skeleton?)", i);
        errs = errs + 1;
      end else begin
        diff = $signed(got0[i]) - $signed(golden[i]);
        if (diff < 0) diff = -diff;
        if (diff > TOL) begin
          if (errs < 8)
            $display("FAIL phaseA lane%0d got=%h(%0d) want=%h(%0d) err=%0d",
                     i, got0[i], $signed(got0[i]),
                     golden[i], $signed(golden[i]), diff);
          errs = errs + 1;
        end
      end
    end
    $display("phaseA golden frame done errs=%0d", errs);

    // Phase B: back-to-back repeat frame; framing must be exact and the
    // second result must match the first (determinism across frames).
    for (i = 0; i < D; i = i + 1) drive_lane(sx[i], 16'h0000, sg[i]);
    pulses = 0; cyc = 0;
    while (pulses < D && cyc < 2000) begin
      @(negedge clk);
      cyc = cyc + 1;
      x = 16'h0000; resid = 16'h0000; gamma = 16'h0000;
      if (y_valid === 1'b1) begin
        got1[pulses] = y;
        pulses = pulses + 1;
      end
    end
    if (pulses !== D) begin
      $display("FAIL phaseB: y_valid pulses=%0d want=%0d", pulses, D);
      errs = errs + 1000;
    end
    for (i = 0; i < D; i = i + 1)
      if (got1[i] !== got0[i]) begin
        if (errs < 1010)
          $display("FAIL phaseB lane%0d f1=%h f2=%h (nondeterministic)",
                   i, got0[i], got1[i]);
        errs = errs + 1;
      end
    $display("phaseB repeat frame done errs=%0d", errs);

    // Phase C: all-zero frame -> all-zero y exactly, framing intact.
    for (i = 0; i < D; i = i + 1) drive_lane(16'h0000, 16'h0000, 16'h0000);
    pulses = 0; cyc = 0;
    while (pulses < D && cyc < 2000) begin
      @(negedge clk);
      cyc = cyc + 1;
      if (y_valid === 1'b1) begin
        if (y !== 16'h0000) begin
          if (errs < 1020)
            $display("FAIL phaseC lane%0d y=%h want=0000", pulses, y);
          errs = errs + 1;
        end
        pulses = pulses + 1;
      end
    end
    if (pulses !== D) begin
      $display("FAIL phaseC: y_valid pulses=%0d want=%0d", pulses, D);
      errs = errs + 1000;
    end
    $display("phaseC zero frame done errs=%0d", errs);

    // Phase D: residual saturation corner (black-box): lane0 x=resid=
    // 0x7000 saturates t to 0x7fff; golden is float RMSNorm over the
    // saturated lanes (gen_golden.py). Catches a missing/wrong sat16.
    for (i = 0; i < D; i = i + 1) drive_lane(sdx[i], sdr[i], sdg[i]);
    pulses = 0; cyc = 0;
    while (pulses < D && cyc < 3000) begin
      @(negedge clk);
      cyc = cyc + 1;
      x = 16'h0000; resid = 16'h0000; gamma = 16'h0100;
      if (y_valid === 1'b1) begin
        got0[pulses] = y;
        pulses = pulses + 1;
      end
    end
    if (pulses !== D) begin
      $display("FAIL phaseD: y_valid pulses=%0d want=%0d", pulses, D);
      errs = errs + 1000;
    end
    for (i = 0; i < D; i = i + 1) begin
      if (^got0[i] === 1'bx) begin
        if (errs < 1025)
          $display("FAIL phaseD lane%0d y undriven", i);
        errs = errs + 1;
      end else begin
        diff = $signed(got0[i]) - $signed(goldd[i]);
        if (diff < 0) diff = -diff;
        if (diff > TOL) begin
          if (errs < 1030)
            $display("FAIL phaseD lane%0d got=%h(%0d) want=%h(%0d) err=%0d",
                     i, got0[i], $signed(got0[i]),
                     goldd[i], $signed(goldd[i]), diff);
          errs = errs + 1;
        end
      end
    end
    $display("phaseD saturation corner done errs=%0d", errs);

    if (errs == 0) $display("RMSNORM PASS (576-lane golden + repeat + zero + sat, tol=%0d LSB)", TOL);
    else           $display("RMSNORM FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
