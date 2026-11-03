// tb_outproj_tile_stitch.v — stitch tb for outproj_tile (S=1,H=576,C=8 proxy).
// Oracle (independent of the RTL): weights/bake/layer0_o_proj.hex (first 8
// rows = slice weights) + tv_o_act.hex / tv_o_golden.hex (exact
// int8xint8->s32 dots of the first 8 out-channels, seed 0xB0C4).
// RUN FROM THE REPO ROOT so the repo-root-relative $readmemh paths resolve:
//   iverilog -g2012 -s tb_outproj_tile_stitch -o /tmp/o \
//     src/components/*.v src/tb/outproj_tile_stitch/tb_outproj_tile_stitch.v
//   vvp /tmp/o
// Checks:
//  (1) idle framing: slice_valid=0, z_ready=1 out of reset;
//  (2) accum psums vs tv_o_golden.hex bit-exact (MAC K-fold + wrap split);
//  (3) slice_out bytes vs clip8(psum) (unity requant split, scale=256/SHIFT=8);
//  (4) re-frame 1->0->1 across a 2nd frame (y_valid framing trap).
module tb_outproj_tile_stitch;
  parameter S = 1, H = 576, C = 8;
  localparam integer NP = (H + 31) / 32;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [S*H*8-1:0] z_in = 0;
  reg              z_valid = 0;
  wire             z_ready;
  wire [S*C*8-1:0] slice_out;
  wire             slice_valid;

  outproj_tile #(.S(S), .H(H), .C(C)) dut (
    .clk(clk), .rst_n(rst_n),
    .z_in(z_in), .z_valid(z_valid), .z_ready(z_ready),
    .slice_out(slice_out), .slice_valid(slice_valid)
  );

  reg [7:0]  act [0:H-1];
  reg [31:0] gold [0:C-1];
  reg [7:0]  w8 [0:C*H-1];

  integer k, j, errs = 0, cnt;
  reg [255:0] wword;
  integer wj, wp, wi;

  // Independent unity-requant expectation: clip8(psum), same formula the
  // tile wires (scale=256 Q8.8 x1.0, SHIFT=8, zero=0), recomputed here.
  function [7:0] clip8;
    input [31:0] v;
    reg signed [31:0] sv;
    begin
      sv = $signed(v);
      if (sv > 32'sd127) clip8 = 8'h7f;
      else if (sv < -32'sd128) clip8 = 8'h80;
      else clip8 = sv[7:0];
    end
  endfunction

  task wait_valid;
    input integer tlim;
    begin
      cnt = 0;
      while (slice_valid !== 1'b1 && cnt < tlim) begin
        @(posedge clk);
        cnt = cnt + 1;
      end
    end
  endtask

  task wait_invalid;
    input integer tlim;
    begin
      cnt = 0;
      while (slice_valid !== 1'b0 && cnt < tlim) begin
        @(posedge clk);
        cnt = cnt + 1;
      end
    end
  endtask

  task check_frame;
    input integer fno;
    begin
      for (j = 0; j < C; j = j + 1) begin
        if (dut.u_accum.mem[j] !== gold[j]) begin
          $display("MISMATCH f%0d psum j=%0d: got=%h want=%h",
                   fno, j, dut.u_accum.mem[j], gold[j]);
          errs = errs + 1;
        end
        if (slice_out[j*8 +: 8] !== clip8(gold[j])) begin
          $display("MISMATCH f%0d byte j=%0d: got=%h want=%h (psum %h)",
                   fno, j, slice_out[j*8 +: 8], clip8(gold[j]), gold[j]);
          errs = errs + 1;
        end
      end
    end
  endtask

  initial begin
    $readmemh("weights/bake/tv_o_act.hex", act);
    $readmemh("weights/bake/tv_o_golden.hex", gold);
    // First C*H bytes of the row-major table = first C weight rows.
    $readmemh("weights/bake/layer0_o_proj.hex", w8);
    // Stationary slice pack: 32 K-bytes per wide SRAM row.
    for (wj = 0; wj < C; wj = wj + 1) begin
      for (wp = 0; wp < NP; wp = wp + 1) begin
        wword = 256'b0;
        for (wi = 0; wi < 32; wi = wi + 1)
          wword[wi*8 +: 8] = w8[wj*H + wp*32 + wi];
        dut.u_wsram.mem[wj*NP + wp] = wword;
      end
    end

    #12 rst_n = 1;
    @(negedge clk);
    // (1) idle framing
    if (slice_valid !== 1'b0) begin
      $display("MISMATCH idle: slice_valid=%b want 0", slice_valid);
      errs = errs + 1;
    end
    if (z_ready !== 1'b1) begin
      $display("MISMATCH idle: z_ready=%b want 1", z_ready);
      errs = errs + 1;
    end

    // frame 0
    for (k = 0; k < H; k = k + 1) z_in[k*8 +: 8] = act[k];
    @(negedge clk); z_valid = 1'b1;
    @(negedge clk); z_valid = 1'b0;
    wait_valid(20000);
    if (slice_valid !== 1'b1) begin
      $display("MISMATCH f0: slice_valid never rose (timeout)");
      errs = errs + 1;
    end else begin
      #1;
      check_frame(0);
    end

    // frame 1 (same vector): exercises stale pop + re-frame 1->0->1.
    @(negedge clk); z_valid = 1'b1;
    @(negedge clk); z_valid = 1'b0;
    wait_invalid(20000);
    if (slice_valid !== 1'b0) begin
      $display("MISMATCH f1: slice_valid never fell (no re-frame)");
      errs = errs + 1;
    end
    wait_valid(20000);
    if (slice_valid !== 1'b1) begin
      $display("MISMATCH f1: slice_valid never re-rose (timeout)");
      errs = errs + 1;
    end else begin
      #1;
      check_frame(1);
    end

    #20;
    if (errs == 0)
      $display("OUTPROJ_STITCH PASS (frames=2, C=%0d dots exact, requant bytes exact)", C);
    else
      $display("OUTPROJ_STITCH FAIL errs=%0d", errs);
    $finish;
  end

  initial begin
    #500000;
    $display("OUTPROJ_STITCH FAIL timeout");
    $finish;
  end
endmodule
