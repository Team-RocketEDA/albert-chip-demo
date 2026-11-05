// tb_layer_etched_stitch — layer_etched full-path regression (S=1).
// DEFECTS UNDER TEST (red on the stubbed layer):
//   (1) outproj 3-slice concat missing (one C=256 slice, 320 cols dropped);
//   (2) ln1 absent (ffn leg runs on raw x_in);
//   (3) ln2 FXP16 y_out wired to int8 x_out (silent truncation).
// MODEL GRAPH (MobileLLM pre-norm; fidelity probe 2026-11-04 showed the
// old post-norm variant predicted rank-12037/32000 vs golden top-1):
//   x -> ln0(input_ln) -> inproj -> attn -> outproj -> r1=x+a ->
//   ln1(post_attn_ln) -> ffn -> r2=r1+m = x_out (NO third norm).
// Checks (S=1, layer-0 bake, no golden — component goldens R1-R3 cover
// numerics; this pins topology + completion + no-X):
//   (a) y_valid rises (no hang) and x_out is fully driven;
//   (b) ffn consumed exactly ln1's frame (u_ffn.x_reg === u_ln1.yq_mem);
//   (c) ln1 input is the resid sum x_in + o_full (concat order pinned:
//       rows[0:256)=u_p1a, [256:512)=u_p1b, [512:576)=u_p1c);
//   (d) resid2 is the model-graph sum r1 + ffn_out (x_out === sat8(
//       o_res1 + ffn_y)), NOT the old post-ffn ffn_in-based discipline;
//   (e) pre-attention norm present: ln0 input === x_in and inproj ate
//       ln0's frame (u_p0.xbuf_q === u_ln0.yq_mem).
// RUN FROM THE REPO ROOT:
//   iverilog -g2012 -s tb_layer_etched_stitch -o /tmp/layer \
//     src/components/*.v src/tb/layer_etched_stitch/tb_layer_etched_stitch.v \
//     && vvp /tmp/layer
`timescale 1ns / 1ps
module tb_layer_etched_stitch;
  localparam S = 1;
  localparam H = 576;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;

  reg  [S*H*8-1:0] x_in = 0;
  reg              x_valid = 0;
  wire             x_ready;
  wire [S*H*8-1:0] x_out;
  wire             y_valid;

  layer_etched #(
    .S(S),
    .GN1_FILE("weights/bake/layer0_input_layernorm_q88.hex"),
    .GN2_FILE("weights/bake/layer0_post_attention_layernorm_q88.hex")
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .x_in(x_in), .x_valid(x_valid), .x_ready(x_ready),
    .x_out(x_out), .y_valid(y_valid)
  );

  function [7:0] sat8(input integer v);
    begin
      if (v > 127) sat8 = 8'h7f;
      else if (v < -128) sat8 = 8'h80;
      else sat8 = v[7:0];
    end
  endfunction
  function integer s8(input [7:0] b);
    s8 = $signed(b);
  endfunction

  integer i, cyc, errs;

  initial begin
    errs = 0;
    for (i = 0; i < S*H; i = i + 1)
      x_in[i*8 +: 8] = (i * 13 + 7) & 8'hFF;

    rst_n = 0;
    repeat (4) @(posedge clk); #1;
    rst_n = 1;
    @(posedge clk); #1;
    x_valid = 1'b1;
    @(posedge clk); #1;
    x_valid = 1'b0;

    cyc = 0;
    while (y_valid !== 1'b1 && cyc < 8000000) begin
      @(posedge clk); #1;
      cyc = cyc + 1;
    end
    if (y_valid !== 1'b1) begin
      $display("LAYER_STITCH FAIL y_valid never rose after %0d cycles", cyc);
      $finish;
    end
    $display("layer done after %0d cycles", cyc);
    if ($isunknown(x_out)) begin
      $display("LAYER_STITCH FAIL x_out undriven");
      errs = errs + 1;
    end

    // (b) ffn ate ln1's frame, not the raw port.
    for (i = 0; i < H; i = i + 1) begin
      if (dut.u_ffn.x_reg[i] !== dut.u_ln1.yq_mem[i]) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL ffn_in[%0d]=%h want ln1 %h", i,
                   dut.u_ffn.x_reg[i], dut.u_ln1.yq_mem[i]);
        errs = errs + 1;
      end
    end

    // (c) ln1 input = sat(x_in + o_full); concat order pinned.
    for (i = 0; i < H; i = i + 1) begin
      if (dut.u_ln1.x_in[i*8 +: 8] !==
          sat8(s8(x_in[i*8 +: 8]) + s8(dut.o_full[i*8 +: 8]))) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL resid1[%0d]=%h want=%h (x=%h o=%h)", i,
                   dut.u_ln1.x_in[i*8 +: 8],
                   sat8(s8(x_in[i*8 +: 8]) + s8(dut.o_full[i*8 +: 8])),
                   x_in[i*8 +: 8], dut.o_full[i*8 +: 8]);
        errs = errs + 1;
      end
    end
    // Concat order: slice tails land at global rows 255/511/575.
    if (dut.o_full[255*8 +: 8] !== dut.u_p1a.slice_out[(S*256-1)*8 +: 8]) begin
      $display("LAYER_STITCH FAIL concat order at row 255");
      errs = errs + 1;
    end
    if (dut.o_full[511*8 +: 8] !== dut.u_p1b.slice_out[(S*256-1)*8 +: 8]) begin
      $display("LAYER_STITCH FAIL concat order at row 511");
      errs = errs + 1;
    end
    if (dut.o_full[575*8 +: 8] !== dut.u_p1c.slice_out[(S*64-1)*8 +: 8]) begin
      $display("LAYER_STITCH FAIL concat order at row 575");
      errs = errs + 1;
    end

    // (d) resid2 = r1 + ffn_out (model graph, no third norm).
    for (i = 0; i < H; i = i + 1) begin
      if (x_out[i*8 +: 8] !==
          sat8(s8(dut.o_res1[i*8 +: 8]) + s8(dut.ffn_y[i*8 +: 8]))) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL resid2[%0d]=%h want=%h (r1=%h m=%h)", i,
                   x_out[i*8 +: 8],
                   sat8(s8(dut.o_res1[i*8 +: 8]) + s8(dut.ffn_y[i*8 +: 8])),
                   dut.o_res1[i*8 +: 8], dut.ffn_y[i*8 +: 8]);
        errs = errs + 1;
      end
    end

    // (e) pre-attention norm: ln0 ate the rescaled entry xr (which
    // equals x_in under the default identity RS), inproj ate ln0's frame.
    for (i = 0; i < H; i = i + 1) begin
      if (dut.u_ln0.x_in[i*8 +: 8] !== dut.xr[i*8 +: 8]) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL ln0_in[%0d]=%h want xr %h", i,
                   dut.u_ln0.x_in[i*8 +: 8], dut.xr[i*8 +: 8]);
        errs = errs + 1;
      end
    end
    for (i = 0; i < H; i = i + 1) begin
      if (dut.xr[i*8 +: 8] !== x_in[i*8 +: 8]) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL xr[%0d]=%h want x_in %h (default RS)", i,
                   dut.xr[i*8 +: 8], x_in[i*8 +: 8]);
        errs = errs + 1;
      end
    end
    for (i = 0; i < H; i = i + 1) begin
      if (dut.u_p0.xbuf_q[i] !== dut.u_ln0.yq_mem[i]) begin
        if (errs < 8)
          $display("LAYER_STITCH FAIL inproj_in[%0d]=%h want ln0 %h", i,
                   dut.u_p0.xbuf_q[i], dut.u_ln0.yq_mem[i]);
        errs = errs + 1;
      end
    end

    if (errs == 0)
      $display("LAYER_STITCH PASS (S=%0d topology pinned, frame complete)", S);
    else
      $display("LAYER_STITCH FAIL errs=%0d", errs);
    $finish;
  end

  initial begin
    #200000000;
    $display("LAYER_STITCH FAIL timeout");
    $finish;
  end
endmodule
