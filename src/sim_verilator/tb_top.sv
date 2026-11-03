// tb_top.sv — Verilator smoke top for the FULL model (structural today).
//
// This instantiates mobilellm_top with the shipped MobileLLM-125M geometry
// (S=64/H=576/V=32000) so the whole tree elaborates under Verilator and
// you get a real waves_top.fst in Surfer. EXPECT X OUTPUTS: the hierarchy
// above the leaves is still wiring-only (ports unconnected by design, see
// the STRUCTURAL ONLY headers), so pred_out/done cannot be meaningful
// until the stitching lands. This bench proves the flow, not the model.
`timescale 1ns / 1ps
module tb_top (
  input  wire            clk,
  input  wire            rst_n,
  input  wire            start,
  input  wire [64*16-1:0] ids_in,
  input  wire            ids_valid,
  output wire [14:0]     pred_out,
  output wire            done
);
  mobilellm_top #(.S(64), .H(576), .V(32000)) u_dut (
    .clk(clk), .rst_n(rst_n), .start(start),
    .ids_in(ids_in), .ids_valid(ids_valid),
    .pred_out(pred_out), .done(done)
  );
endmodule
