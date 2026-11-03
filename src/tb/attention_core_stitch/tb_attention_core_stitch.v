// tb_attention_core_stitch — self-checking stitch test for attention_core.
// Contract: architecture/blocks/03-attention-core.md item 4 + GQA/causal/KV-cache.
// Oracle: golden_a/b/c.hex from src/tb/attention_core_stitch/gen_golden.py
// (pure-stdlib python over baked tv_q/k/v/o_act.hex + rope_cos/sin.hex).
// RED-capable: on the skeleton y_out/y_valid/qkv_ready float (X) -> FAIL.
// Frames (S=4): A full (s_cfg=4); B partial (s_cfg=3, row3 must read 0);
// C full with V row3 swapped (rows 0..2 must be bit-identical to A:
// causal invariance; row0 == V row0 proves row_q reset after partial B).
// Y compare vs float golden with TOL (softmax_d fixed-point budget) plus
// EXACT checks that need no oracle. Run from repo root:
//   iverilog -o /tmp/tb_attn_stitch src/components/attention_core.v \
//     src/components/sram_1r1w.v src/components/mac_array.v \
//     src/components/softmax_d.v src/components/div_unit.v \
//     src/components/exp_lut.v src/components/fifo_sync.v \
//     src/tb/attention_core_stitch/tb_attention_core_stitch.v \
//     && vvp /tmp/tb_attn_stitch
`timescale 1ns / 1ps
module tb_attention_core_stitch;
  localparam S = 4;
  localparam H = 576;
  localparam KV = 192;
  // TOL=6: analytic bound 3 (softmax A-quant <=2 folded through |V|<=128
  // plus requant round <=1); measured worst diff is 1 LSB over all 6912
  // bytes of frames A/B/C, so 6 keeps 6x measured / 2x analytic margin.
  localparam TOL = 6;
  localparam QW = S*H*8;
  localparam KW = S*KV*8;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg [QW-1:0] q_in = 0;
  reg [KW-1:0] k_in = 0;
  reg [KW-1:0] v_in = 0;
  reg qkv_valid = 0;
  reg [6:0] s_cfg = 0;
  wire qkv_ready;
  wire [QW-1:0] y_out;
  wire y_valid;

  attention_core #(.S(S)) dut (
    .clk(clk), .rst_n(rst_n),
    .q_in(q_in), .k_in(k_in), .v_in(v_in),
    .qkv_valid(qkv_valid), .s_cfg(s_cfg),
    .qkv_ready(qkv_ready), .y_out(y_out), .y_valid(y_valid)
  );

  reg [7:0] qa [0:575];
  reg [7:0] ka [0:575];
  reg [7:0] va [0:575];
  reg [7:0] oa [0:575];
  reg [7:0] ga [0:S*H-1];
  reg [7:0] gb [0:S*H-1];
  reg [7:0] gc [0:S*H-1];
  reg [7:0] gotA [0:S*H-1];
  reg [7:0] gotB [0:S*H-1];
  reg [7:0] gotC [0:S*H-1];

  integer i, j, errs, diff, cyc;
  integer nA, nB, nC;

  task pack_q;
    integer r, c;
    begin
      for (r = 0; r < S; r = r + 1)
        for (c = 0; c < H; c = c + 1) begin
          if (r == 0) q_in[(r*H+c)*8 +: 8] = qa[c];
          else if (r == 1) q_in[(r*H+c)*8 +: 8] = ka[c];
          else if (r == 2) q_in[(r*H+c)*8 +: 8] = va[c];
          else q_in[(r*H+c)*8 +: 8] = oa[c];
        end
    end
  endtask

  task pack_k;
    integer r, c;
    begin
      for (r = 0; r < S; r = r + 1)
        for (c = 0; c < KV; c = c + 1) begin
          if (r == 0) k_in[(r*KV+c)*8 +: 8] = ka[c];
          else if (r == 1) k_in[(r*KV+c)*8 +: 8] = ka[192+c];
          else if (r == 2) k_in[(r*KV+c)*8 +: 8] = ka[384+c];
          else k_in[(r*KV+c)*8 +: 8] = va[c];
        end
    end
  endtask

  // sel 0: V rows = v_act thirds + k_act low third (frames A/B).
  // sel 1: V row3 = o_act low third (frame C causal probe).
  task pack_v(input integer sel);
    integer r, c;
    begin
      for (r = 0; r < S; r = r + 1)
        for (c = 0; c < KV; c = c + 1) begin
          if (r == 0) v_in[(r*KV+c)*8 +: 8] = va[c];
          else if (r == 1) v_in[(r*KV+c)*8 +: 8] = va[192+c];
          else if (r == 2) v_in[(r*KV+c)*8 +: 8] = va[384+c];
          else if (sel == 0) v_in[(r*KV+c)*8 +: 8] = ka[c];
          else v_in[(r*KV+c)*8 +: 8] = oa[c];
        end
    end
  endtask

  // Send one frame and capture Y into got<tag>. drv=0/1/2 -> gotA/B/C.
  task send_frame(input integer vsel, input [6:0] cfg, input integer drv);
    integer r, c, done;
    begin
      pack_q; pack_k; pack_v(vsel);
      s_cfg = cfg;
      @(negedge clk);
      if (qkv_ready !== 1'b1) begin
        $display("FAIL frame cfg=%0d: qkv_ready=%b want 1", cfg, qkv_ready);
        errs = errs + 1;
      end
      qkv_valid = 1;
      @(negedge clk);
      qkv_valid = 0;
      // busy: ready must fall
      repeat (10) @(negedge clk);
      if (qkv_ready !== 1'b0) begin
        $display("FAIL frame cfg=%0d: qkv_ready=%b during busy want 0", cfg, qkv_ready);
        errs = errs + 1;
      end
      done = 0; cyc = 0;
      while (done == 0) begin
        @(negedge clk);
        cyc = cyc + 1;
        if (y_valid === 1'b1) done = 1;
        if (cyc > 100000) begin
          $display("FAIL frame cfg=%0d: y_valid timeout", cfg);
          errs = errs + 1;
          done = 2;
        end
      end
      if (done == 1) begin
        for (r = 0; r < S; r = r + 1)
          for (c = 0; c < H; c = c + 1) begin
            if (drv == 0) gotA[r*H+c] = y_out[(r*H+c)*8 +: 8];
            else if (drv == 1) gotB[r*H+c] = y_out[(r*H+c)*8 +: 8];
            else gotC[r*H+c] = y_out[(r*H+c)*8 +: 8];
          end
      end
      // inputs held whole frame; release now
      @(negedge clk);
    end
  endtask

  // Compare captured frame vs golden bytes with TOL; rows [r0,r1).
  task cmp_gold(input integer drv, input integer r0, input integer r1,
                input integer which);
    integer r, c, g, v;
    begin
      for (r = r0; r < r1; r = r + 1)
        for (c = 0; c < H; c = c + 1) begin
          if (drv == 0) v = $signed(gotA[r*H+c]);
          else if (drv == 1) v = $signed(gotB[r*H+c]);
          else v = $signed(gotC[r*H+c]);
          if (which == 0) g = $signed(ga[r*H+c]);
          else if (which == 1) g = $signed(gb[r*H+c]);
          else g = $signed(gc[r*H+c]);
          diff = v - g;
          if (diff < 0) diff = -diff;
          if (diff > TOL) begin
            if (errs < 10)
              $display("FAIL gold drv=%0d row=%0d col=%0d got=%0d want=%0d",
                       drv, r, c, v, g);
            errs = errs + 1;
          end
        end
    end
  endtask

  initial begin
    errs = 0; nA = 0; nB = 0; nC = 0;
    $readmemh("weights/bake/tv_q_act.hex", qa);
    $readmemh("weights/bake/tv_k_act.hex", ka);
    $readmemh("weights/bake/tv_v_act.hex", va);
    $readmemh("weights/bake/tv_o_act.hex", oa);
    $readmemh("src/tb/attention_core_stitch/golden_a.hex", ga);
    $readmemh("src/tb/attention_core_stitch/golden_b.hex", gb);
    $readmemh("src/tb/attention_core_stitch/golden_c.hex", gc);

    #12;
    if (y_valid !== 1'b0) begin
      $display("FAIL reset: y_valid=%b want 0", y_valid);
      errs = errs + 1;
    end
    if (^qkv_ready === 1'bx) begin
      $display("FAIL reset: qkv_ready undriven (skeleton)");
      errs = errs + 1;
    end
    rst_n = 1;
    @(negedge clk);

    // Frame A: full frame, golden compare + exact row0 (A[0]=[1,0..] so Y=V).
    send_frame(0, 4, 0);
    cmp_gold(0, 0, S, 0);
    for (i = 0; i < H; i = i + 1) begin
      j = va[((i/64)/3)*64+(i%64)]; // GQA fan-out: Y head h reads V head h/3
      if (gotA[i] !== j[7:0]) begin
        if (nA < 5)
          $display("FAIL A row0 exact col=%0d got=%h want=%h", i, gotA[i], j[7:0]);
        nA = nA + 1;
      end
    end
    if (nA != 0) begin
      $display("FAIL A row0 exact: %0d mismatches", nA);
      errs = errs + nA;
    end
    if (^y_out === 1'bx) begin
      $display("FAIL A: y_out undriven (skeleton)");
      errs = errs + 1;
    end

    // Frame B: partial s_cfg=3; rows 0..2 golden, row3 exactly zero.
    send_frame(0, 3, 1);
    cmp_gold(1, 0, 3, 1);
    for (i = 0; i < H; i = i + 1)
      if (gotB[3*H+i] !== 8'h00) nB = nB + 1;
    if (nB != 0) begin
      $display("FAIL B row3 zero: %0d nonzero bytes", nB);
      errs = errs + 1;
    end

    // Frame C: V row3 swapped; rows 0..2 bit-identical to A (causal mask);
    // row0 == V row0 exact (row_q reset after partial B, the known trap).
    send_frame(1, 4, 2);
    cmp_gold(2, 0, S, 2);
    for (i = 0; i < 3*H; i = i + 1)
      if (gotC[i] !== gotA[i]) nC = nC + 1;
    if (nC != 0) begin
      $display("FAIL C causal invariance: %0d bytes differ in rows 0..2", nC);
      errs = errs + 1;
    end
    for (i = 0; i < H; i = i + 1) begin
      j = va[((i/64)/3)*64+(i%64)];
      if (gotC[i] !== j[7:0]) begin
        if (errs < 10)
          $display("FAIL C row0 reset: col=%0d got=%h want=%h", i, gotC[i], j[7:0]);
        errs = errs + 1;
      end
    end

    #20;
    if (errs == 0)
      $display("ATTN_STITCH PASS (frames A/B/C, S=%0d, tol=%0d)", S, TOL);
    else
      $display("ATTN_STITCH FAIL errs=%0d", errs);
    $finish;
  end

  initial begin
    #2000000;
    $display("ATTN_STITCH FAIL timeout");
    $finish;
  end
endmodule
