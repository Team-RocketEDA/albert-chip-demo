// tb_exp_lut — self-checking (step 8, RED-capable: elaborates on the
// skeleton, fails in sim because y is undriven).
// Oracle: baked softmax row via gen_golden.py (8 exp points from the
// tv_softmax_stim row seed 0xB0CB, d = score - max) + 10 edge cases,
// Q4.12, tolerance 2 LSB. Positive inputs clamp to 0x1000 by contract.
// Run from repo root:
//   iverilog -o /tmp/tb_exp_lut src/components/exp_lut.v src/tb/exp_lut/tb_exp_lut.v && vvp /tmp/tb_exp_lut
`timescale 1ns / 1ps
module tb_exp_lut;
  localparam N = 18;
  localparam TOL = 2;

  reg [15:0] x;
  wire [15:0] y;

  exp_lut #(.W(16)) dut (.x(x), .y(y));

  reg [15:0] stim [0:N-1];
  reg [15:0] gold [0:N-1];
  integer i, errs, diff;

  initial begin
    $readmemh("src/tb/exp_lut/stim.hex", stim);
    $readmemh("src/tb/exp_lut/golden.hex", gold);
    errs = 0;

    // 1. Golden vectors (baked exp points + edges) within TOL LSB.
    for (i = 0; i < N; i = i + 1) begin
      x = stim[i]; #1;
      if (^y === 1'bx) begin
        $display("FAIL vec=%0d x=%h y=undriven (skeleton)", i, x);
        errs = errs + 1;
      end else begin
        diff = $signed(y) - $signed(gold[i]);
        if (diff < 0) diff = -diff;
        if (diff > TOL) begin
          $display("FAIL vec=%0d x=%h got=%h(%0d) want=%h(%0d) err=%0d LSB",
                   i, x, y, $signed(y), gold[i], $signed(gold[i]), diff);
          errs = errs + 1;
        end
      end
    end
    $display("exp golden vectors done errs=%0d", errs);

    // 2. Structural: exp(0) = 1.0 exactly; positive clamp; floor entry.
    x = 16'h0000; #1;
    if (y !== 16'h1000) begin
      $display("FAIL exp(0) got=%h want=1000", y);
      errs = errs + 1;
    end
    x = 16'h4000; #1; // +4.0, unreachable after max-sub: clamp
    if (y !== 16'h1000) begin
      $display("FAIL pos-clamp got=%h want=1000", y);
      errs = errs + 1;
    end
    x = 16'h8000; #1; // -8.0 floor entry
    if (y !== 16'h0001) begin
      $display("FAIL floor got=%h want=0001", y);
      errs = errs + 1;
    end

    // 3. Full-domain bounds sweep: every code in [-8,0] lands in [0,4096],
    // every positive code clamps to 4096.
    for (i = 0; i < 65536; i = i + 1) begin
      x = i[15:0]; #1;
      if (^y === 1'bx) begin
        if (errs < 5) $display("FAIL sweep undriven at x=%h", x);
        errs = errs + 1;
      end else if ($signed(x) <= 0) begin
        if ($signed(y) < 0 || $signed(y) > 4096) begin
          if (errs < 5) $display("FAIL sweep x=%h y=%0d out of [0,4096]", x, $signed(y));
          errs = errs + 1;
        end
      end else begin
        if (y !== 16'h1000) begin
          if (errs < 5) $display("FAIL sweep pos x=%h y=%h want=1000", x, y);
          errs = errs + 1;
        end
      end
    end
    $display("exp bounds sweep done errs=%0d", errs);

    if (errs == 0) $display("EXP PASS (%0d vectors + sweep, tol=%0d LSB)", N, TOL);
    else           $display("EXP FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
