// tb_softmax_d — self-checking (step 9, RED-capable: elaborates on the
// skeleton, fails in sim because probs/probs_valid are undriven).
// Oracle: baked checkpoint floats via gen_golden.py (row0 = tv_softmax_stim
// seed 0xB0CB, LCG rows + directed edges), Q4.12, tolerance TOL_LSB.
// Pass A (causal=0): probs == plain softmax golden, row-sum ~= 4096.
// Pass B (causal=1): probs == prefix-softmax golden_causal (lanes past the
// accept-order row index read exactly 0), row-sum ~= 4096.
// S=64 smoke (compile with -DS_TB=64): directed uniform/one-hot/causal rows,
// structural checks only (no golden files).
// Run from repo root:
///   iverilog -o /tmp/tb_softmax_d src/components/softmax_d.v src/components/exp_lut.v src/components/div_unit.v src/tb/softmax_d/tb_softmax_d.v && vvp /tmp/tb_softmax_d
`timescale 1ns / 1ps
module tb_softmax_d;
`ifndef S_TB
  `define S_TB 8
`endif
  localparam S = `S_TB;
  localparam W = 16;
`ifndef TOL_OVR
  `define TOL_OVR 16
`endif
  localparam TOL_LSB = `TOL_OVR; // fixed tolerance: 16 LSB Q4.12 = 0.0039
  localparam NS8 = 24;       // rows in stim/golden hex (S=8 only)

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg [S*W-1:0] scores_flat = 0;
  reg scores_valid = 0;
  reg causal = 0;
  wire [S*W-1:0] probs_flat;
  wire probs_valid;

  softmax_d #(.W(W), .S(S)) dut (
    .clk(clk), .rst_n(rst_n),
    .scores(scores_flat), .scores_valid(scores_valid), .causal(causal),
    .probs(probs_flat), .probs_valid(probs_valid)
  );

  reg [15:0] stim_mem [0:NS8*8-1];
  reg [15:0] gold_mem [0:NS8*8-1];
  reg [15:0] gcsr_mem [0:NS8*8-1];
  reg [31:0] cnt_mem [0:0];

  integer i, j, r, n, errs, diff, run_sum, want_sum;
  reg [15:0] got_lane, want_lane;
  integer nrows;

  task automatic accept_row(input integer base);
    begin
      for (j = 0; j < S; j = j + 1)
        scores_flat[j*W +: W] = stim_mem[base + j];
      @(negedge clk);
      scores_valid = 1;
      @(negedge clk); // sampling posedge consumed the row
      scores_valid = 0;
      #1;
    end
  endtask

  initial begin
    errs = 0;
    if (S == 8) begin
      $readmemh("src/tb/softmax_d/stim.hex", stim_mem);
      $readmemh("src/tb/softmax_d/golden.hex", gold_mem);
      $readmemh("src/tb/softmax_d/golden_causal.hex", gcsr_mem);
      $readmemh("src/tb/softmax_d/vec_count.hex", cnt_mem);
      nrows = cnt_mem[0];
      if (nrows !== NS8) begin
        $display("SOFTMAX FAIL bad vec count %0d want %0d", nrows, NS8);
        $finish;
      end
    end else begin
      nrows = 0;
    end

    // Reset: outputs held 0, valid low.
    #12;
    if (probs_valid !== 1'b0) begin
      $display("SOFTMAX FAIL valid during reset = %b", probs_valid);
      errs = errs + 1;
    end
    rst_n = 1;
    @(negedge clk);

    if (S == 8) begin
      // ---- Pass A: causal=0, plain softmax ----
      causal = 0;
      for (r = 0; r < nrows; r = r + 1) begin
        accept_row(r * S);
        if (probs_valid !== 1'b1) begin
          $display("FAIL A row=%0d valid=%b want 1", r, probs_valid);
          errs = errs + 1;
        end
        if (^probs_flat === 1'bx) begin
          $display("FAIL A row=%0d probs undriven (skeleton)", r);
          errs = errs + 1;
        end else begin
          run_sum = 0;
          for (j = 0; j < S; j = j + 1) begin
            got_lane = probs_flat[j*W +: W];
            want_lane = gold_mem[r * S + j];
            run_sum = run_sum + $signed(got_lane);
            diff = $signed(got_lane) - $signed(want_lane);
            if (diff < 0) diff = -diff;
            if (diff > TOL_LSB) begin
              $display("FAIL A row=%0d lane=%0d got=%h(%0d) want=%h(%0d) err=%0d",
                       r, j, got_lane, $signed(got_lane),
                       want_lane, $signed(want_lane), diff);
              errs = errs + 1;
            end
          end
          diff = run_sum - 4096;
          if (diff < 0) diff = -diff;
          if (diff > S) begin
            $display("FAIL A row=%0d row-sum=%0d want 4096+-%0d", r, run_sum, S);
            errs = errs + 1;
          end
        end
        @(negedge clk); // idle gap: valid must fall
        if (probs_valid !== 1'b0) begin
          $display("FAIL A row=%0d valid stuck high", r);
          errs = errs + 1;
        end
      end
      $display("softmax pass A (non-causal) done errs=%0d", errs);

      // ---- Pass B: causal=1, prefix softmax + hard-zero tail ----
      rst_n = 0; #12; rst_n = 1; @(negedge clk); // row counter back to 0
      causal = 1;
      for (r = 0; r < nrows; r = r + 1) begin
        accept_row(r * S);
        if (probs_valid !== 1'b1) begin
          $display("FAIL B row=%0d valid=%b want 1", r, probs_valid);
          errs = errs + 1;
        end
        if (^probs_flat === 1'bx) begin
          $display("FAIL B row=%0d probs undriven (skeleton)", r);
          errs = errs + 1;
        end else begin
          run_sum = 0;
          for (j = 0; j < S; j = j + 1) begin
            got_lane = probs_flat[j*W +: W];
            want_lane = gcsr_mem[r * S + j];
            run_sum = run_sum + $signed(got_lane);
            // Masked tail must read EXACTLY zero (no tolerance).
            if (j > (r % S)) begin
              if (got_lane !== 16'h0000) begin
                $display("FAIL B row=%0d lane=%0d masked got=%h want=0000",
                         r, j, got_lane);
                errs = errs + 1;
              end
            end else begin
              diff = $signed(got_lane) - $signed(want_lane);
              if (diff < 0) diff = -diff;
              if (diff > TOL_LSB) begin
                $display("FAIL B row=%0d lane=%0d got=%h(%0d) want=%h(%0d) err=%0d",
                         r, j, got_lane, $signed(got_lane),
                         want_lane, $signed(want_lane), diff);
                errs = errs + 1;
              end
            end
          end
          diff = run_sum - 4096;
          if (diff < 0) diff = -diff;
          if (diff > S) begin
            $display("FAIL B row=%0d row-sum=%0d want 4096+-%0d", r, run_sum, S);
            errs = errs + 1;
          end
        end
        @(negedge clk);
        if (probs_valid !== 1'b0) begin
          $display("FAIL B row=%0d valid stuck high", r);
          errs = errs + 1;
        end
      end
      // Row 0 causal pin: [1.0, 0, ...] exactly on the unmasked lane.
      $display("softmax pass B (causal) done errs=%0d", errs);
    end else begin
      // ---- S=64 smoke: directed structural rows ----
      causal = 0;
      // uniform 0.25 -> each prob ~= 4096/64 = 64
      for (j = 0; j < S; j = j + 1) scores_flat[j*W +: W] = 16'h0400;
      @(negedge clk); scores_valid = 1;
      @(negedge clk); scores_valid = 0; #1;
      run_sum = 0;
      for (j = 0; j < S; j = j + 1) begin
        got_lane = probs_flat[j*W +: W];
        run_sum = run_sum + $signed(got_lane);
        diff = $signed(got_lane) - 64;
        if (diff < 0) diff = -diff;
        if (diff > TOL_LSB) begin
          $display("FAIL S64 uniform lane=%0d got=%0d want 64+-%0d",
                   j, $signed(got_lane), TOL_LSB);
          errs = errs + 1;
        end
      end
      diff = run_sum - 4096;
      if (diff < 0) diff = -diff;
      if (diff > S) begin
        $display("FAIL S64 uniform row-sum=%0d", run_sum);
        errs = errs + 1;
      end
      @(negedge clk);
      // causal row 0: lane0 = 1.0, rest exactly 0
      causal = 1;
      rst_n = 0; #12; rst_n = 1; @(negedge clk);
      for (j = 0; j < S; j = j + 1) scores_flat[j*W +: W] = 16'h7000; // +7 trap
      scores_flat[0 +: W] = 16'h0800; // lane0 = +0.5
      @(negedge clk); scores_valid = 1;
      @(negedge clk); scores_valid = 0; #1;
      if (probs_flat[0 +: W] !== 16'h1000) begin
        $display("FAIL S64 causal row0 lane0=%h want=1000", probs_flat[0 +: W]);
        errs = errs + 1;
      end
      for (j = 1; j < S; j = j + 1) begin
        if (probs_flat[j*W +: W] !== 16'h0000) begin
          $display("FAIL S64 causal row0 lane=%0d=%h want=0000", j,
                   probs_flat[j*W +: W]);
          errs = errs + 1;
        end
      end
      $display("softmax S64 smoke done errs=%0d", errs);
    end

    if (errs == 0) $display("SOFTMAX PASS (S=%0d, tol=%0d LSB)", S, TOL_LSB);
    else           $display("SOFTMAX FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
