// tb_rmsnorm_stage_stitch — stitch test for rmsnorm_stage (S=64, H=576).
// Contract: architecture/blocks/05-rmsnorm.md. Oracle: baked checkpoint
// bytes weights/bake/tv_rmsnorm_{in,golden}.hex (+ gamma_q88.hex /
// sat_row_golden.hex from gen_vectors.py in this dir, same oracle).
// Entry: s8 stimulus; DUT widens s8<<8, resid saturate-then-add, streams
// 64 rows = 64 frames through rmsnorm_d (D=576), FXP16 y_out frame,
// requant exit narrow to int8, tbuf store.
// RED-capable: on the skeleton y_out floats (X) and y_valid is the raw
// leaf free-run (never 64/row strobes) -> FAIL.
// Run from repo root (GREEN, wired DUT):
//   iverilog -g2012 -DSTITCH_YQ -o /tmp/tb_rmsnorm_stage \
//     src/components/*.v src/tb/rmsnorm_stage_stitch/tb_rmsnorm_stage_stitch.v \
//     && vvp /tmp/tb_rmsnorm_stage
// RED (skeleton check, no STITCH_YQ: hierarchical refs stay out):
//   iverilog -g2012 -o /tmp/tb_rmsnorm_stage_red \
//     src/components/*.v src/tb/rmsnorm_stage_stitch/tb_rmsnorm_stage_stitch.v \
//     && vvp /tmp/tb_rmsnorm_stage_red   (expect FAIL)
`timescale 1ns / 1ps
module tb_rmsnorm_stage_stitch;
  localparam S = 64;
  localparam H = 576;
  localparam N = S * H;
  localparam TOL = 3; // LSB, same budget as the rmsnorm_d leaf tb

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [N*8-1:0]  x_in = 0;
  reg  [N*8-1:0]  resid_in = 0;
  reg             in_valid = 0;
  wire            in_ready;
  wire [N*16-1:0] y_out;
  wire            y_valid;

  rmsnorm_stage #(.S(S), .H(H)) dut (
    .clk(clk), .rst_n(rst_n),
    .x_in(x_in), .resid_in(resid_in),
    .in_valid(in_valid), .in_ready(in_ready),
    .y_out(y_out), .y_valid(y_valid)
  );

  reg [7:0]  s8row [0:H-1];   // baked s8 stimulus row
  reg [15:0] golden [0:H-1];  // baked Q8.8 golden row
  reg [15:0] satgold [0:H-1]; // saturation-corner golden row0
  integer r, c, i, errs, tot_errs, strobes, cyc, diff;
  reg [15:0] ylane;
  reg [7:0]  exp8;

  task drive_phase(input integer mode);
    // mode 0: every row = baked s8 row, resid 0
    // mode 1: all-zero frame (x=resid=0)
    // mode 2: row0 lane0 x=resid=0x7F (sat corner), rest zero
    begin
      x_in = 0;
      resid_in = 0;
      if (mode == 0) begin
        for (r = 0; r < S; r = r + 1)
          for (c = 0; c < H; c = c + 1)
            x_in[(r*H+c)*8 +: 8] = s8row[c];
      end else if (mode == 2) begin
        x_in[0*8 +: 8] = 8'h7f;
        resid_in[0*8 +: 8] = 8'h7f;
      end
    end
  endtask

  task run_frame;
    begin
      @(posedge clk); #1;
      if (in_ready !== 1'b1) begin
        $display("FAIL: in_ready=%b want 1 before in_valid", in_ready);
        tot_errs = tot_errs + 1;
      end
      in_valid = 1'b1;
      @(posedge clk); #1;
      in_valid = 1'b0;
      strobes = 0;
      cyc = 0;
      while (strobes < S && cyc < 100000) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
        if (y_valid === 1'b1) begin
          strobes = strobes + 1;
          if (strobes % 16 == 0) $display("progress strobes=%0d cyc=%0d", strobes, cyc);
        end
        else if (y_valid !== 1'b0) begin
          $display("FAIL: y_valid=X/Z at cyc=%0d", cyc);
          tot_errs = tot_errs + 1;
        end
      end
      if (strobes !== S) begin
        $display("FAIL: y_valid strobes=%0d want=%0d (cyc=%0d)", strobes, S, cyc);
        tot_errs = tot_errs + 1000;
      end
      // Quiesce: no extra strobes after the frame.
      repeat (20) @(posedge clk);
      #1;
      if (y_valid !== 1'b0) begin
        $display("FAIL: y_valid not idle after frame (%b)", y_valid);
        tot_errs = tot_errs + 1;
      end
    end
  endtask

  initial begin
    $readmemh("weights/bake/tv_rmsnorm_in.hex", s8row);
    $readmemh("weights/bake/tv_rmsnorm_golden.hex", golden);
    $readmemh("src/tb/rmsnorm_stage_stitch/sat_row_golden.hex", satgold);
    tot_errs = 0;

    @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- Phase A: 64 identical golden rows, resid=0 ----
    drive_phase(0);
    run_frame();
    errs = 0;
    for (r = 0; r < S; r = r + 1)
      for (c = 0; c < H; c = c + 1) begin
        ylane = y_out[(r*H+c)*16 +: 16];
        if (^ylane === 1'bx) begin
          if (errs < 5)
            $display("FAIL phaseA row%0d lane%0d y undriven (skeleton?)", r, c);
          errs = errs + 1;
        end else begin
          diff = $signed(ylane) - $signed(golden[c]);
          if (diff < 0) diff = -diff;
          if (diff > TOL) begin
            if (errs < 8)
              $display("FAIL phaseA row%0d lane%0d got=%h(%0d) want=%h(%0d) err=%0d",
                       r, c, ylane, $signed(ylane),
                       golden[c], $signed(golden[c]), diff);
            errs = errs + 1;
          end
        end
      end
    $display("phaseA golden x64 done errs=%0d", errs);
    tot_errs = tot_errs + errs;

`ifdef STITCH_YQ
    // Exit requant: yq int8 must equal clip(y>>8) exactly (scale=1.0).
    errs = 0;
    for (r = 0; r < S; r = r + 1)
      for (c = 0; c < H; c = c + 1) begin
        ylane = y_out[(r*H+c)*16 +: 16];
        exp8 = $signed(ylane) >>> 8;
        if (dut.yq_mem[r*H+c] !== exp8) begin
          if (errs < 8)
            $display("FAIL phaseA requant row%0d lane%0d got=%h want=%h (y=%h)",
                     r, c, dut.yq_mem[r*H+c], exp8, ylane);
          errs = errs + 1;
        end
      end
    $display("phaseA requant narrow done errs=%0d", errs);
    tot_errs = tot_errs + errs;
    // Tbuf store: spot-check bank0 rows 0/63 lanes 0/575 + a mid lane.
    errs = 0;
    if (dut.u_tbuf.mem[0] !== y_out[0*16 +: 16]) begin
      $display("FAIL tbuf addr0 got=%h want=%h", dut.u_tbuf.mem[0], y_out[0*16+:16]);
      errs = errs + 1;
    end
    if (dut.u_tbuf.mem[575] !== y_out[575*16 +: 16]) begin
      $display("FAIL tbuf addr575 got=%h want=%h", dut.u_tbuf.mem[575], y_out[575*16+:16]);
      errs = errs + 1;
    end
    if (dut.u_tbuf.mem[63*H+100] !== y_out[(63*H+100)*16 +: 16]) begin
      $display("FAIL tbuf addr%0d", 63*H+100);
      errs = errs + 1;
    end
    $display("phaseA tbuf store done errs=%0d", errs);
    tot_errs = tot_errs + errs;
