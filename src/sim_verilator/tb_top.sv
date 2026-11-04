// tb_top.sv — Verilator top for the FULL etched model.
//
// mobilellm_top at the shipped MobileLLM-125M geometry (S=64/H=576):
// EMBED -> 30-deep ETCHED STACK (decoder_etched_stack, layer0 tables) ->
// HEAD. The C++ driver (tb_top.cpp) pushes 64 prompt ids, waits the
// stack frame, then checks the last-row subset-logit oracle against
// pred_out (done exactly once). Loop-protocol taps are gone with the
// time-muxed loop: the stack is feedforward, so there is no tile_sel
// cycling, no theta_req, no stall lanes to check here.
// Waves land in waves_top.fst for Surfer (NOTRACE=1 skips tracing).
`timescale 1ns / 1ps
module tb_top (
  input  wire            clk,
  input  wire            rst_n,
  input  wire            start,
  input  wire [64*16-1:0] ids_in,
  input  wire            ids_valid,
  output wire [14:0]     pred_out,
  output wire            done,
  // Hierarchical taps (sim-owned). Exporting them as wrapper outputs
  // keeps Verilator from deleting the cones as unused.
  output wire            tap_ids_ready,
  output wire            tap_x0_valid,
  output wire [64*576*8-1:0] tap_x0,
  output wire            tap_layer_done,
  output wire [64*576*8-1:0] tap_x30
);
  mobilellm_top #(.S(64), .H(576), .V(32000)) u_dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .ids_in(ids_in), .ids_valid(ids_valid),
    .pred_out(pred_out), .done(done)
  );
  assign tap_ids_ready  = u_dut.u_embed.ids_ready;
  assign tap_x0_valid   = u_dut.u_embed.x0_valid;
  assign tap_x0         = u_dut.u_embed.x0_out;
  assign tap_layer_done = u_dut.u_stack.y_valid;
  // Head input frame (post-final-norm), not the raw stack output: the
  // oracle recomputes argmax over exactly what the head consumed.
  assign tap_x30        = u_dut.u_normf.yq_out;
endmodule
