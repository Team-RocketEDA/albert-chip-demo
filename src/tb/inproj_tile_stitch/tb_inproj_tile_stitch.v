// tb_inproj_tile_stitch.v — stitch test for inproj_tile (L1.2, 02-inproj-tile.md).
//
// What it proves (sim covers wiring; leaves already proven by their own sbys):
//  1. Chunk-folded MAC (C=256: 2x256 + 64-tail over K=576, P=32 K-fold with
//     acc_in fold) reproduces the baked s32 goldens exactly:
//     dut.u_accum.mem[0..7]     == tv_q_golden (act = tv_q_act, Q weights)
//     dut.u_accum.mem[576..583] == tv_k_golden (act = tv_k_act, K weights)
//     dut.u_accum.mem[768..775] == tv_v_golden (act = tv_v_act, V weights)
//     Full-frame cross-check: an independent tb-side oracle recomputes ALL
//     960 s32 dots + requant clip and compares dut accum (all 960) and every
//     y_out byte. The golden files anchor the oracle (first-8 must match).
//  2. No bias: golden equality itself (any added bias would offset every dot).
//  3. MAC wraps mod-2^32, never saturates: accum holds exact s32 goldens
//     (e.g. -68981) while the same channel's y_out byte saturates to 0x80 —
//     saturation lives in requant only.
//  4. y_valid exactly per packed row/frame: exactly one 1-cycle pulse per
//     accepted tok_valid, low otherwise; tok_ready low while busy.
//  5. Packed thirds: y_out = Q[0:575] | K[576:767] | V[768:959] per row;
//     S=2 instance proves multi-row packing (both rows = tv_q_act).
//
// Protocol: tb holds tok_in stable through the frame; tok_valid is a single
// cycle pulse issued while tok_ready==1. cfg_scale=256 (Q8.8 x1.0),
// cfg_zero=0, so y = clip_int8(acc).
// Run from the repo root (all $readmemh paths are repo-root-relative):
//   iverilog -g2012 -o /tmp/inproj.vvp <components...> \
//     src/tb/inproj_tile_stitch/tb_inproj_tile_stitch.v && vvp /tmp/inproj.vvp
`timescale 1ns/1ps
module tb_inproj_tile_stitch;
  localparam H = 576, KV = 192, NO = 960, IN = 576;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg [15:0] cfg_scale = 16'd256; // Q8.8 x1.0
  reg [15:0] cfg_zero = 16'd0;

  // ---- DUT, S=1 ----
  reg  [1*H*8-1:0]      tok_in1 = 0;
  reg                   tok_valid1 = 0;
  wire                  tok_ready1;
  wire [1*NO*8-1:0]     y_out1;
  wire                  y_valid1;
  inproj_tile #(.S(1)) dut1 (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in1), .tok_valid(tok_valid1),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(tok_ready1), .y_out(y_out1), .y_valid(y_valid1)
  );

  // ---- DUT, S=2 (packed-row check) ----
  reg  [2*H*8-1:0]      tok_in2 = 0;
  reg                   tok_valid2 = 0;
  wire                  tok_ready2;
  wire [2*NO*8-1:0]     y_out2;
  wire                  y_valid2;
  inproj_tile #(.S(2)) dut2 (
    .clk(clk), .rst_n(rst_n),
    .tok_in(tok_in2), .tok_valid(tok_valid2),
    .cfg_scale(cfg_scale), .cfg_zero(cfg_zero),
    .tok_ready(tok_ready2), .y_out(y_out2), .y_valid(y_valid2)
  );

  // ---- stimulus / golden / weight images (repo-root-relative) ----
  reg [7:0]  act_q [0:575], act_k [0:575], act_v [0:575];
  reg [31:0] gq [0:7], gk [0:7], gv [0:7];
  reg [7:0]  Wq [0:331775], Wk [0:110591], Wv [0:110591];
  reg [7:0]  act_use [0:575];
  integer    exp_acc [0:959];
  reg [7:0]  exp_y [0:959];

  integer errs = 0;

  function [7:0] clip8(input integer v);
    begin
      if (v > 127) clip8 = 8'h7f;
      else if (v < -128) clip8 = 8'h80;
      else clip8 = v[7:0];
    end
  endfunction

  // Independent oracle: exact s32 dots (wrap mod-2^32) + requant clip.
  task compute_oracle;
    integer j, k;
    integer s;
    reg signed [63:0] prod, shr, biased;
    begin
      for (j = 0; j < NO; j = j + 1) begin
        s = 0;
        for (k = 0; k < IN; k = k + 1) begin
          if (j < H)
            s = s + $signed(act_use[k]) * $signed(Wq[j*IN+k]);
          else if (j < H+KV)
            s = s + $signed(act_use[k]) * $signed(Wk[(j-H)*IN+k]);
          else
            s = s + $signed(act_use[k]) * $signed(Wv[(j-H-KV)*IN+k]);
        end
        exp_acc[j] = s;
        prod = s;
        prod = prod * $signed(cfg_scale);
        shr = prod >>> 8;
        biased = shr + $signed(cfg_zero);
        if (biased > 127) exp_y[j] = 8'h7f;
        else if (biased < -127-1) exp_y[j] = 8'h80;
        else exp_y[j] = biased[7:0];
      end
    end
  endtask

  task check_golden_anchor(input integer which);
    integer j;
    begin
      for (j = 0; j < 8; j = j + 1) begin
        if (which == 0 && exp_acc[j] !== $signed(gq[j])) begin
          $display("MISMATCH oracle-Q vs golden j=%0d oracle=%h golden=%h",
                   j, exp_acc[j], gq[j]);
          errs = errs + 1;
        end
        if (which == 1 && exp_acc[H+j] !== $signed(gk[j])) begin
          $display("MISMATCH oracle-K vs golden j=%0d oracle=%h golden=%h",
                   j, exp_acc[H+j], gk[j]);
          errs = errs + 1;
        end
        if (which == 2 && exp_acc[H+KV+j] !== $signed(gv[j])) begin
          $display("MISMATCH oracle-V vs golden j=%0d oracle=%h golden=%h",
                   j, exp_acc[H+KV+j], gv[j]);
          errs = errs + 1;
        end
      end
    end
  endtask

  initial begin
    $readmemh("weights/bake/tv_q_act.hex", act_q);
    $readmemh("weights/bake/tv_k_act.hex", act_k);
    $readmemh("weights/bake/tv_v_act.hex", act_v);
    $readmemh("weights/bake/tv_q_golden.hex", gq);
    $readmemh("weights/bake/tv_k_golden.hex", gk);
    $readmemh("weights/bake/tv_v_golden.hex", gv);
    $readmemh("weights/bake/layer0_q_proj.hex", Wq);
    $readmemh("weights/bake/layer0_k_proj.hex", Wk);
    $readmemh("weights/bake/layer0_v_proj.hex", Wv);
    #12 rst_n = 1;
    @(negedge clk);

    run_frame1(0); // act_q: Q accum == tv_q_golden
    run_frame1(1); // act_k: K accum == tv_k_golden
    run_frame1(2); // act_v: V accum == tv_v_golden
    run_frame2();  // S=2 packing, both rows act_q

    #20;
    if (errs == 0)
      $display("INPROJ_STITCH PASS (frames=4 rows=5 thirds=Q|K|V thirds-ok)");
    else
      $display("INPROJ_STITCH FAIL (%0d errs)", errs);
    $finish;
  end

  // Watchdog: ~40k cycles/row worst case; 5 rows need < 1M cycles.
  initial begin
    #20000000;
    $display("INPROJ_STITCH FAIL timeout");
    $finish;
  end

  task run_frame1(input integer which);
    integer b, j, pulses, guard;
    reg [7:0] got;
    begin
      // select stimulus
      for (b = 0; b < 576; b = b + 1) begin
        if (which == 0) act_use[b] = act_q[b];
        else if (which == 1) act_use[b] = act_k[b];
        else act_use[b] = act_v[b];
        tok_in1[b*8 +: 8] = act_use[b];
      end
      compute_oracle();
      check_golden_anchor(which);

      // wait ready, issue single-cycle tok_valid
      guard = 0;
      while (tok_ready1 !== 1'b1 && guard < 1000) begin
        @(posedge clk); guard = guard + 1;
      end
      if (tok_ready1 !== 1'b1) begin
        $display("MISMATCH frame%0d: ready never rose", which);
        errs = errs + 1;
      end
      @(negedge clk); tok_valid1 = 1'b1;
      @(negedge clk); tok_valid1 = 1'b0;

      // busy: ready must drop; inject a spurious tok_valid (must be ignored)
      pulses = 0; guard = 0;
      repeat (50) @(posedge clk);
      if (tok_ready1 !== 1'b0) begin
        $display("MISMATCH frame%0d: ready did not drop while busy", which);
        errs = errs + 1;
      end
      @(negedge clk); tok_valid1 = 1'b1;
      @(negedge clk); tok_valid1 = 1'b0;
      while (tok_ready1 !== 1'b1 && guard < 500000) begin
        @(posedge clk);
        if (y_valid1 === 1'b1) pulses = pulses + 1;
        guard = guard + 1;
      end
      if (tok_ready1 !== 1'b1) begin
        $display("MISMATCH frame%0d: frame never completed", which);
        errs = errs + 1;
      end
      if (pulses !== 1) begin
        $display("MISMATCH frame%0d: y_valid pulses=%0d want 1", which, pulses);
        errs = errs + 1;
      end

      // accum: all 960 exact s32 (MAC wraps, never saturates; no bias)
      for (j = 0; j < NO; j = j + 1) begin
        if (dut1.u_accum.mem[j] !== exp_acc[j][31:0]) begin
          if (errs < 10)
            $display("MISMATCH frame%0d accum[%0d]: got=%h want=%h",
                     which, j, dut1.u_accum.mem[j], exp_acc[j]);
          errs = errs + 1;
        end
      end
      // y_out: all 960 bytes requanted (saturation lives here only)
      for (j = 0; j < NO; j = j + 1) begin
        got = y_out1[j*8 +: 8];
        if (got !== exp_y[j]) begin
          if (errs < 10)
            $display("MISMATCH frame%0d y_out[%0d]: got=%h want=%h",
                     which, j, got, exp_y[j]);
          errs = errs + 1;
        end
      end
      // directed saturation corners from the golden row itself
      if (which == 0) begin
        // gold_q[2] = -68981 -> exact s32 kept, byte saturates to 0x80
        if (dut1.u_accum.mem[2] !== gq[2]) begin
          $display("MISMATCH wrap corner: accum[2]=%h want %h",
                   dut1.u_accum.mem[2], gq[2]);
          errs = errs + 1;
        end
        if (y_out1[2*8 +: 8] !== 8'h80) begin
          $display("MISMATCH sat corner: y_out[2]=%h want 80",
                   y_out1[2*8 +: 8]);
          errs = errs + 1;
        end
      end
      $display("frame%0d done pulses=%0d", which, pulses);
    end
  endtask

  task run_frame2;
    integer b, r, j, pulses, guard;
    reg [7:0] got;
    begin
      for (b = 0; b < 576; b = b + 1) act_use[b] = act_q[b];
      for (r = 0; r < 2; r = r + 1)
        for (b = 0; b < 576; b = b + 1)
          tok_in2[(r*576+b)*8 +: 8] = act_q[b];
      compute_oracle();
      check_golden_anchor(0);

      guard = 0;
      while (tok_ready2 !== 1'b1 && guard < 1000) begin
        @(posedge clk); guard = guard + 1;
      end
      @(negedge clk); tok_valid2 = 1'b1;
      @(negedge clk); tok_valid2 = 1'b0;
      pulses = 0; guard = 0;
      while (tok_ready2 !== 1'b1 && guard < 1000000) begin
        @(posedge clk);
        if (y_valid2 === 1'b1) pulses = pulses + 1;
        guard = guard + 1;
      end
      if (pulses !== 1) begin
        $display("MISMATCH S=2: y_valid pulses=%0d want 1", pulses);
        errs = errs + 1;
      end
      // accum holds the last row; both packed rows must match the oracle
      for (j = 0; j < NO; j = j + 1) begin
        if (dut2.u_accum.mem[j] !== exp_acc[j][31:0]) begin
          if (errs < 10)
            $display("MISMATCH S=2 accum[%0d]: got=%h want=%h",
                     j, dut2.u_accum.mem[j], exp_acc[j]);
          errs = errs + 1;
        end
      end
      for (r = 0; r < 2; r = r + 1)
        for (j = 0; j < NO; j = j + 1) begin
          got = y_out2[(r*NO+j)*8 +: 8];
          if (got !== exp_y[j]) begin
            if (errs < 10)
              $display("MISMATCH S=2 y_out row%0d[%0d]: got=%h want=%h",
                       r, j, got, exp_y[j]);
            errs = errs + 1;
          end
        end
      $display("frameS2 done pulses=%0d", pulses);
    end
  endtask
endmodule