`endif

    // ---- Phase B: all-zero frame -> all-zero y exactly ----
    rst_n = 0; repeat (2) @(posedge clk); #1; rst_n = 1;
    repeat (2) @(posedge clk);
    drive_phase(1);
    run_frame();
    errs = 0;
    for (i = 0; i < N; i = i + 1) begin
      ylane = y_out[i*16 +: 16];
      if (^ylane === 1'bx) begin
        if (errs < 5) $display("FAIL phaseB lane%0d undriven", i);
        errs = errs + 1;
      end else if (ylane !== 16'h0000) begin
        if (errs < 8) $display("FAIL phaseB lane%0d y=%h want=0000", i, ylane);
        errs = errs + 1;
      end
    end
    $display("phaseB zero frame done errs=%0d", errs);
    tot_errs = tot_errs + errs;

    // ---- Phase C: saturation corner (row0 lane0 x=resid=0x7F) ----
    rst_n = 0; repeat (2) @(posedge clk); #1; rst_n = 1;
    repeat (2) @(posedge clk);
    drive_phase(2);
    run_frame();
    errs = 0;
    for (c = 0; c < H; c = c + 1) begin
      ylane = y_out[c*16 +: 16];
      if (^ylane === 1'bx) begin
        if (errs < 5) $display("FAIL phaseC lane%0d undriven", c);
        errs = errs + 1;
      end else begin
        diff = $signed(ylane) - $signed(satgold[c]);
        if (diff < 0) diff = -diff;
        if (diff > TOL) begin
          if (errs < 8)
            $display("FAIL phaseC lane%0d got=%h(%0d) want=%h(%0d) err=%0d",
                     c, ylane, $signed(ylane),
                     satgold[c], $signed(satgold[c]), diff);
          errs = errs + 1;
        end
      end
    end
    for (i = H; i < N; i = i + 1) begin
      ylane = y_out[i*16 +: 16];
      if (ylane !== 16'h0000) begin
        if (errs < 12) $display("FAIL phaseC row%0d lane%0d y=%h want=0000",
                                i / H, i % H, ylane);
        errs = errs + 1;
      end
    end
    $display("phaseC saturation corner done errs=%0d", errs);
    tot_errs = tot_errs + errs;

    if (tot_errs == 0)
      $display("RMSNORM_STAGE PASS (64-row golden + zero + sat, tol=%0d LSB)", TOL);
    else
      $display("RMSNORM_STAGE FAIL (%0d errs)", tot_errs);
    $finish;
  end
endmodule
