// tb_mac_array.v — self-checking unit test for mac_array (P=8 lanes).
// Oracle: array_golden.hex from src/tb/gen_mac_vectors.py (independent
// pure-python chained lane-sum, nonzero chain seed). Covers: reset/clr,
// chained accumulation vs golden, ce-hold, directed wrap corners.
module tb_mac_array;
  parameter W = 8, P = 8, M = 128;
  parameter SEED = 1000;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg                 ce = 0, clr = 0;
  reg  [P*W-1:0]      avec = 0, bvec = 0;
  reg  [31:0]         acc_in = 0;
  wire [31:0]         acc_out;

  mac_array #(.W(W), .P(P)) dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .avec(avec), .bvec(bvec), .acc_in(acc_in), .acc_out(acc_out)
  );

  reg [P*W-1:0] arows [0:M-1];
  reg [P*W-1:0] brows [0:M-1];
  reg [31:0]    golden [0:M-1];
  integer i, errs = 0;

  initial begin
    $readmemh("array_a.hex", arows);
    $readmemh("array_b.hex", brows);
    $readmemh("array_golden.hex", golden);
    #12 rst_n = 1;
    @(negedge clk); clr = 1; ce = 0;
    @(posedge clk); #2;
    if (acc_out !== 0) begin
      $display("MISMATCH: clr did not clear, got=%h", acc_out); errs = errs+1;
    end
    @(negedge clk); clr = 0;
    for (i = 0; i < M; i = i + 1) begin
      @(negedge clk);
      avec = arows[i]; bvec = brows[i];
      acc_in = (i == 0) ? SEED : golden[i-1];
      ce = 1'b1; clr = 1'b0;
      @(posedge clk); #2;
      if (acc_out !== golden[i]) begin
        $display("MISMATCH i=%0d: got=%h want=%h", i, acc_out, golden[i]);
        errs = errs + 1;
      end
      @(negedge clk); ce = 1'b0;
    end
    // ce-hold
    @(negedge clk);
    avec = {P*W{1'b1}}; bvec = {P*W{1'b1}}; acc_in = 32'h1234_5678; ce = 1'b0;
    @(posedge clk); #2;
    if (acc_out !== golden[M-1]) begin
      $display("MISMATCH: ce-hold moved, got=%h want=%h", acc_out, golden[M-1]);
      errs = errs + 1;
    end
    // directed wrap: 8 lanes of (-128*-128)=+131072 + seed near max
    @(negedge clk);
    avec = {P{8'h80}}; bvec = {P{8'h80}}; acc_in = 32'h7FFD_FFFF;
    ce = 1'b1; clr = 1'b0;
    @(posedge clk); #2;
    // psum=8*16384=131072; 0x7FFDFFFF+131072 = 0x7FFFFFFF exact, no wrap
    if (acc_out !== 32'h7FFF_FFFF) begin
      $display("MISMATCH: wrap corner got=%h want=7fffffff", acc_out);
      errs = errs + 1;
    end
    #20;
    if (errs == 0) $display("MAC_ARRAY PASS (%0d rows, P=%0d)", M, P);
    else           $display("MAC_ARRAY FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
