// tb_ffn_tile_stitch — stitch test for ffn_tile (SwiGLU FFN tile).
// Contract: architecture/blocks/06-ffn-tile.md.
// Datapath under test: X[SxH]s8 -> gate/up mats (parallel) -> silu_lut on
// gate psum (Q4.12 domain) -> inferred 16x16 elementwise gate*up + fxp
// rescale -> h8 -> down proj -> accum + requant -> Y[SxH]s8.
// Oracle: baked checkpoint bytes (weights/bake/):
//   X row0 = tv_gate_act.hex, X row1 = tv_up_act.hex (shared-X stitch: one
//   X row feeds BOTH gate and up, per the parent math X*Wg^T / X*Wu^T).
//   Wg/Wu/Wd = layer0_{gate,up,down}_proj.hex (row-major int8).
//   tv_gate_golden rows: exact s32 dots of X row0 (baked-exact DUT check).
//   tv_up_golden rows: exact s32 dots of X row1 (baked-exact DUT check).
//   tv_down act/golden: tb oracle self-check (validates tb-side weight
//   interpretation, not the DUT down path — DUT down is 8-wide h8).
// Fixed-point chain (stitch-calibrated, documented in ffn_tile.v):
//   gq/uq = sat_s16(psum >>> 2); sg = silu_lut(gq); prod = sg*uq (16x16);
//   h8 = sat_s8(prod >>> 20); Yacc = sum_j h8[j]*Wd[i][j];
//   y = sat_s8(Yacc >>> 6) via requant(scale=1, SHIFT=6, zero=0).
// RED-capable: on the skeleton y_out floats (Z) and done never asserts,
// so the undriven check + done timeout FAIL. GREEN (wired DUT):
//   iverilog -g2012 -DFFN_IMPL -o /tmp/tb_ffn_tile \
//     src/components/*.v src/tb/ffn_tile_stitch/tb_ffn_tile_stitch.v \
//     && vvp /tmp/tb_ffn_tile
// RED (skeleton check, hierarchical impl probes compiled out):
//   iverilog -g2012 -o /tmp/tb_ffn_tile_red \
//     src/components/*.v src/tb/ffn_tile_stitch/tb_ffn_tile_stitch.v \
//     && vvp /tmp/tb_ffn_tile_red   (expect FAIL)
// Run from repo root (repo-root-relative $readmemh below).
`timescale 1ns / 1ps
module tb_ffn_tile_stitch;
  localparam S = 2;
  localparam H = 576;
  localparam FF = 8;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [S*H*8-1:0] x_in = 0;
  reg              x_valid = 0;
  reg              start = 0;
  wire             x_ready;
  wire [S*H*8-1:0] y_out;
  wire             y_valid;
  wire             done;

  ffn_tile #(.S(S), .H(H), .FF(FF)) dut (
    .clk(clk), .rst_n(rst_n),
    .x_in(x_in), .x_valid(x_valid), .start(start),
    .x_ready(x_ready),
    .y_out(y_out), .y_valid(y_valid), .done(done)
  );

  // Reference-model SiLU oracle (leaf already proven; sim checks wiring).
  reg [15:0] ref_x = 0;
  wire [15:0] ref_y;
  silu_lut #(.W(16)) ref_silu (.x(ref_x), .y(ref_y));

  reg [7:0]  X0 [0:H-1];
  reg [7:0]  X1 [0:H-1];
  reg [7:0]  Xd [0:1535];
  reg [7:0]  Wg [0:1536*576-1];
  reg [7:0]  Wu [0:1536*576-1];
  reg [7:0]  Wd [0:576*1536-1];
  reg [31:0] Gg [0:7];
  reg [31:0] Gu [0:7];
  reg [31:0] Gd [0:7];

  integer i, j, k, c, cyc, errs, tot;
  integer d;
  integer Gref [0:7];
  integer Uref [0:7];
  integer gq, uq;
  integer h8 [0:7];
  integer Yacc;
  reg [7:0] exp_y [0:S*H-1];
  reg [7:0] got8;

  function integer s8(input [7:0] b);
    s8 = $signed(b);
  endfunction

  initial begin
    errs = 0; tot = 0;
    $readmemh("weights/bake/tv_gate_act.hex", X0);
    $readmemh("weights/bake/tv_up_act.hex", X1);
    $readmemh("weights/bake/tv_down_act.hex", Xd);
    $readmemh("weights/bake/layer0_gate_proj.hex", Wg);
    $readmemh("weights/bake/layer0_up_proj.hex", Wu);
    $readmemh("weights/bake/layer0_down_proj.hex", Wd);
    $readmemh("weights/bake/tv_gate_golden.hex", Gg);
    $readmemh("weights/bake/tv_up_golden.hex", Gu);
    $readmemh("weights/bake/tv_down_golden.hex", Gd);

    // 1. Oracle self-checks: prove the tb-side weight interpretation
    // (row-major, signed) reproduces the baked goldens exactly.
    for (j = 0; j < 8; j = j + 1) begin
      d = 0;
      for (k = 0; k < 576; k = k + 1) d = d + s8(X0[k]) * s8(Wg[j*576+k]);
      tot = tot + 1;
      if (d !== $signed(Gg[j])) begin
        $display("FAIL oracle gate j=%0d dot=%0d gold=%0d", j, d, $signed(Gg[j]));
        errs = errs + 1;
      end
    end
    $display("oracle gate layout: 8/8 checked errs=%0d", errs);
    for (j = 0; j < 8; j = j + 1) begin
      d = 0;
      for (k = 0; k < 576; k = k + 1) d = d + s8(X1[k]) * s8(Wu[j*576+k]);
      tot = tot + 1;
      if (d !== $signed(Gu[j])) begin
        $display("FAIL oracle up j=%0d dot=%0d gold=%0d", j, d, $signed(Gu[j]));
        errs = errs + 1;
      end
    end
    $display("oracle up layout: 8/8 checked errs=%0d", errs);
    for (i = 0; i < 8; i = i + 1) begin
      d = 0;
      for (k = 0; k < 1536; k = k + 1) d = d + s8(Xd[k]) * s8(Wd[i*1536+k]);
      tot = tot + 1;
      if (d !== $signed(Gd[i])) begin
        $display("FAIL oracle down i=%0d dot=%0d gold=%0d", i, d, $signed(Gd[i]));
        errs = errs + 1;
      end
    end
    $display("oracle down layout: 8/8 checked errs=%0d", errs);

    // 2. Backdoor-load the DUT weight SRAMs (first-FF-row slices).
    // (Slice scope FF=8: the bound INIT_FILE tables stay "" here, so the
    // host-load path carries the weights exactly as before the bind.)
    for (j = 0; j < FF; j = j + 1)
      for (k = 0; k < H; k = k + 1) begin
        dut.u_gatew.mem[j*H+k] = Wg[j*576+k];
        dut.u_upw.mem[j*H+k]   = Wu[j*576+k];
      end
    for (i = 0; i < H; i = i + 1)
      for (j = 0; j < FF; j = j + 1)
        dut.u_downw.mem[i*FF+j] = Wd[i*1536+j];

    // 3. Pack frame: row0 = tv_gate_act, row1 = tv_up_act.
    x_in = 0;
    for (c = 0; c < H; c = c + 1) begin
      x_in[(0*H+c)*8 +: 8] = X0[c];
      x_in[(1*H+c)*8 +: 8] = X1[c];
    end

    // 4. Reset, then single-frame issue.
    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;
    if (x_ready !== 1'b1) begin
      $display("FAIL x_ready=%b want 1 in IDLE", x_ready);
      errs = errs + 1;
    end
    tot = tot + 1;
    x_valid = 1'b1; start = 1'b1;
    @(posedge clk); #1;
    x_valid = 1'b0; start = 1'b0;

    // 5. Wait for frame done (bound: ~11k cycles/row + margin).
    cyc = 0;
    while (done !== 1'b1 && cyc < 100000) begin
      @(posedge clk); #1;
      cyc = cyc + 1;
    end
    tot = tot + 1;
    if (done !== 1'b1) begin
      $display("FAIL done never asserted after %0d cycles (skeleton?)", cyc);
      errs = errs + 1;
    end else begin
      $display("frame done after %0d cycles", cyc);
    end
    tot = tot + 1;
    if (y_valid !== 1'b1) begin
      $display("FAIL y_valid=%b want 1 at done", y_valid);
      errs = errs + 1;
    end
    tot = tot + 1;
    if ($isunknown(y_out)) begin
      $display("FAIL y_out undriven (skeleton)");
      errs = errs + 1;
    end

`ifdef FFN_IMPL
    // 6. Baked-exact intermediate checks (wired DUT only): gate psums of
    // row0 must equal tv_gate_golden; up psums of row1 must equal
    // tv_up_golden (row1 stimulus IS tv_up_act).
    for (j = 0; j < FF; j = j + 1) begin
      tot = tot + 1;
      if (dut.g_psum[0][j] !== $signed(Gg[j])) begin
        $display("FAIL row0 gate_psum[%0d]=%0d gold=%0d", j, dut.g_psum[0][j], $signed(Gg[j]));
        errs = errs + 1;
      end
      tot = tot + 1;
      if (dut.u_psum[1][j] !== $signed(Gu[j])) begin
        $display("FAIL row1 up_psum[%0d]=%0d gold=%0d", j, dut.u_psum[1][j], $signed(Gu[j]));
        errs = errs + 1;
      end
    end
    $display("baked psum spot-checks done errs=%0d", errs);
