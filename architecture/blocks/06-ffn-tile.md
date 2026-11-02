# L1.6 FFN_TILE (digital: GATE/UP -> SiLU -> DOWN, SwiGLU)

Parent math: `X[Sx576] -> G = X*Wg^T, U = X*Wu^T -> H = silu(G)*U -> Y = H*Wd^T`
[Sx576]; Wg/Wu:[1536x576], Wd:[576x1536], int8-quant, pinned in SRAM, never
move. Top ports: `X_in: in: S*576 int8` rows; `Y_out: out: S*576 int8`;
clk/rst_n/start/done.

## Inner blocks (all §00-E RTL)

1. gateup_mtile (GATE+UP digital MAC tiles). `G_part/U_part` per 256-wide
   in-chunk; full rows `G[j]/U[j]` accumulate over ceil(576/256) = 3 chunk
   passes (2x256 + 64-tail) in gate/up accum regfiles.
   Children (primitives only): gateup_in_fifo (`fifo_sync` 2x576B double
   buffer); gate_wsram/up_wsram (`sram_1r1w` slices, stationary);
   gate_mac/up_mac (`mac_array #(8,32)`); gateup_shiftacc
   (`shifter`+`adder`+regfile: 3-chunk accumulate + dequant rescale).
2. silu_pipe (digital SiLU + elementwise mul).
   `H = silu(G)*U`, silu exact in SW golden.
   Children: silu_in_fifo (`fifo_sync` depth 8); silu_lut (SRAM/ROM:
   silu(v) 1024x16b LUT + linear interp via 1 `mult` + 1 `adder`);
   gate_mul (`mult`: `h = silu_g*u`); silu_out_fifo (`fifo_sync`
   depth 8). FXP Q4.12 (pinned, PARAMS §2).
3. down_mtile (DOWN digital MAC tile). `Y[i] = sum` over ceil(1536/256)=6
   chunk passes of `H_chunk * Wd_chunk^T`. Same leaf set as gate/up +
   down_shiftacc (6-chunk accumulation + dequant rescale).
4. tile_ctrl (digital sequencer). `seq_fsm` leaf: counter+comparator FSM +
   MUX selects (chunk/col/row counters, ping-pong bank MUX, lane MUX).
   Schedule per token row: gate/up chunks -> SiLU stream ->
   6x DOWN chunks -> Y FIFO.

## Storage

H buffer 96KB + Wg/Wu 864KB each + Wd 864KB (full; proxy slices smaller)
in OpenRAM Sky130; FIFOs `fifo_sync` depth 8; SiLU LUT 2KB ROM. Golden:
HF MobileLLM MLP (gate/up/down) + SwiGLU; sim: iverilog `mac_array` tb +
SiLU pipe tb vs numpy. Pinned in PARAMS §4 (chunk factor 256) + §2
(SiLU Q4.12, LUT 1024x16b). Demo: S=32 default; FF cols in 256-wide
groups (6x256 exact).

## Interface integration (09-interface.md)

Gate/up = chunk-accumulate-then-requant (one requant per output, cleanest);
DOWN = 6-chunk digital accum + per-chunk coeff count. p2 owns the whole
lane fabric one wave; p3 drains row-tiles separately.
