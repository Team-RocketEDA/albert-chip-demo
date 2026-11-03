// tb_div_unit — self-checking tb for div_unit (step 11, RED-capable:
// elaborates on the skeleton, fails in sim because quot/done undriven).
// Oracle: stim/golden hex from gen_golden.py (independent pure-stdlib
// floor-division oracle over directed corners + seeded random + baked
// softmax-reciprocal/norm-mean vectors). Bit-exact (0 ulp).
// Protocol under test (single-shot, matches dotK): present numer/denom
// with start=1; at the next posedge quot latches and done pulses for
// exactly one cycle; quot holds and done drops while start=0.
// denom==0 saturates quot to all-ones by contract.
// Run from repo root:
//   iverilog -o /tmp/tb_div_unit src/components/div_unit.v src/tb/div_unit/tb_div_unit.v && vvp /tmp/tb_div_unit
`timescale 1ns / 1ps
module tb_div_unit;
  parameter N = 200;  // file-depth bound (>= gen count)
  parameter M = 16;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  // W=32 general lane
  reg  [31:0] numer = 0, denom = 0;
  reg         start = 0;
  wire [31:0] quot;
  wire        done;
  div_unit #(.W(32)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .numer(numer), .denom(denom), .quot(quot), .done(done)
  );

  // W=16 reciprocal lane (softmax_d u_recip operating point)
  reg  [15:0] numer16 = 0, denom16 = 0;
  reg         start16 = 0;
  wire [15:0] quot16;
  wire        done16;
  div_unit #(.W(16)) dut16 (
    .clk(clk), .rst_n(rst_n), .start(start16),
    .numer(numer16), .denom(denom16), .quot(quot16), .done(done16)
  );

  reg [31:0] n_mem [0:N-1];
  reg [31:0] d_mem [0:N-1];
  reg [31:0] g_mem [0:N-1];
  reg [15:0] n16_mem [0:M-1];
  reg [15:0] d16_mem [0:M-1];
  reg [15:0] g16_mem [0:M-1];
  reg [31:0] cnt_mem [0:0];
  reg [31:0] cnt16_mem [0:0];

  integer i, n, m, errs = 0;
  reg [31:0] hold_q;
  reg [15:0] hold_q16;

  task check32(input [31:0] tn, input [31:0] td, input [31:0] want);
    begin
      @(negedge clk);
      numer = tn; denom = td; start = 1'b1;
      @(posedge clk); #2;
      if (^quot === 1'bx || ^done === 1'bx) begin
        $display("FAIL32 n=%h d=%h quot/done undriven (skeleton)", tn, td);
        errs = errs + 1;
      end else begin
        if (done !== 1'b1) begin
          $display("FAIL32 n=%h d=%h done=%b want=1", tn, td, done);
          errs = errs + 1;
        end
        if (quot !== want) begin
          $display("FAIL32 n=%h d=%h got=%h want=%h", tn, td, quot, want);
          errs = errs + 1;
        end
      end
      hold_q = quot;
      @(negedge clk); start = 1'b0;
      @(posedge clk); #2;
      if (done !== 1'b0) begin
        $display("FAIL32-hold n=%h d=%h done stuck=%b", tn, td, done);
        errs = errs + 1;
      end
      if ((^hold_q !== 1'bx) && (quot !== hold_q)) begin
        $display("FAIL32-hold n=%h d=%h quot moved %h->%h", tn, td, hold_q, quot);
        errs = errs + 1;
      end
    end
  endtask

  task check16(input [15:0] tn, input [15:0] td, input [15:0] want);
    begin
      @(negedge clk);
      numer16 = tn; denom16 = td; start16 = 1'b1;
      @(posedge clk); #2;
      if (^quot16 === 1'bx || ^done16 === 1'bx) begin
        $display("FAIL16 n=%h d=%h quot/done undriven (skeleton)", tn, td);
        errs = errs + 1;
      end else begin
        if (done16 !== 1'b1) begin
          $display("FAIL16 n=%h d=%h done=%b want=1", tn, td, done16);
          errs = errs + 1;
        end
        if (quot16 !== want) begin
          $display("FAIL16 n=%h d=%h got=%h want=%h", tn, td, quot16, want);
          errs = errs + 1;
        end
      end
      hold_q16 = quot16;
      @(negedge clk); start16 = 1'b0;
      @(posedge clk); #2;
      if (done16 !== 1'b0) begin
        $display("FAIL16-hold n=%h d=%h done stuck=%b", tn, td, done16);
        errs = errs + 1;
      end
      if ((^hold_q16 !== 1'bx) && (quot16 !== hold_q16)) begin
        $display("FAIL16-hold n=%h d=%h quot moved %h->%h", tn, td, hold_q16, quot16);
        errs = errs + 1;
      end
    end
  endtask

  initial begin
    $readmemh("src/tb/div_unit/stim_numer.hex", n_mem);
    $readmemh("src/tb/div_unit/stim_denom.hex", d_mem);
    $readmemh("src/tb/div_unit/golden.hex", g_mem);
    $readmemh("src/tb/div_unit/stim16_numer.hex", n16_mem);
    $readmemh("src/tb/div_unit/stim16_denom.hex", d16_mem);
    $readmemh("src/tb/div_unit/golden16.hex", g16_mem);
    $readmemh("src/tb/div_unit/vec_count.hex", cnt_mem);
    $readmemh("src/tb/div_unit/vec16_count.hex", cnt16_mem);
    n = cnt_mem[0]; m = cnt16_mem[0];
    if (n <= 0 || n > N || m <= 0 || m > M) begin
      $display("DIV FAIL bad vec counts n=%0d m=%0d", n, m);
      $finish;
    end

    // Reset: quot/done held 0 while rst_n low.
    #12;
    if (quot !== 32'h0 && (^quot !== 1'bx)) begin
      $display("FAIL reset quot=%h want=0", quot); errs = errs + 1;
    end
    if (^quot === 1'bx) begin
      $display("FAIL reset quot undriven (skeleton)"); errs = errs + 1;
    end
    if (done !== 1'b0 && (^done !== 1'bx)) begin
      $display("FAIL reset done=%b want=0", done); errs = errs + 1;
    end
    if (^done === 1'bx) begin
      $display("FAIL reset done undriven (skeleton)"); errs = errs + 1;
    end
    rst_n = 1;
    @(negedge clk);

    // W=32 file vectors (every golden row the generator emitted).
    for (i = 0; i < n; i = i + 1)
      check32(n_mem[i], d_mem[i], g_mem[i]);

    // W=16 recip-lane file vectors.
    for (i = 0; i < m; i = i + 1)
      check16(n16_mem[i], d16_mem[i], g16_mem[i]);

    if (errs == 0) $display("DIV PASS (%0d x W=32 + %0d x W=16, bit-exact)", n, m);
    else           $display("DIV FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