`endif

    // 7. Full-pipeline reference (procedural exact-integer chain + the
    // proven silu_lut leaf as oracle) vs DUT y_out, bit-exact.
    for (i = 0; i < S; i = i + 1) begin
      for (j = 0; j < FF; j = j + 1) begin
        d = 0;
        for (k = 0; k < H; k = k + 1)
          d = d + s8(i == 0 ? X0[k] : X1[k]) * s8(Wg[j*576+k]);
        Gref[j] = d;
        d = 0;
        for (k = 0; k < H; k = k + 1)
          d = d + s8(i == 0 ? X0[k] : X1[k]) * s8(Wu[j*576+k]);
        Uref[j] = d;
      end
      for (j = 0; j < FF; j = j + 1) begin
        // sat_s16(psum >>> 2): arithmetic shift, then inferred saturation
        // (mirrors the DUT; LUT input stays in the s16 Q4.12 domain).
        gq = Gref[j] >>> 2;
        if (gq > 32767) gq = 32767;
        if (gq < -32768) gq = -32768;
        uq = Uref[j] >>> 2;
        if (uq > 32767) uq = 32767;
        if (uq < -32768) uq = -32768;
        ref_x = gq[15:0]; #1;
        // 16x16 elementwise product, then fxp rescale before width growth.
        d = $signed(ref_y) * uq;
        d = d >>> 20;
        if (d > 127) d = 127;
        if (d < -128) d = -128;
        h8[j] = d;
      end
      for (k = 0; k < H; k = k + 1) begin
        Yacc = 0;
        for (j = 0; j < FF; j = j + 1)
          Yacc = Yacc + h8[j] * s8(Wd[k*1536+j]);
        // requant(scale=1, SHIFT=6, zero=0): (Yacc*1)>>>6 == Yacc>>>6.
        Yacc = Yacc >>> 6;
        if (Yacc > 127) Yacc = 127;
        if (Yacc < -128) Yacc = -128;
        exp_y[i*H+k] = Yacc[7:0];
      end
    end
    for (i = 0; i < S*H; i = i + 1) begin
      got8 = y_out[i*8 +: 8];
      tot = tot + 1;
      if (got8 !== exp_y[i]) begin
        if (errs < 8)
          $display("FAIL y[%0d] got=%0d(%h) exp=%0d(%h)", i, $signed(got8), got8,
                   $signed(exp_y[i]), exp_y[i]);
        errs = errs + 1;
      end
    end
    $display("y_out compare: %0d bytes errs=%0d", S*H, errs);

    if (errs == 0) $display("FFN_TILE_STITCH PASS (%0d checks)", tot);
    else           $display("FFN_TILE_STITCH FAIL (%0d errs / %0d checks)", errs, tot);
    $finish;
  end
endmodule
