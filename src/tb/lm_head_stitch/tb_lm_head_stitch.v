// tb_lm_head_stitch — stitch bench for lm_head (last-token -> pred id).
//
// Oracle: baked checkpoint bytes weights/bake/tv_lmhead_act.hex (576 s8)
// + tv_lmhead_golden.hex (16 s32 exact dots vs embed-copy rows 0..15,
// seed 0xB0C8). W image is the baked embed copy: DUT loads the first 16
// rows via src/tb/lm_head_stitch/wlm_subset16.hex (head of embed_full ==
// embed_proxy64 head). Full 32k vocab is the Verilator stretch, NOT iverilog.
//
// Contract: architecture/blocks/07-lm-head.md Stage G. Slice X_29 last row
// (parent pre-slices; tb drives x_last_in directly) -> LAST_BUF latch ->
// dots over the 16-row subset -> inferred argmax compare loop -> pred_out
// + single-cycle done. Traps: done pulses exactly once per x_valid;
// subset golden only (no scoreboard/label FIFO on chip).
//
// RED-capable: on the skeleton pred_out floats (X) and done never pulses
// (seq_fsm layer_done needs frame/tile IRQs) -> FAIL (timeout/X), not an
// elab error. Hierarchical logit check is guarded so RED still elaborates.
// Run from repo root:
//   RED (skeleton, expect FAIL):
//     iverilog -g2012 -o /tmp/tb_lm_head_red src/components/*.v \
//       src/tb/lm_head_stitch/tb_lm_head_stitch.v && vvp /tmp/tb_lm_head_red
//   GREEN (wired DUT, expect PASS):
//     iverilog -g2012 -DSTITCH_LOGITS -o /tmp/tb_lm_head \
//       src/components/*.v src/tb/lm_head_stitch/tb_lm_head_stitch.v \
//       && vvp /tmp/tb_lm_head
`timescale 1ns / 1ps
module tb_lm_head_stitch;
  localparam H = 576;
  localparam VSUB = 16;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [H*8-1:0] x_last_in = 0;
  reg             x_valid = 0;
  wire [14:0]     pred_out;
  wire            done;

  lm_head #(.H(H), .V(32000)) dut (
    .clk(clk), .rst_n(rst_n),
    .x_last_in(x_last_in), .x_valid(x_valid),
    .pred_out(pred_out), .done(done)
  );

  reg [7:0]  act [0:H-1];
  reg [31:0] golden [0:VSUB-1];
  integer i, errs, tot_errs;
  integer exp_pred;

  task pack_act;
    begin
      x_last_in = 0;
      for (i = 0; i < H; i = i + 1)
        x_last_in[i*8 +: 8] = act[i];
    end
  endtask

  task pulse_valid;
    begin
      @(negedge clk);
      x_valid = 1'b1;
      @(posedge clk); #1;
      x_valid = 1'b0;
    end
  endtask

  // Wait for done==1, count asserted cycles over the window; expect exactly 1.
  task wait_done_once(output integer pulses);
    integer cyc;
    begin
      pulses = 0;
      cyc = 0;
      // First rising edge (timeout 200 cycles: 16-row compute + margin).
      while (cyc < 200) begin
        @(posedge clk); #1;
        cyc = cyc + 1;
        if (done === 1'b1) begin
          pulses = pulses + 1;
          cyc = 200; // break to trailing check below (counts the 1)
        end else if (done !== 1'b0) begin
          $display("FAIL: done=X/Z while waiting (skeleton?)");
          tot_errs = tot_errs + 1;
          cyc = 200;
        end
      end
      // Trailing: done must deassert next cycle (single-cycle pulse) and
      // stay low for 10 more cycles (exactly-once trap).
      repeat (10) begin
        @(posedge clk); #1;
        if (done === 1'b1) pulses = pulses + 1;
        else if (done !== 1'b0) begin
          $display("FAIL: done=X/Z after pulse");
          tot_errs = tot_errs + 1;
        end
      end
    end
  endtask

  initial begin
    $readmemh("weights/bake/tv_lmhead_act.hex", act);
    $readmemh("weights/bake/tv_lmhead_golden.hex", golden);
    tot_errs = 0;

    // Independent argmax oracle (first-max wins on ties).
    exp_pred = 0;
    for (i = 1; i < VSUB; i = i + 1)
      if ($signed(golden[i]) > $signed(golden[exp_pred]))
        exp_pred = i;
    $display("golden argmax: pred=%0d logit=%h", exp_pred, golden[exp_pred]);

    @(posedge clk); #1;
    rst_n = 1;
    repeat (2) @(posedge clk); #1;
    if (done !== 1'b0) begin
      $display("FAIL: done=%b after reset, want 0", done);
      tot_errs = tot_errs + 1;
    end

    // ---- Phase A: baked vector -> subset logits bit-exact + argmax ----
    pack_act();
    pulse_valid();
    begin
      integer pulses;
      wait_done_once(pulses);
      if (pulses !== 1) begin
        $display("FAIL phaseA: done pulses=%0d want=1 (timeout/skeleton?)", pulses);
        tot_errs = tot_errs + 1;
      end
    end
`ifdef STITCH_LOGITS
    begin
      integer k, lerrs;
      lerrs = 0;
      for (k = 0; k < VSUB; k = k + 1) begin
        if (dut.logits[k] !== golden[k]) begin
          if (lerrs < 8)
            $display("FAIL phaseA logit%0d got=%h want=%h", k, dut.logits[k], golden[k]);
          lerrs = lerrs + 1;
        end
      end
      $display("phaseA logits bit-exact done lerrs=%0d", lerrs);
      tot_errs = tot_errs + lerrs;
    end
