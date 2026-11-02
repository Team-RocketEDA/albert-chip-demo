// tb_mac_unit.v — self-checking: streams mac_a/b.hex, compares acc vs
// mac_golden.hex (running sum, independent python oracle). PASS/FAIL print.
module tb_mac_unit;
  parameter W = 8, ACC = 32, N = 64;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg                  ce = 0, clr = 0;
  reg  signed [W-1:0]  a = 0, b = 0;
  reg  signed [ACC-1:0] acc_in = 0;
  wire signed [ACC-1:0] acc_out;

  mac_unit #(.W(W), .ACC(ACC)) dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .a(a), .b(b), .acc_in(acc_in), .acc_out(acc_out)
  );

  reg signed [W-1:0]   avec [0:N-1];
  reg signed [W-1:0]   bvec [0:N-1];
  reg signed [ACC-1:0] golden [0:N-1];
  integer i, errs = 0;

  initial begin
    $readmemh("mac_a.hex", avec);
    $readmemh("mac_b.hex", bvec);
    $readmemh("mac_golden.hex", golden);
    #12 rst_n = 1;
    clr = 1; @(posedge clk); clr = 0;
    acc_in = 0;
    for (i = 0; i < N; i = i + 1) begin
      a <= avec[i]; b <= bvec[i]; acc_in <= (i == 0) ? 0 : golden[i-1];
      ce <= 1'b1;
      @(posedge clk);
      #1;
      if (acc_out !== golden[i]) begin
        $display("MISMATCH i=%0d: got %0d want %0d", i, acc_out, golden[i]);
        errs = errs + 1;
      end
      ce <= 1'b0;
    end
    #20;
    if (errs == 0) $display("MAC PASS (%0d iters, W=%0d)", N, W);
    else           $display("MAC FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
