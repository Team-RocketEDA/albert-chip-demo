// tb_ffn_wbind — ffn_tile weight-bind + full-dim-engine regression.
// DEFECTS UNDER TEST (red on the slice-scoped RTL):
//   (1) WG/WU/WD_FILE params missing -> weights all-zero in sim;
//   (2) kk_cnt 3-bit can never reach FF-1 (FF>8 hangs in ST_DSTREAM);
//   (3) 64-bit h_dword/mid path drops FF-8 h entries per row;
//   (4) 8KB weight banks truncate full-dim addresses.
// Config S=1,H=64,FF=16 with committed tiny hex (gen_tiny.py): FF=16
// exercises the multi-word mid path (2 words/row) in seconds.
// Oracle: tiny_y_golden.hex = exact bit-model of the fixed-point chain.
// RUN FROM THE REPO ROOT:
//   iverilog -g2012 -s tb_ffn_wbind -o /tmp/ffnw \
//     src/components/fifo_sync.v src/components/mac_array.v \
//     src/components/ffn_tile.v src/components/regfile_dp.v \
//     src/components/requant.v src/components/seq_fsm.v \
//     src/components/silu_lut.v src/components/sram_1r1w.v \
//     src/tb/ffn_tile_stitch/tb_ffn_wbind.v && vvp /tmp/ffnw
`timescale 1ns / 1ps
module tb_ffn_wbind;
  localparam S = 1;
  localparam H = 64;
  localparam FF = 16;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [S*H*8-1:0] x_in = 0;
  reg              x_valid = 0;
  reg              start = 0;
  wire             x_ready;
  wire [S*H*8-1:0] y_out;
  wire             y_valid;
  wire             done;

  ffn_tile #(
    .S(S), .H(H), .FF(FF),
    .WG_FILE("src/tb/ffn_tile_stitch/tiny_wg.hex"),
    .WU_FILE("src/tb/ffn_tile_stitch/tiny_wu.hex"),
    .WD_FILE("src/tb/ffn_tile_stitch/tiny_wd.hex")
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .x_in(x_in), .x_valid(x_valid), .start(start),
    .x_ready(x_ready),
    .y_out(y_out), .y_valid(y_valid), .done(done)
  );

  reg [7:0] X [0:H-1];
  reg [7:0] gold [0:H-1];

  integer i, cyc, errs;

  initial begin
    errs = 0;
    $readmemh("src/tb/ffn_tile_stitch/tiny_x.hex", X);
    $readmemh("src/tb/ffn_tile_stitch/tiny_y_golden.hex", gold);
    for (i = 0; i < H; i = i + 1)
      x_in[i*8 +: 8] = X[i];

    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;
    x_valid = 1'b1; start = 1'b1;
    @(posedge clk); #1;
    x_valid = 1'b0; start = 1'b0;

    // Bound: ~2.5k cycles/frame at these dims; hang (kk 3-bit) trips this.
    cyc = 0;
    while (done !== 1'b1 && cyc < 100000) begin
      @(posedge clk); #1;
      cyc = cyc + 1;
    end
    if (done !== 1'b1) begin
      $display("FFN_WBIND FAIL done never asserted after %0d cycles (hang?)", cyc);
      $finish;
    end
    $display("frame done after %0d cycles", cyc);
    if (y_valid !== 1'b1) begin
      $display("FFN_WBIND FAIL y_valid=%b want 1 at done", y_valid);
      errs = errs + 1;
    end
    if ($isunknown(y_out)) begin
      $display("FFN_WBIND FAIL y_out undriven");
      errs = errs + 1;
    end else begin
      for (i = 0; i < H; i = i + 1) begin
        if (y_out[i*8 +: 8] !== gold[i]) begin
          if (errs < 8)
            $display("FFN_WBIND FAIL y[%0d]=%h want=%h", i, y_out[i*8 +: 8], gold[i]);
          errs = errs + 1;
        end
      end
    end
    if (errs == 0)
      $display("FFN_WBIND PASS (S=%0d,H=%0d,FF=%0d full-chain exact)", S, H, FF);
    else
      $display("FFN_WBIND FAIL errs=%0d", errs);
    $finish;
  end

  initial begin
    #2000000;
    $display("FFN_WBIND FAIL timeout");
    $finish;
  end
endmodule
