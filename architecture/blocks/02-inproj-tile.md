# L1.2 INPROJ_TILE_ARRAY (digital MAC tile, weight-stationary)

Parent I/O: `Xl[Sx576]` int8 -> `Y[Sx960]` int8 (packed Q[576]+K[192]+V[192]).
Math: `Y = Xl*W^T`, W:[960x576] pinned in SRAM, never moves. One tile
time-muxes over 576-col input in C=256 chunks (2x256 + 64-tail); K/V rows
are the same pass, sliced per OLP lane for ATTN handoff. Demo proxy S<=64.

Top ports: `tok_in: in: Sx576 int8` (chunked rows); `y_out: out: Sx960
int8` (packed QKV); `cfg_scale/cfg_zero: in: 16b per chunk`;
clk/rst/valid-ready. Weights live ONLY in `w_sram` (stationary); tokens
stream through FIFOs.

## Inner blocks (per tile, all §00-E RTL)

1. input_vector_fifo (`fifo_sync`). `in_tok: in: 4608x8b` (one 576B row);
   `out_chunk: out: 2048x8b` (C=256 slice). Double buffer, 64-entry ring
   in SRAM.
2. w_sram_bank (`sram_1r1w`, STATIONARY). Holds W slice `[960x576]` int8.
   Wide row read, no write port during inference; host-loaded once.
3. mac_array (`mac_array #(8,32)`). `avec,bvec: in: 32x8b` -> `psum: out:
   32b`. `psum_out[j] += sum_p a[p]*b[p]` per cycle; 32 MACs/cycle;
   chunk loop over K=576 in 18 passes of 32.
4. accum_regfile (`regfile_dp`). 960x s32 psums per row, cleared per token
   row via FSM.
5. bias_add (`adder`). `biased[j] = acc[j]+b[j]`; int8 model has no bias —
   bank present, zero-filled (MobileLLM dense mats ship no bias).
6. requant_clip (`requant` + `cmp`). `y = clip_int8((acc*scale)>>shift +
   zero)`; per-chunk scale/zero from coeff SRAM (30 layer-use sets
   resident, selected by `cal_addr.layer5b`).
7. out_fifo (`fifo_sync`). Packs Q/K/V thirds; streams 4096b words to ATTN.

## Storage

W: `w_sram_bank` only (stationary). Tokens: input double-buffer SRAM FIFO +
output bank. Coeffs: scale/zero regfile per layer-use. Golden: HF MobileLLM
qkv-proj slice; sim: iverilog tb driving `mac_array`
+ requant vs numpy. Pinned in PARAMS §3 (sysclk 100MHz, 1 MAC/cycle/PE,
32-lane default) + §2 (int8/s32; requant shift/scale per-use sweep).

## Interface integration (09-interface.md)

5-lane OLP drain (p0: olp0-4); Q/K/V thirds separable per lane for direct
ATTN_WAIT handoff. Chunk loop + requant per interface §4-6.
