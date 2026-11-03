// tb_top.sv — Verilator top for the FULL model (wired since stitching).
//
// This instantiates mobilellm_top with the shipped MobileLLM-125M geometry
// (S=64/H=576/V=32000): EMBED -> LOOP30 -> HEAD. The C++ driver
// (tb_top.cpp) runs the loop_top Part B protocol: 64 baked ids in,
// X_30 loopback check, subset-logit oracle, pred_out/done out.
// Waves land in waves_top.fst for Surfer.
`timescale 1ns / 1ps
module tb_top (
  input  wire            clk,
  input  wire            rst_n,
  input  wire            start,
  input  wire [64*16-1:0] ids_in,
  input  wire            ids_valid,
  output wire [14:0]     pred_out,
  output wire            done,
  // Hierarchical taps (sim-owned; mirror the loop_top stitch TB's
  // dut_top.u_embed/u_loop probes). Exporting them here as wrapper
  // outputs keeps Verilator from deleting the cones as unused.
  output wire            tap_ids_ready,
  output wire            tap_x0_valid,
  output wire [64*576*8-1:0] tap_x0,
  output wire            tap_layer_done,
  output wire [64*576*8-1:0] tap_x30,
  // Loop protocol taps (09-interface phase/stall checks at full dims).
  output wire [4:0]      tap_layer_idx,
  output wire [3:0]      tap_tile_sel,
  output wire [5:0]      tap_ilp,
  output wire [5:0]      tap_olp,
  output wire            tap_theta_req
);
  mobilellm_top #(.S(64), .H(576), .V(32000)) u_dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .ids_in(ids_in), .ids_valid(ids_valid),
    .pred_out(pred_out), .done(done)
  );
  assign tap_ids_ready  = u_dut.u_embed.ids_ready;
  assign tap_x0_valid   = u_dut.u_embed.x0_valid;
  assign tap_x0         = u_dut.u_embed.x0_out;
  assign tap_layer_done = u_dut.u_loop.layer_done;
  assign tap_x30        = u_dut.u_loop.x_out;
  assign tap_layer_idx  = u_dut.u_loop.layer_idx;
  assign tap_tile_sel   = u_dut.u_loop.tile_sel;
  assign tap_ilp        = u_dut.u_loop.fifo_lane_en_ilp;
  assign tap_olp        = u_dut.u_loop.fifo_lane_en_olp;
  assign tap_theta_req  = u_dut.u_loop.theta_req;
endmodule
