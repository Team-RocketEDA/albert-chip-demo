// seq_fsm — §00-E leaf, STRUCTURAL ONLY (ports, no logic).
// Contract: blocks/00-primitive-library.md §E + ADR-0001 (hardwired phase/IRQ
// sequencer; NO RV32; firmware/mcu_fw.c is the golden C model) + doc 08-D
// (layer_counter, phase_decoder: tile_sel/fifo_lane_en/cal_addr).
// Decoder modes: prefill = full-sequence pass, decode = one token + KV cache.
module seq_fsm (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        irq_row_done,
  input  wire        irq_tile_done,
  input  wire        irq_frame_done,
  input  wire        prefill,      // 1 = prefill pass, 0 = decode token
  output wire [3:0]  phase_sel,    // one-hot-per-phase (tile_sel)
  output wire [4:0]  layer_idx,    // 08-D1 layer counter l=0..29
  output wire [22:0] cal_addr,     // 08-D4 use select {layer5,block,phase,chunk,col}
  output wire [5:0]  fifo_lane_en_ilp,
  output wire [5:0]  fifo_lane_en_olp,
  output wire        fifo_rd,
  output wire        layer_done
);
endmodule
