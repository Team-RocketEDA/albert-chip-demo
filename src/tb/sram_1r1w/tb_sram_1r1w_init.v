// tb_sram_1r1w_init — INIT_FILE acceptance (GREEN-only): the bank preloads
// from a $readmemh image of baked checkpoint bytes (init.hex = first 64
// bytes of weights/bake/layer0_q_proj.hex) with no writes applied.
`timescale 1ns / 1ps
module tb_sram_1r1w_init;
  localparam W = 8;
  localparam N = 64;
  localparam AW = 6;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [AW-1:0] ra = 0;
  wire [W-1:0] rdata;

  sram_1r1w #(.W(W), .N(N), .INIT_FILE("src/tb/sram_1r1w/init.hex")) dut (
    .clk(clk), .ra(ra), .wa(6'd0), .wdata(8'd0), .we(1'b0), .rdata(rdata)
  );

  reg [W-1:0] want [0:N-1];
  integer i, errs;

  initial begin
    $readmemh("src/tb/sram_1r1w/init.hex", want);
    errs = 0;
    repeat (2) @(posedge clk);
    for (i = 0; i < N; i = i + 1) begin
      @(negedge clk); ra = i[AW-1:0];
      @(posedge clk); #1;
      if (rdata !== want[i]) begin
        $display("FAIL init addr=%0d got=%h want=%h", i, rdata, want[i]);
        errs = errs + 1;
      end
    end
    if (errs == 0) $display("PASS tb_sram_1r1w_init");
    else begin $display("FAIL tb_sram_1r1w_init errs=%0d", errs); $fatal; end
    $finish;
  end

  initial begin
    #100000;
    $display("FAIL tb_sram_1r1w_init watchdog timeout");
    $fatal;
  end
endmodule
