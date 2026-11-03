// tb_embed_top_stitch.v — RED/GREEN stitch bench for embed_top + dff.
//
// Oracle: baked checkpoint bytes via weights/bake/tv_embed_ids.hex (8x u15)
// + tv_embed_golden.hex (8x576 s8 bytes, one per line). Independent of RTL.
//
// Run FROM THE REPO ROOT (paths below resolve from there):
//   python3 src/tb/embed_top_stitch/gen_dut_init.py   (once; ~37MB sparse image)
//   iverilog -g2012 -o /tmp/embed_stitch_sim src/components/dff.v \
//     src/components/fifo_sync.v src/components/embed_lut.v \
//     src/components/sram_1r1w.v src/components/seq_fsm.v \
//     src/components/embed_top.v src/tb/embed_top_stitch/tb_embed_top_stitch.v
//   vvp /tmp/embed_stitch_sim
//
// Protocol: push exactly S ids (one u15 id per valid beat on the low slice
// of ids_in, honoring ids_ready), wait x0_valid, compare the full frame.
// Single frame per reset (x0_valid is sticky via seq_fsm DONE).
// DUT64 honors the default S=64 contract (8 tv ids + 56x id0 pad, rows 8..63
// must equal golden row 0). DUT8 re-proves S/H parametricity plus OOR edges
// (ids >= V read zero by LUT construction, any init).
`timescale 1ns / 1ps

module tb_embed_top_stitch;
  reg clk = 1'b0;
  always #5 clk = ~clk;

  // ---------------- dff (async-rst flop) ----------------
  reg        d_rst_n = 1'b0;
  reg  [7:0] d_d = 8'h00;
  wire [7:0] d_q;
  dff #(.W(8)) u_dff (.clk(clk), .rst_n(d_rst_n), .d(d_d), .q(d_q));

  integer derrs = 0;
  integer dgot = 0;

  task dcheck(input [7:0] want);
    begin
      dgot = dgot + 1;
      if (d_q !== want) begin
        $display("DFF MISMATCH: got=%h want=%h", d_q, want);
        derrs = derrs + 1;
      end
    end
  endtask

  // ---------------- DUT64: default S=64 frame ----------------
  reg                 rst64 = 1'b0;
  reg  [64*16-1:0]    ids_in64 = {64*16{1'b0}};
  reg                 ids_valid64 = 1'b0;
  wire                ids_ready64;
  wire [64*576*8-1:0] x0_64;
  wire                x0_valid64;
  embed_top #(.S(64), .H(576), .V(32000)) dut64 (
    .clk(clk), .rst_n(rst64), .ids_in(ids_in64), .ids_valid(ids_valid64),
    .ids_ready(ids_ready64), .x0_out(x0_64), .x0_valid(x0_valid64)
  );

  // ---------------- DUT8: parametric S=8 ----------------
  reg               rst8 = 1'b0;
  reg  [8*16-1:0]   ids_in8 = {8*16{1'b0}};
  reg               ids_valid8 = 1'b0;
  wire              ids_ready8;
  wire [8*576*8-1:0] x0_8;
  wire              x0_valid8;
  embed_top #(.S(8), .H(576), .V(32000)) dut8 (
    .clk(clk), .rst_n(rst8), .ids_in(ids_in8), .ids_valid(ids_valid8),
    .ids_ready(ids_ready8), .x0_out(x0_8), .x0_valid(x0_valid8)
  );

  // ---------------- oracle ----------------
  reg [15:0] tv_ids [0:7];
  reg [7:0]  gold [0:8*576-1];
  integer errs = 0;
  integer got = 0;

  task push64(input [15:0] id);
    integer t;
    begin
      t = 0;
      while (ids_ready64 !== 1'b1 && t < 100000) begin
        @(posedge clk); t = t + 1;
      end
      if (ids_ready64 !== 1'b1) begin
        $display("TIMEOUT ids_ready64");
        errs = errs + 1;
      end
      @(negedge clk);
      ids_in64 = {64*16{1'b0}};
      ids_in64[15:0] = id;
      ids_valid64 = 1'b1;
      @(posedge clk); #1;
      ids_valid64 = 1'b0;
    end
  endtask

  task push8(input [15:0] id);
    integer t;
    begin
      t = 0;
      while (ids_ready8 !== 1'b1 && t < 100000) begin
        @(posedge clk); t = t + 1;
      end
      if (ids_ready8 !== 1'b1) begin
        $display("TIMEOUT ids_ready8");
        errs = errs + 1;
      end
      @(negedge clk);
      ids_in8 = {8*16{1'b0}};
      ids_in8[15:0] = id;
      ids_valid8 = 1'b1;
      @(posedge clk); #1;
      ids_valid8 = 1'b0;
    end
  endtask

  task wait_valid64;
    integer t;
    begin
      t = 0;
      while (x0_valid64 !== 1'b1 && t < 200000) begin
        @(posedge clk); t = t + 1;
      end
      if (x0_valid64 !== 1'b1) begin
        $display("TIMEOUT waiting x0_valid64");
        errs = errs + 1;
      end
    end
  endtask

  task wait_valid8;
    integer t;
    begin
      t = 0;
      while (x0_valid8 !== 1'b1 && t < 60000) begin
        @(posedge clk); t = t + 1;
      end
      if (x0_valid8 !== 1'b1) begin
        $display("TIMEOUT waiting x0_valid8");
        errs = errs + 1;
      end
    end
  endtask

  // Frame-byte compare: DUT64 row r (0..63) vs golden row gr (0..7).
  task check64(input integer r, input integer gr);
    integer b;
    reg [7:0] want;
    begin
      for (b = 0; b < 576; b = b + 1) begin
        want = gold[gr*576+b];
        got = got + 1;
        if (x0_64[(r*576+b)*8 +: 8] !== want) begin
          if (errs < 8)
            $display("MISMATCH64 row=%0d (goldrow=%0d) byte=%0d got=%h want=%h",
                     r, gr, b, x0_64[(r*576+b)*8 +: 8], want);
          errs = errs + 1;
        end
      end
    end
  endtask

  // DUT64 row r must be all-zero (OOR/unprogrammed rows).
  task check64_zero(input integer r);
    integer b;
    begin
      for (b = 0; b < 576; b = b + 1) begin
        got = got + 1;
        if (x0_64[(r*576+b)*8 +: 8] !== 8'h00) begin
          if (errs < 8)
            $display("MISMATCH64-ZERO row=%0d byte=%0d got=%h",
                     r, b, x0_64[(r*576+b)*8 +: 8]);
          errs = errs + 1;
        end
      end
    end
  endtask

  task check8(input integer r, input integer gr);
    integer b;
    reg [7:0] want;
    begin
      for (b = 0; b < 576; b = b + 1) begin
        want = gold[gr*576+b];
        got = got + 1;
        if (x0_8[(r*576+b)*8 +: 8] !== want) begin
          if (errs < 8)
            $display("MISMATCH8 row=%0d (goldrow=%0d) byte=%0d got=%h want=%h",
                     r, gr, b, x0_8[(r*576+b)*8 +: 8], want);
          errs = errs + 1;
        end
      end
    end
  endtask

  task check8_zero(input integer r);
    integer b;
    begin
      for (b = 0; b < 576; b = b + 1) begin
        got = got + 1;
        if (x0_8[(r*576+b)*8 +: 8] !== 8'h00) begin
          if (errs < 8)
            $display("MISMATCH8-ZERO row=%0d byte=%0d got=%h",
                     r, b, x0_8[(r*576+b)*8 +: 8]);
          errs = errs + 1;
        end
      end
    end
  endtask

  task reset64;
    begin
      rst64 = 1'b0;
      ids_valid64 = 1'b0;
      repeat (5) @(posedge clk); #1;
      rst64 = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task reset8;
    begin
      rst8 = 1'b0;
      ids_valid8 = 1'b0;
      repeat (5) @(posedge clk); #1;
      rst8 = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  integer i;

  initial begin
    $readmemh("weights/bake/tv_embed_ids.hex", tv_ids);
    $readmemh("weights/bake/tv_embed_golden.hex", gold);
    #1;
    $display("tv_ids: %0d %0d %0d %0d ... (edges 0 / 31999)",
             tv_ids[0], tv_ids[1], tv_ids[2], tv_ids[3]);

    // ---- 1) dff: reset dominance, Q=D, async clear ----
    d_rst_n = 1'b0; d_d = 8'hA5;
    repeat (3) @(posedge clk); #1;
    dcheck(8'h00);
    d_rst_n = 1'b1; #1;
    @(posedge clk); #1;
    dcheck(8'hA5);
    @(negedge clk);
    d_d = 8'h3C;
    @(posedge clk); #1;
    dcheck(8'h3C);
    @(negedge clk);
    d_d = 8'hFF;
    @(posedge clk); #1;
    dcheck(8'hFF);
    d_rst_n = 1'b0; #1; // async: no clock edge
    dcheck(8'h00);
    d_rst_n = 1'b1;
    repeat (2) @(posedge clk);
    if (derrs == 0)
      $display("DFF PASS (%0d checks)", dgot);
    else
      $display("DFF FAIL derrs=%0d dgot=%0d", derrs, dgot);

    // ---- 2) DUT64 full frame: 8 tv ids + 56x id0 pad ----
    reset64;
    if (ids_ready64 !== 1'b1) begin
      $display("MISMATCH64: ids_ready not asserted after reset");
      errs = errs + 1;
    end
    for (i = 0; i < 8; i = i + 1)
      push64(tv_ids[i]);
    for (i = 0; i < 56; i = i + 1)
      push64(16'd0);
    wait_valid64;
    if (x0_valid64 === 1'b1) begin
      for (i = 0; i < 8; i = i + 1)
        check64(i, i);
      for (i = 8; i < 64; i = i + 1)
        check64(i, 0); // id0 pad rows equal golden row 0
    end

    // ---- 3) DUT8 golden rows (S/H parametricity) ----
    reset8;
    for (i = 0; i < 8; i = i + 1)
      push8(tv_ids[i]);
    wait_valid8;
    if (x0_valid8 === 1'b1) begin
      for (i = 0; i < 8; i = i + 1)
        check8(i, i);
    end

    // ---- 4) DUT8 OOR edges read zero (LUT construction, any init) ----
    reset8;
    push8(16'd32000); push8(16'd32767); push8(16'd0); push8(16'd31999);
    push8(16'd1); push8(16'd2); push8(16'd32001); push8(16'd32767);
    wait_valid8;
    if (x0_valid8 === 1'b1) begin
      check8_zero(0); check8_zero(1);
      check8(2, 0); check8(3, 3); check8(4, 1); check8(5, 2);
      check8_zero(6); check8_zero(7);
    end

    #20;
    if (errs == 0)
      $display("EMBED_TOP_STITCH PASS (%0d checks)", got);
    else
      $display("EMBED_TOP_STITCH FAIL errs=%0d got=%0d", errs, got);
    if (derrs == 0 && errs == 0)
      $display("STITCH_ALL PASS");
    $finish;
  end
endmodule
