// tb_regfile_dp_init — INIT_FILE acceptance (GREEN-only): the file preloads
// from a $readmemh image of baked checkpoint bytes (init.hex packs the first
// 256 bytes of weights/bake/layer0_q_proj.hex little-endian into 64x32b).
`timescale 1ns / 1ps
module tb_regfile_dp_init;
  localparam W = 32;
  localparam N = 64;
  localparam AW = 6;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [AW-1:0] ra = 0, rb = 0;
  wire [W-1:0] rda, rdb;

  regfile_dp #(.W(W), .N(N), .INIT_FILE("src/tb/regfile_dp/init.hex")) dut (
    .clk(clk), .ra(ra), .rb(rb), .wa(6'd0), .wdata(32'd0), .we(1'b0),
    .rda(rda), .rdb(rdb)
  );

  reg [W-1:0] want [0:N-1];
  integer i, errs;

  initial begin
    $readmemh("src/tb/regfile_dp/init.hex", want);
    errs = 0;
    repeat (2) @(posedge clk);
    for (i = 0; i < N; i = i + 1) begin
      ra = i[AW-1:0]; rb = (N - 1 - i); #2;
      if (rda !== want[i]) begin
        $display("FAIL init rda addr=%0d got=%h want=%h", i, rda, want[i]);
        errs = errs + 1;
      end
      if (rdb !== want[N - 1 - i]) begin
        $display("FAIL init rdb addr=%0d got=%h want=%h",
                 N - 1 - i, rdb, want[N - 1 - i]);
        errs = errs + 1;
      end
    end
    if (errs == 0) $display("PASS tb_regfile_dp_init");
    else begin $display("FAIL tb_regfile_dp_init errs=%0d", errs); $fatal; end
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL tb_regfile_dp_init watchdog timeout");
    $fatal;
  end
endmodule
