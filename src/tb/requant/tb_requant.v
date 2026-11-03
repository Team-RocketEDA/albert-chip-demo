// tb_requant.v — self-checking tb for requant (W=8, SHIFT=8).
// File-driven: stim_acc/scale/zero.hex + golden.hex from
// gen_requant_vectors.py (stdlib oracle over baked checkpoint bytes).
// DUT has one registered stage: inputs applied at negedge, checked at
// the next negedge; valid must read 1 throughout (0 during reset).
module tb_requant;
  parameter SHIFT = 8;
  parameter MAXV  = 8192;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [31:0] acc_wide = 0;
  reg  [15:0] scale = 0;
  reg  [15:0] zero = 0;
  wire [7:0]  act_int;
  wire        valid;

  // SHIFT rides the dut default (8, Q8.8); pinned by requant.sby + manifest.
  requant #(.W(8)) dut (
    .clk(clk), .rst_n(rst_n),
    .acc_wide(acc_wide), .scale(scale), .zero(zero),
    .act_int(act_int), .valid(valid)
  );

  reg [31:0] acc_mem   [0:MAXV-1];
  reg [15:0] scale_mem [0:MAXV-1];
  reg [15:0] zero_mem  [0:MAXV-1];
  reg [7:0]  gold_mem  [0:MAXV-1];
  reg [31:0] cnt_mem   [0:0];

  integer i, n, errs = 0, got = 0;

  initial begin
    $readmemh("stim_acc.hex", acc_mem);
    $readmemh("stim_scale.hex", scale_mem);
    $readmemh("stim_zero.hex", zero_mem);
    $readmemh("golden.hex", gold_mem);
    $readmemh("vec_count.hex", cnt_mem);
    n = cnt_mem[0];
    if (n <= 0 || n > MAXV) begin
      $display("REQUANT FAIL bad vec count %0d", n);
      $finish;
    end

    // Reset: outputs held 0, valid low.
    #12;
    if (valid !== 1'b0) begin
      $display("REQUANT FAIL valid during reset = %b", valid);
      errs = errs + 1;
    end
    rst_n = 1;
    @(negedge clk); // one idle cycle: pipeline arms, valid goes high

    for (i = 0; i < n; i = i + 1) begin
      @(negedge clk);
      acc_wide <= acc_mem[i];
      scale    <= scale_mem[i];
      zero     <= zero_mem[i];
      @(negedge clk); // dut samples; outputs settle by next negedge
      #1;
      got = got + 1;
      if (valid !== 1'b1) begin
        $display("MISMATCH %0d: valid=%b want 1", i, valid);
        errs = errs + 1;
      end
      if (act_int !== gold_mem[i]) begin
        $display("MISMATCH %0d: acc=%h scale=%h zero=%h got=%h want=%h",
                 i, acc_mem[i], scale_mem[i], zero_mem[i],
                 act_int, gold_mem[i]);
        errs = errs + 1;
      end
    end

    #20;
    if (errs == 0 && got == n)
      $display("REQUANT PASS (%0d vectors)", n);
    else
      $display("REQUANT FAIL errs=%0d got=%0d want=%0d", errs, got, n);
    $finish;
  end

  // Watchdog: 4 cycles per vector is plenty for this 1-stage block.
  initial begin
    #400000;
    $display("REQUANT FAIL timeout");
    $finish;
  end
endmodule
