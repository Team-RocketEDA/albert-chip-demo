// tb_loop_top_stitch — stitch bench for loop_mem_seq (Stage H) + mobilellm_top (Stage I).
//
// Contract: architecture/blocks/08-loop-mem-seq.md + 09-interface.md +
// top-level.md signal path + plans/full-model-stitch-plan.md Stages H/I.
// Frame order p0->ATTN->p1->RMS1->p2->SILU->p3->RMS2->LOOPBACK (locked);
// phases never overlap (tile_sel one-hot); almost_full -> FSM stall, never
// a weight fetch (theta_req==0 always, incl. stall + recal windows).
//
// Part A (loop, S=2/H=8 proxy): proves protocol with stubbed tiles —
//   layer_idx 0..29 exact, layer_done exactly at l==29, x_out == X_30 where
//   X(l+1) = X(l)+1 per byte (wrap), so X_30 = X_0+30 proves 30 iterations.
//   Traps: one-hot tile_sel every cycle; fifo_lane_en matches the 09 table;
//   white-box almost_full force -> layer_idx/tile_sel freeze, resume clean;
//   busy x_in_valid ignored; recal_trig mid-run changes nothing; determinism
//   (same frame twice -> identical x_out); theta_req==0 sampled every cycle.
// Part B (top, full S=64/H=576/V=32000): EMBED -> LOOP30 -> HEAD end to end.
//   64 ids (baked tv ids cycled) -> X0 sample (hierarchical) -> X_30 check
//   -> last-row subset-logit oracle (wlm_subset16.hex) + argmax -> pred_out
//   + done exactly once.
// x_out_valid protocol: single-cycle strobe per frame; x_out holds X_30
// after (until next frame). Single frame per reset (DONE sticky, like seq).
//
// Run from the repo root (all $readmemh paths repo-root-relative):
//   iverilog -g2012 -o /tmp/tb_loop_top src/components/*.v \
//     src/tb/loop_top_stitch/tb_loop_top_stitch.v && vvp /tmp/tb_loop_top
`timescale 1ns / 1ps
module tb_loop_top_stitch;
  reg clk = 0;
  always #5 clk = ~clk;

  integer tot_errs = 0;

  // ================= Part A: loop protocol proxy (S=2,H=8) =================
  localparam AS = 2, AH = 8, AN = AS * AH;

  reg rstA_n = 0;
  reg [AN*8-1:0] a_x_in = 0;
  reg a_x_valid = 0;
  wire a_x_ready;
  wire [AN*8-1:0] a_x_out;
  wire a_x_out_valid;
  wire [4:0] a_layer;
  wire a_done;
  wire [3:0] a_tilesel;
  wire [5:0] a_ilp, a_olp;
  wire a_theta_req;
  reg a_recal = 0;

  loop_mem_seq #(.S(AS), .H(AH)) dut_loop (
    .clk(clk), .rst_n(rstA_n),
    .x_in(a_x_in), .x_in_valid(a_x_valid), .tag_in(4'b0),
    .x_in_ready(a_x_ready),
    .x_out(a_x_out), .x_out_valid(a_x_out_valid),
    .layer_idx(a_layer), .layer_done(a_done),
    .tile_sel(a_tilesel),
    .fifo_lane_en_ilp(a_ilp), .fifo_lane_en_olp(a_olp),
    .theta_req(a_theta_req), .theta_ack(1'b0),
    .sw_result_in(18432'b0), .recal_trig(a_recal)
  );

  reg [7:0] a_in [0:AN-1];
  reg [7:0] a_prev_out [0:AN-1];
  integer i, cyc;

  task a_reset;
    begin
      rstA_n = 0; a_x_valid = 0; a_recal = 0;
      repeat (4) @(posedge clk); #1;
      rstA_n = 1;
      repeat (2) @(posedge clk); #1;
    end
  endtask

  task a_load_frame;
    begin
      a_x_in = 0;
      for (i = 0; i < AN; i = i + 1)
        a_x_in[i*8 +: 8] = a_in[i];
      if (a_x_ready !== 1'b1) begin
        $display("FAIL A: x_in_ready=%b before frame, want 1", a_x_ready);
        tot_errs = tot_errs + 1;
      end
      @(negedge clk);
      a_x_valid = 1'b1;
      @(posedge clk); #1;
      a_x_valid = 1'b0;
    end
  endtask

  // Per-cycle invariant monitor state.
  reg a_run_mon = 0;
  integer a_valid_pulses = 0;
  reg a_valid_d = 0;
  integer a_layers_seen [0:29];
  integer a_last_layer = -1;
  integer a_phase_hist [0:3];
  integer a_stall_checks = 0;

  task a_mon_reset;
    integer q;
    begin
      a_run_mon = 1;
      a_valid_pulses = 0; a_valid_d = 0;
      a_last_layer = -1; a_stall_checks = 0;
      for (q = 0; q < 30; q = q + 1) a_layers_seen[q] = 0;
      for (q = 0; q < 4; q = q + 1) a_phase_hist[q] = 0;
    end
  endtask

  // Invariant sampler: call once per cycle while a run is live.
  task a_mon_sample;
    begin
      if (a_run_mon) begin
        // No X on protocol nets (skeleton floats -> caught here).
        if (^a_tilesel === 1'bx) begin
          $display("FAIL A: tile_sel=X (skeleton?)");
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end else if ((a_tilesel != 4'b0001) && (a_tilesel != 4'b0010) &&
                     (a_tilesel != 4'b0100) && (a_tilesel != 4'b1000)) begin
          $display("FAIL A: tile_sel=%b not one-hot (phase overlap?)", a_tilesel);
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end
        if (^a_layer === 1'bx || ^a_done === 1'bx) begin
          $display("FAIL A: layer_idx/done X");
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end
        if (a_layer > 5'd29) begin
          $display("FAIL A: layer_idx=%0d > 29", a_layer);
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end
        // 09-interface lane table vs observed phase.
        case (a_tilesel)
          4'b0001: if (a_ilp !== 6'b000011 || a_olp !== 6'b011111) begin
            $display("FAIL A: p0 lanes ilp=%b olp=%b", a_ilp, a_olp);
            tot_errs = tot_errs + 1; a_run_mon = 0;
          end
          4'b0010: if (a_ilp !== 6'b000011 || a_olp !== 6'b000111) begin
            $display("FAIL A: p1 lanes ilp=%b olp=%b", a_ilp, a_olp);
            tot_errs = tot_errs + 1; a_run_mon = 0;
          end
          4'b0100: if (a_ilp !== 6'b000011 || a_olp !== 6'b111111) begin
            $display("FAIL A: p2 lanes ilp=%b olp=%b", a_ilp, a_olp);
            tot_errs = tot_errs + 1; a_run_mon = 0;
          end
          4'b1000: if (a_ilp !== 6'b111111 || a_olp !== 6'b000011) begin
            $display("FAIL A: p3 lanes ilp=%b olp=%b", a_ilp, a_olp);
            tot_errs = tot_errs + 1; a_run_mon = 0;
          end
        endcase
        // Phase histogram + layer coverage.
        case (a_tilesel)
          4'b0001: a_phase_hist[0] = a_phase_hist[0] + 1;
          4'b0010: a_phase_hist[1] = a_phase_hist[1] + 1;
          4'b0100: a_phase_hist[2] = a_phase_hist[2] + 1;
          4'b1000: a_phase_hist[3] = a_phase_hist[3] + 1;
        endcase
        if (a_layer != a_last_layer) begin
          if (a_last_layer !== -1 && a_layer !== a_last_layer + 1) begin
            $display("FAIL A: layer jump %0d -> %0d", a_last_layer, a_layer);
            tot_errs = tot_errs + 1; a_run_mon = 0;
          end
          a_last_layer = a_layer;
          a_layers_seen[a_layer] = 1;
        end
        // Never a weight fetch, even mid-run.
        if (a_theta_req !== 1'b0) begin
          $display("FAIL A: theta_req=%b (weight fetch!)", a_theta_req);
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end
        // x_out_valid exactly-once counting.
        if (a_x_out_valid === 1'b1 && a_valid_d === 1'b0)
          a_valid_pulses = a_valid_pulses + 1;
        else if (a_x_out_valid !== 1'b0 && a_x_out_valid !== 1'b1) begin
          $display("FAIL A: x_out_valid=X");
          tot_errs = tot_errs + 1; a_run_mon = 0;
        end
        a_valid_d = a_x_out_valid;
      end
    end
  endtask

  task a_wait_done(input integer tlim, input integer want_done);
    begin
      cyc = 0;
      while (cyc < tlim && a_done !== want_done) begin
        @(posedge clk); #1;
        a_mon_sample();
        cyc = cyc + 1;
      end
      if (a_done !== want_done) begin
        $display("FAIL A: layer_done=%b after %0d cyc, want %b", a_done, cyc, want_done);
        tot_errs = tot_errs + 1;
      end
    end
  endtask

  task a_check_x30;
    integer errs, k;
    reg [7:0] got;
    begin
      errs = 0;
      for (k = 0; k < AN; k = k + 1) begin
        got = a_x_out[k*8 +: 8];
        if (^got === 1'bx) begin
          if (errs < 4) $display("FAIL A: x_out byte%0d X (skeleton?)", k);
          errs = errs + 1;
        end else if (got !== ((a_in[k] + 30) & 8'hff)) begin
          if (errs < 8)
            $display("FAIL A: x_out[%0d]=%02h want %02h (X0+30)", k, got, ((a_in[k]+30)&8'hff));
          errs = errs + 1;
        end
      end
      if (errs == 0) $display("phaseA X_30 = X_0+30 byte-exact PASS");
      tot_errs = tot_errs + errs;
    end
  endtask

  task a_check_coverage;
    integer q, errs;
    begin
      errs = 0;
      for (q = 0; q < 30; q = q + 1)
        if (!a_layers_seen[q]) begin
          $display("FAIL A: layer %0d never observed", q);
          errs = errs + 1;
        end
      for (q = 0; q < 4; q = q + 1)
        if (a_phase_hist[q] == 0) begin
          $display("FAIL A: phase %0d never observed", q);
          errs = errs + 1;
        end
      if (errs == 0)
        $display("phaseA layers 0..29 + phases p0..p3 all observed PASS");
      tot_errs = tot_errs + errs;
      if (a_valid_pulses !== 1) begin
        $display("FAIL A: x_out_valid pulses=%0d want 1", a_valid_pulses);
        tot_errs = tot_errs + 1;
      end else begin
        $display("phaseA x_out_valid exactly-once PASS");
      end
      // x_out must hold X_30 after the pulse (sampled late).
      repeat (10) @(posedge clk); #1;
      a_check_x30();
    end
  endtask

  // ================= Part B: full top (S=64/H=576) =================
  localparam BS = 64, BH = 576, BN = BS * BH;

  reg rstB_n = 0;
  reg [BS*16-1:0] b_ids = 0;
  reg b_ids_valid = 0;
  wire [14:0] b_pred;
  wire b_done;

  mobilellm_top #(.S(BS), .H(BH), .V(32000)) dut_top (
    .clk(clk), .rst_n(rstB_n), .start(1'b0),
    .ids_in(b_ids), .ids_valid(b_ids_valid),
    .pred_out(b_pred), .done(b_done)
  );

  reg [15:0] b_idseq [0:7];
  reg [7:0] b_wmem [0:16*BH-1];
  reg [7:0] b_lastrow [0:BH-1];
  integer b_cyc, b_pulses, b_exp, bb, kk;
  reg signed [63:0] b_acc;
  reg [31:0] b_logits [0:15];
  reg [7:0] b_xb;

  task b_push_ids;
    integer r;
    begin
      for (r = 0; r < BS; r = r + 1) begin
        b_ids = 0;
        b_ids[15:0] = b_idseq[r % 8];
        cyc = 0;
        while (dut_top.u_embed.ids_ready !== 1'b1 && cyc < 10000) begin
          @(posedge clk); #1;
          cyc = cyc + 1;
        end
        if (dut_top.u_embed.ids_ready !== 1'b1) begin
          $display("FAIL B: ids_ready never came (row %0d)", r);
          tot_errs = tot_errs + 1;
        end
        @(negedge clk);
        b_ids_valid = 1'b1;
        @(posedge clk); #1;
        b_ids_valid = 1'b0;
      end
      $display("phaseB pushed 64 ids PASS");
    end
  endtask

  initial begin
    // ---------------- Part A ----------------
    for (i = 0; i < AN; i = i + 1) a_in[i] = (i * 7 + 3) & 8'hff;

    // A1: basic protocol run.
    a_reset();
    a_mon_reset();
    a_load_frame();
    a_wait_done(20000, 1);
    // Settle: DONE strobe + x_out hold land after layer_done.
    repeat (5) begin @(posedge clk); #1; a_mon_sample(); end
    a_run_mon = 0;
    a_check_coverage();
    for (i = 0; i < AN; i = i + 1) a_prev_out[i] = a_x_out[i*8 +: 8];

    // A2: almost_full -> FSM stall (white-box force on OLP lane 0).
    a_reset();
    a_mon_reset();
    a_load_frame();
    // Run to layer 3, then force the lane full and prove the freeze.
    cyc = 0;
    while (cyc < 20000 && a_layer < 3) begin
      @(posedge clk); #1; a_mon_sample(); cyc = cyc + 1;
    end
    if (a_layer < 3) begin
      $display("FAIL A2: never reached layer 3");
      tot_errs = tot_errs + 1;
    end else begin
      force dut_loop.olp_full[0] = 1'b1;
      repeat (2) @(posedge clk); #1;
      begin
        integer fr_layer; reg [3:0] fr_sel;
        fr_layer = a_layer; fr_sel = a_tilesel;
        repeat (20) @(posedge clk); #1;
        a_mon_sample();
        if (a_layer !== fr_layer || a_tilesel !== fr_sel) begin
          $display("FAIL A2: no stall under almost_full (layer %0d->%0d sel %b->%b)",
                   fr_layer, a_layer, fr_sel, a_tilesel);
          tot_errs = tot_errs + 1;
        end else begin
          $display("phaseA2 almost_full -> FSM stall (freeze 20cyc) PASS");
        end
        if (a_theta_req !== 1'b0) begin
          $display("FAIL A2: theta_req during stall");
          tot_errs = tot_errs + 1;
        end
      end
      release dut_loop.olp_full[0];
    end
    a_wait_done(20000, 1);
    repeat (5) begin @(posedge clk); #1; a_mon_sample(); end
    a_run_mon = 0;
    if (a_valid_pulses !== 1) begin
      $display("FAIL A2: valid pulses=%0d after stall-resume", a_valid_pulses);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseA2 stall-resume completes exactly-once PASS");
    end
    a_check_x30();

    // A3: busy x_in_valid ignored + recal mid-run.
    a_reset();
    a_mon_reset();
    a_load_frame();
    cyc = 0;
    while (cyc < 20000 && a_layer < 5) begin
      @(posedge clk); #1; a_mon_sample(); cyc = cyc + 1;
    end
    if (a_x_ready !== 1'b0) begin
      $display("FAIL A3: x_in_ready=%b mid-run, want 0", a_x_ready);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseA3 backpressure (ready low mid-run) PASS");
    end
    // Push a decoy frame mid-run: must be ignored.
    a_x_in = {AN*8{1'b1}};
    @(negedge clk); a_x_valid = 1'b1;
    @(posedge clk); #1; a_x_valid = 1'b0;
    // Recal pulse mid-run: protocol must not glitch.
    @(negedge clk); a_recal = 1'b1;
    @(posedge clk); #1; a_recal = 1'b0;
    a_wait_done(20000, 1);
    repeat (5) begin @(posedge clk); #1; a_mon_sample(); end
    a_run_mon = 0;
    a_check_x30();
    $display("phaseA3 busy-ignore + recal-no-glitch PASS (x30 exact above)");

    // A4: determinism — same frame twice, identical x_out.
    a_reset();
    a_mon_reset();
    a_load_frame();
    a_wait_done(20000, 1);
    repeat (5) begin @(posedge clk); #1; a_mon_sample(); end
    a_run_mon = 0;
    begin
      integer derrs, k;
      derrs = 0;
      for (k = 0; k < AN; k = k + 1)
        if (a_x_out[k*8 +: 8] !== a_prev_out[k]) begin
          if (derrs < 4)
            $display("FAIL A4: byte%0d %02h vs first-run %02h",
                     k, a_x_out[k*8 +: 8], a_prev_out[k]);
          derrs = derrs + 1;
        end
      if (derrs == 0) $display("phaseA4 determinism (rerun identical) PASS");
      tot_errs = tot_errs + derrs;
    end

    // ---------------- Part B ----------------
    $readmemh("weights/bake/tv_embed_ids.hex", b_idseq);
    $readmemh("src/tb/lm_head_stitch/wlm_subset16.hex", b_wmem);
    rstB_n = 0; b_ids_valid = 0;
    repeat (4) @(posedge clk); #1;
    rstB_n = 1;
    repeat (2) @(posedge clk); #1;
    b_push_ids();
    // Wait for embed frame.
    b_cyc = 0;
    while (b_cyc < 300000 && dut_top.u_embed.x0_valid !== 1'b1) begin
      @(posedge clk); #1;
      b_cyc = b_cyc + 1;
      if (^dut_top.u_embed.x0_valid === 1'bx && b_cyc > 100) begin
        $display("FAIL B: x0_valid=X");
        tot_errs = tot_errs + 1;
        b_cyc = 300000;
      end
    end
    if (dut_top.u_embed.x0_valid !== 1'b1) begin
      $display("FAIL B: x0_valid never came");
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseB X0 valid after %0d cyc PASS", b_cyc);
    end
    // Wait for the 30x loop.
    b_cyc = 0;
    while (b_cyc < 100000 && dut_top.u_loop.layer_done !== 1'b1) begin
      @(posedge clk); #1;
      b_cyc = b_cyc + 1;
    end
    if (dut_top.u_loop.layer_done !== 1'b1) begin
      $display("FAIL B: loop layer_done never came");
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseB LOOP30 done after %0d cyc PASS", b_cyc);
    end
    // Settle: x_out_valid strobe + X_30 hold land after layer_done.
    repeat (5) @(posedge clk); #1;
    // X_30 = X_0 + 30 per byte (loopback integrity at full dims).
    begin
      integer xerrs;
      reg [BN*8-1:0] x0f, x3f;
      xerrs = 0;
      x0f = dut_top.u_embed.x0_out;
      x3f = dut_top.u_loop.x_out;
      for (bb = 0; bb < BN; bb = bb + 1) begin
        b_xb = x0f[bb*8 +: 8];
        if (x3f[bb*8 +: 8] !== ((b_xb + 30) & 8'hff)) begin
          if (xerrs < 8)
            $display("FAIL B: X30 byte%0d=%02h want X0+30=%02h", bb,
                     x3f[bb*8 +: 8], ((b_xb + 30) & 8'hff));
          xerrs = xerrs + 1;
        end
      end
      if (xerrs == 0) $display("phaseB X_30 = X_0+30 full-frame PASS");
      tot_errs = tot_errs + xerrs;
      // Last-token slice -> subset-logit oracle -> argmax.
      for (kk = 0; kk < BH; kk = kk + 1)
        b_lastrow[kk] = x3f[((BS-1)*BH+kk)*8 +: 8];
      for (kk = 0; kk < 16; kk = kk + 1) begin
        b_acc = 0;
        for (bb = 0; bb < BH; bb = bb + 1)
          b_acc = b_acc + $signed(b_lastrow[bb]) * $signed(b_wmem[kk*BH+bb]);
        b_logits[kk] = b_acc[31:0];
      end
      b_exp = 0;
      for (kk = 1; kk < 16; kk = kk + 1)
        if ($signed(b_logits[kk]) > $signed(b_logits[b_exp])) b_exp = kk;
      $display("phaseB oracle argmax pred=%0d logit=%h", b_exp, b_logits[b_exp]);
    end
    // Head done exactly once + pred match.
    b_cyc = 0; b_pulses = 0;
    begin
      reg b_d;
      b_d = 0;
      while (b_cyc < 2000 && b_pulses == 0) begin
        @(posedge clk); #1;
        b_cyc = b_cyc + 1;
        if (b_done === 1'b1 && b_d === 1'b0) b_pulses = b_pulses + 1;
        b_d = b_done;
      end
      repeat (20) @(posedge clk); #1;
      if (b_done === 1'b1) b_pulses = b_pulses + 1;
    end
    if (b_pulses !== 1) begin
      $display("FAIL B: head done pulses=%0d want 1", b_pulses);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseB head done exactly-once PASS");
    end
    if (^b_pred === 1'bx) begin
      $display("FAIL B: pred_out=X");
      tot_errs = tot_errs + 1;
    end else if (b_pred !== b_exp) begin
      $display("FAIL B: pred=%0d want=%0d", b_pred, b_exp);
      tot_errs = tot_errs + 1;
    end else begin
      $display("phaseB pred=%0d matches oracle PASS", b_pred);
    end

    if (tot_errs == 0)
      $display("LOOP_TOP_STITCH PASS (loop protocol + top ids->pred)");
    else
      $display("LOOP_TOP_STITCH FAIL (%0d errs)", tot_errs);
    $finish;
  end
endmodule
