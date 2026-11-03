// tb_silu_lut — self-checking (step 8, RED-capable: elaborates on the
// skeleton, fails in sim because y is undriven).
// Oracle: baked checkpoint floats via gen_golden.py (16 baked SiLU vectors
// seed 0xB0CA + 10 edge cases), Q4.12, tolerance 2 LSB (0.000488).
// Run from repo root:
//   iverilog -o /tmp/tb_silu_lut src/components/silu_lut.v src/tb/silu_lut/tb_silu_lut.v && vvp /tmp/tb_silu_lut
`timescale 1ns / 1ps
module tb_silu_lut;
  localparam N = 26;
  localparam TOL = 2;

  reg [15:0] x;
  wire [15:0] y;

  silu_lut #(.W(16)) dut (.x(x), .y(y));

  reg [15:0] stim [0:N-1];
  reg [15:0] gold [0:N-1];
  integer i, errs, diff;

  initial begin
    $readmemh("src/tb/silu_lut/stim.hex", stim);
    $readmemh("src/tb/silu_lut/golden.hex", gold);
    errs = 0;

    // 1. Golden vectors (baked floats + edges) within TOL LSB.
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
    $display("silu golden vectors done errs=%0d", errs);

    // 2. Structural: exact zero at x=0 (table entry, no interp).
    x = 16'h0000; #1;
    if (y !== 16'h0000) begin
      $display("FAIL zero x=0 got=%h want=0000", y);
      errs = errs + 1;
    end

    // 3. Full-range bounds sweep: every Q4.12 code must land inside the
    // SiLU image +/- TOL (min -1141, max 32756 per the float oracle).
    for (i = 0; i < 65536; i = i + 1) begin
      x = i[15:0]; #1;
      if (^y === 1'bx) begin
        if (errs < 5) $display("FAIL sweep undriven at x=%h", x);
        errs = errs + 1;
      end else if ($signed(y) < -1143 || $signed(y) > 32758) begin
        if (errs < 5) $display("FAIL sweep x=%h y=%0d out of image", x, $signed(y));
        errs = errs + 1;
      end
    end
    $display("silu bounds sweep done errs=%0d", errs);

    if (errs == 0) $display("SILU PASS (%0d vectors + sweep, tol=%0d LSB)", N, TOL);
    else           $display("SILU FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
