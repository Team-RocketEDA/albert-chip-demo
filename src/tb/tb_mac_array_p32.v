// tb_mac_array_p32.v — regression: mac_array at its DEFAULT P=32.
// The P=8 unit test does not cover the shipped default lane count.
// Self-contained (no hex files): deterministic vectors + a 64-bit tb-side
// reference; acc_out must equal rsum[31:0] exactly (mod-2^32 contract).
// acc_in fold path is exercised with nonzero carry-in values.
module tb_mac_array_p32;
  parameter W = 8, P = 32, M = 40;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg             ce = 0, clr = 0;
  reg [P*W-1:0]   avec = 0, bvec = 0;
  reg [31:0]      acc_in = 0;
  wire [31:0]     acc_out;

  mac_array #(.W(W), .P(P)) dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .avec(avec), .bvec(bvec), .acc_in(acc_in), .acc_out(acc_out)
  );

  reg signed [63:0] rsum;
  integer i, j, errs = 0;
  reg signed [W-1:0] av, bv;
  reg signed [31:0] carry;

  initial begin
    #12 rst_n = 1;
    @(negedge clk);
    // directed max corner with carry: acc_in + 32 x (-128 x -128)
    carry = 32'sd1234567;
    acc_in = carry; ce = 1'b1;
    for (j = 0; j < P; j = j + 1) begin
      avec[j*W+:W] = 8'h80; bvec[j*W+:W] = 8'h80;
    end
    rsum = carry + 64'sd524288; // 32 x 16384
    @(posedge clk); #2;
    if (acc_out !== rsum[31:0]) begin
      $display("MISMATCH max corner: got=%h want=%h", acc_out, rsum[31:0]); errs = errs+1;
    end
    // deterministic pseudo-random vectors with random-ish carry-ins
    for (i = 0; i < M; i = i + 1) begin
      carry = (i*2654435761) % 32'sd2000000000 - 32'sd1000000000;
      acc_in = carry;
      rsum = carry;
      for (j = 0; j < P; j = j + 1) begin
        av = ((i*131 + j*73 + 11) % 256) - 128;
        bv = ((i*197 + j*37 + 5) % 256) - 128;
        avec[j*W+:W] = av; bvec[j*W+:W] = bv;
        rsum = rsum + av * bv;
      end
      @(negedge clk);
      @(posedge clk); #2;
      if (acc_out !== rsum[31:0]) begin
        $display("MISMATCH i=%0d: got=%h want=%h", i, acc_out, rsum[31:0]); errs = errs+1;
      end
    end
    // clr path: output returns to zero
    @(negedge clk); ce = 1'b0; clr = 1'b1;
    @(posedge clk); #2;
    if (acc_out !== 32'd0) begin
      $display("MISMATCH clr: got=%h want=0", acc_out); errs = errs+1;
    end
    // hold path: ce=0, clr=0 keeps value
    @(negedge clk); clr = 1'b0;
    @(posedge clk); #2;
    if (acc_out !== 32'd0) begin
      $display("MISMATCH hold: got=%h want=0", acc_out); errs = errs+1;
    end
    #20;
    if (errs == 0) $display("MAC_ARRAY_P32 PASS (%0d rows + corner, P=%0d)", M, P);
    else           $display("MAC_ARRAY_P32 FAIL (%0d errs)", errs);
    if (errs != 0) $fatal;
    $finish;
  end
endmodule
