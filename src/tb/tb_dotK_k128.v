// tb_dotK_k128.v — regression: dotK at its DEFAULT K=128 (EMBED DOT128).
// The K=16 unit test + K=16 formal proof do not cover the shipped default.
// Self-contained (no hex files): deterministic vectors + a 64-bit tb-side
// reference; y must equal rsum[31:0] exactly (mod-2^32 contract).
module tb_dotK_k128;
  parameter W = 8, K = 128, M = 40;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg             start = 0;
  reg [K*W-1:0]   avec = 0, bvec = 0;
  wire [31:0]     y;
  wire            done;

  dotK #(.W(W), .K(K)) dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .avec(avec), .bvec(bvec), .y(y), .done(done)
  );

  reg signed [63:0] rsum;
  integer i, j, errs = 0;
  reg signed [W-1:0] av, bv;

  task shot;
    input integer tag;
    begin
      @(negedge clk);
      start = 1'b1;
      @(posedge clk); #2;
      if (done !== 1'b1) begin
        $display("MISMATCH tag=%0d: done=%b, want 1", tag, done); errs = errs+1;
      end
      if (y !== rsum[31:0]) begin
        $display("MISMATCH tag=%0d: got=%h want=%h", tag, y, rsum[31:0]); errs = errs+1;
      end
      @(negedge clk); start = 1'b0;
      @(posedge clk); #2;
      if (done !== 1'b0) begin
        $display("MISMATCH tag=%0d: done stuck =%b", tag, done); errs = errs+1;
      end
      if (y !== rsum[31:0]) begin
        $display("MISMATCH tag=%0d: y not held, got=%h want=%h", tag, y, rsum[31:0]); errs = errs+1;
      end
    end
  endtask

  initial begin
    #12 rst_n = 1;
    // directed max corner: 128 x (-128 x -128) = 2097152 = 0x200000
    for (j = 0; j < K; j = j + 1) begin
      avec[j*W+:W] = 8'h80; bvec[j*W+:W] = 8'h80;
    end
    rsum = 64'sd2097152;
    shot(1001);
    if (y !== 32'h0020_0000) begin
      $display("MISMATCH max corner: y=%h want=00200000", y); errs = errs+1;
    end
    // directed min corner: 128 x (127 x -128) = -2080768
    for (j = 0; j < K; j = j + 1) begin
      avec[j*W+:W] = 8'h7f; bvec[j*W+:W] = 8'h80;
    end
    rsum = -64'sd2080768;
    shot(1002);
    // deterministic pseudo-random vectors, tb-side 64-bit reference
    for (i = 0; i < M; i = i + 1) begin
      rsum = 64'sd0;
      for (j = 0; j < K; j = j + 1) begin
        av = ((i*131 + j*73 + 11) % 256) - 128;
        bv = ((i*197 + j*37 + 5) % 256) - 128;
        avec[j*W+:W] = av; bvec[j*W+:W] = bv;
        rsum = rsum + av * bv;
      end
      shot(i);
    end
    // alternating extremes (max lane-magnitude churn)
    for (j = 0; j < K; j = j + 1) begin
      avec[j*W+:W] = (j[0] == 1'b0) ? 8'h80 : 8'h7f;
      bvec[j*W+:W] = (j[0] == 1'b0) ? 8'h7f : 8'h80;
    end
    rsum = 64'sd0;
    for (j = 0; j < K; j = j + 1) rsum = rsum - 64'sd16256;
    shot(1003);
    #20;
    if (errs == 0) $display("DOTK_K128 PASS (%0d vectors + 3 corners, K=%0d)", M, K);
    else           $display("DOTK_K128 FAIL (%0d errs)", errs);
    if (errs != 0) $fatal;
    $finish;
  end
endmodule
