// tb_mac_unit.v — self-checking unit test for mac_unit.
// Oracle: mac_golden.hex from src/tb/gen_mac_vectors.py (independent
// pure-python running sum, nonzero chain seed). Covers: reset/clr clear,
// chained accumulation vs golden, ce-hold, directed 32-bit wrap corners.
// PASS/FAIL print, nonzero $finish.
module tb_mac_unit;
  parameter W = 8, ACC = 32, N = 256;
  parameter SEED = 1000;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg                  ce = 0, clr = 0;
  reg  [W-1:0]         a = 0, b = 0;
  reg  [ACC-1:0]       acc_in = 0;
  wire [ACC-1:0]       acc_out;

  mac_unit #(.W(W), .ACC(ACC)) dut (
    .clk(clk), .rst_n(rst_n), .ce(ce), .clr(clr),
    .a(a), .b(b), .acc_in(acc_in), .acc_out(acc_out)
  );

  reg [W-1:0]   avec [0:N-1];
  reg [W-1:0]   bvec [0:N-1];
  reg [ACC-1:0] golden [0:N-1];
  integer i, errs = 0;

  task step(input [W-1:0] ta, input [W-1:0] tb,
            input [ACC-1:0] tacc, input [ACC-1:0] want);
    begin
      @(negedge clk);
      a = ta; b = tb; acc_in = tacc; ce = 1'b1; clr = 1'b0;
      @(posedge clk); #2;
      if (acc_out !== want) begin
        $display("MISMATCH: a=%h b=%h acc_in=%h got=%h want=%h",
                 ta, tb, tacc, acc_out, want);
        errs = errs + 1;
      end
      @(negedge clk); ce = 1'b0;
    end
  endtask

  initial begin
    $readmemh("mac_a.hex", avec);
    $readmemh("mac_b.hex", bvec);
    $readmemh("mac_golden.hex", golden);
    #12 rst_n = 1;
    // reset/clr must read zero
    @(negedge clk); clr = 1; ce = 0;
    @(posedge clk); #2;
    if (acc_out !== 0) begin
      $display("MISMATCH: clr did not clear, got=%h", acc_out); errs = errs+1;
    end
    @(negedge clk); clr = 0;
    // chained golden stream
    for (i = 0; i < N; i = i + 1)
      step(avec[i], bvec[i], (i == 0) ? SEED : golden[i-1], golden[i]);
    // ce-hold: change inputs with ce=0, output must freeze
    @(negedge clk);
    a = 8'h7F; b = 8'h7F; acc_in = 32'hDEAD_BEEF; ce = 1'b0; clr = 1'b0;
    @(posedge clk); #2;
    if (acc_out !== golden[N-1]) begin
      $display("MISMATCH: ce-hold moved, got=%h want=%h", acc_out, golden[N-1]);
      errs = errs + 1;
    end
    // directed 32-bit wrap corners (values hand-verified vs python ints)
    step(8'h7F, 8'h7F, 32'h7FFF_FFFF, 32'h8000_3F00); // 2147483647+16129 wraps
    step(8'h80, 8'h80, 32'hFFFF_FFFF, 32'h0000_3FFF); // -1+16384
    step(8'h80, 8'h7F, 32'h0000_0000, 32'hFFFF_C080); // -16256
    step(8'h01, 8'h80, 32'h8000_0000, 32'h7FFF_FF80); // min+(-128)
    // clr at end
    @(negedge clk); clr = 1; ce = 0;
    @(posedge clk); #2;
    if (acc_out !== 0) begin
      $display("MISMATCH: final clr, got=%h", acc_out); errs = errs+1;
    end
    #20;
    if (errs == 0) $display("MAC_UNIT PASS (%0d iters, W=%0d)", N, W);
    else           $display("MAC_UNIT FAIL (%0d errs)", errs);
    $finish;
  end
endmodule