`endif
    if (^pred_out === 1'bx) begin
      $display("FAIL phaseA: pred_out=X (skeleton?)");
      tot_errs = tot_errs + 1;
    end else if (pred_out !== exp_pred) begin
      $display("FAIL phaseA: pred=%0d want=%0d", pred_out, exp_pred);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseA baked pred=%0d PASS", pred_out);
    end
    // pred must hold while idle (no x_valid).
    repeat (5) @(posedge clk); #1;
    if (pred_out !== exp_pred) begin
      $display("FAIL phaseA hold: pred=%0d want=%0d", pred_out, exp_pred);
      tot_errs = tot_errs + 1;
    end
    if (done !== 1'b0) begin
      $display("FAIL phaseA idle: done=%b want 0", done);
      tot_errs = tot_errs + 1;
    end

    // ---- Phase B: all-zero vector -> all-zero logits, pred 0 ----
    for (i = 0; i < H; i = i + 1) act[i] = 8'h00;
    pack_act();
    pulse_valid();
    begin
      integer pulses;
      wait_done_once(pulses);
      if (pulses !== 1) begin
        $display("FAIL phaseB: done pulses=%0d want=1", pulses);
        tot_errs = tot_errs + 1;
      end
    end
`ifdef STITCH_LOGITS
    begin
      integer k, lerrs;
      lerrs = 0;
      for (k = 0; k < VSUB; k = k + 1) begin
        if (dut.logits[k] !== 32'h00000000) begin
          if (lerrs < 8)
            $display("FAIL phaseB logit%0d got=%h want=00000000", k, dut.logits[k]);
          lerrs = lerrs + 1;
        end
      end
      $display("phaseB zero logits done lerrs=%0d", lerrs);
      tot_errs = tot_errs + lerrs;
    end
`endif
    if (^pred_out === 1'bx) begin
      $display("FAIL phaseB: pred_out=X");
      tot_errs = tot_errs + 1;
    end else if (pred_out !== 0) begin
      $display("FAIL phaseB: pred=%0d want=0 (tie -> first)", pred_out);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseB zero pred=0 PASS");
    end

    // ---- Phase C: back-to-back baked vector (retrigger, exactly-once) ----
    $readmemh("weights/bake/tv_lmhead_act.hex", act);
    pack_act();
    pulse_valid();
    begin
      integer pulses;
      wait_done_once(pulses);
      if (pulses !== 1) begin
        $display("FAIL phaseC: done pulses=%0d want=1", pulses);
        tot_errs = tot_errs + 1;
      end
    end
    if (^pred_out === 1'bx) begin
      $display("FAIL phaseC: pred_out=X");
      tot_errs = tot_errs + 1;
    end else if (pred_out !== exp_pred) begin
      $display("FAIL phaseC: pred=%0d want=%0d", pred_out, exp_pred);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseC retrigger pred=%0d PASS", pred_out);
    end

    if (tot_errs == 0)
      $display("LM_HEAD_STITCH PASS (baked 16-row golden + zero + retrigger)");
    else
      $display("LM_HEAD_STITCH FAIL (%0d errs)", tot_errs);
    $finish;
  end
endmodule
