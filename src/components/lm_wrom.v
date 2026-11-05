// lm_wrom — LM-head weight ROM (via-ROM precursor; read-only + const).
// Contract: W_lm rows (s8), one full row per cycle: addr (row index) in,
// dout (H bytes flattened) out. Sim preloads WLM_FILE via $readmemh
// (skipped under NETLIST_CLEAN so the render shows clean blocks).
// Synth MUST blackbox this module (blackbox_models); the etched via-ROM
// implements the same interface later. NOT a macro: no LEF, no SRAM.
`ifndef LM_WLM_PATH
`define LM_WLM_PATH "src/tb/lm_head_stitch/wlm_subset16.hex"
`endif
// LibreLane blackbox: under __librelane__ (defined by its synth/header
// steps only) this module keeps ports but elaborates no body — the ROM is
// etched via-ROM, never mapped to logic. Sim flows never define it.
`ifdef __librelane__
(* blackbox *)
`endif
module lm_wrom #(
  parameter H = 576,
  parameter VROWS = 16,
  parameter WLM_FILE = `LM_WLM_PATH
)(
  input  wire [((VROWS > 1) ? $clog2(VROWS) : 1)-1:0] addr,
  output wire [H*8-1:0] dout
);
  reg [7:0] mem [0:VROWS*H-1];
`ifndef NETLIST_CLEAN
  initial $readmemh(WLM_FILE, mem);
`endif
  integer p;
  reg [H*8-1:0] row_r;
  always @* begin
    for (p = 0; p < H; p = p + 1)
      row_r[p*8 +: 8] = mem[addr*H+p];
  end
  assign dout = row_r;
endmodule
