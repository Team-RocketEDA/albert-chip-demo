# L1.6 FFN_TILE (digital: FC1 -> SRAM -> GELU -> FC2)

Parent math: `X[Sx768] -> H = GELU(X*W1^T) -> Y = H*W2^T` [Sx768];
W1:[3072x768], W2:[768x3072], int8-quant, pinned in SRAM, never move.
Top ports: `X_in: in: S*768 int8` rows; `Y_out: out: S*768 int8`;
clk/rst_n/start/done.

## Inner blocks (all §00-E RTL)

1. fc1_mtile (FC1 digital MAC tile). `I_part = A_slice * W1_slice^T` per
   256-wide in-chunk; full row `H_pre[j] = sum` over 3 chunks (768 = 3x256),
   accumulated in `fc1_accum` regfile.
   Children (primitives only): fc1_in_fifo (`fifo_sync` 2x512B double buffer);
   fc1_wsram (`sram_1r1w` W1 slice, stationary); fc1_mac
   (`mac_array #(8,32)`); fc1_shiftacc (`shifter`+`adder`+regfile: 3-chunk
   accumulate + dequant rescale).
2. h_sram_buffer (H pre-GELU store). `H_pre[Sx3072]` latch, double-buffered
   ping/pong (FC1 writes A while GELU reads B). 64*3072B = 192KB/bank demo
   (96KB @S=32). OpenRAM Sky130 macros (32KB banks) + regfile wrapper.
3. gelu_dpipe (digital GELU tanh-approx pipeline).
   `GELU(x) = 0.5x(1+tanh(c0(x+0.044715x^3)))`, c0 ~ 0.79788456.
   Children: gelu_in_fifo (`fifo_sync` depth 8); gelu_mac1
   (`mult`+`adder`+regfile: cubic `u`, then `v = c0*u`); gelu_tanh_lut
   (SRAM/ROM: tanh(v) 1024x16b LUT + linear interp via 1 `mult` + 1 `adder`;
   clamp |v|>4 -> +/-1); gelu_mac2 (`mult`+`adder`: `y = 0.5*x*(1+t)`);
   gelu_out_fifo (`fifo_sync` depth 8). FXP Q4.12 (pinned, PARAMS §2).
4. fc2_mtile (FC2 digital MAC tile). `Y[i] = sum` over ceil(3072/256)=12
   chunk passes of `H_chunk * W2_chunk^T`. Same leaf set as FC1 +
   fc2_shiftacc (12-chunk accumulation + dequant rescale).
5. tile_ctrl (digital sequencer). `seq_fsm` leaf: counter+comparator FSM +
   MUX selects (chunk/col/row counters, ping-pong bank MUX, lane MUX).
   Schedule per token row: 3x FC1 chunks -> SRAM flip -> GELU stream ->
   12x FC2 chunks -> Y FIFO.

## Storage

H buffer 192KB + W1 2.25MB + W2 2.25MB (full; proxy slices smaller) in OpenRAM
Sky130; FIFOs `fifo_sync` depth 8; tanh LUT 2KB ROM. Golden: HF MobileLLM
FC1 Linear + SwiGLU/GELU; sim: iverilog `mac_array` tb + GELU pipe tb vs numpy.
Pinned in PARAMS §4 (chunk factor 256) + §2 (GELU Q4.12, tanh LUT 1024x16b).
Demo: S=32 default; FC cols in 256-wide groups.

## Interface integration (09-interface.md)

FC1 = chunk-accumulate-then-requant (one requant per output, cleanest);
FC2 = 12-chunk digital accum + per-chunk coeff count. p2 owns the whole lane
fabric one wave; p3 drains row-tiles separately.
