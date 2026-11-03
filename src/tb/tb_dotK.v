// tb_dotK.v — self-checking unit test for dotK (K=16 lanes).
// Oracle: dotK_golden.hex from src/tb/gen_mac_vectors.py (independent
// pure-python full dot). Protocol: pulse start, y valid with done==1 one
// cycle later; y holds while start==0. Plus one directed max corner.
module tb_dotK;
  parameter W = 8, K = 16, M = 64;

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

  reg [K*W-1:0] arows [0:M-1];
  reg [K*W-1:0] brows [0:M-1];
  reg [31:0]    golden [0:M-1];
  integer i, errs = 0;

  initial begin
    $readmemh("dotK_a.hex", arows);
    $readmemh("dotK_b.hex", brows);
    $readmemh("dotK_golden.hex", golden);
    #12 rst_n = 1;
    @(negedge clk);
    if (done !== 1'b0) begin
      $display("MISMATCH: done after reset =%b", done); errs = errs+1;
    end
    for (i = 0; i < M; i = i + 1) begin
      @(negedge clk);
      avec = arows[i]; bvec = brows[i]; start = 1'b1;
      @(posedge clk); #2;
      if (done !== 1'b1) begin
        $display("MISMATCH i=%0d: done=%b, want 1", i, done); errs = errs+1;
      end
      if (y !== golden[i]) begin
        $display("MISMATCH i=%0d: got=%h want=%h", i, y, golden[i]);
        errs = errs + 1;
      end
      @(negedge clk); start = 1'b0;
      @(posedge clk); #2;
      if (done !== 1'b0) begin
        $display("MISMATCH i=%0d: done stuck =%b", i, done); errs = errs+1;
      end
      if (y !== golden[i]) begin
        $display("MISMATCH i=%0d: y not held, got=%h want=%h", i, y, golden[i]);
        errs = errs + 1;
      end
    end
    // directed max corner: 16x(-128*-128) = 262144 = 0x40000
    @(negedge clk);
    avec = {K{8'h80}}; bvec = {K{8'h80}}; start = 1'b1;
    @(posedge clk); #2;
    if (y !== 32'h0004_0000 || done !== 1'b1) begin
      $display("MISMATCH: max corner y=%h done=%b", y, done); errs = errs+1;
    end
    #20;
    if (errs == 0) $display("DOTK PASS (%0d dots, K=%0d)", M, K);
    else           $display("DOTK FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
