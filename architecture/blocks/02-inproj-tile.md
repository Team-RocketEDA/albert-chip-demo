# L1.2 INPROJ_TILE_ARRAY (digital MAC tile, weight-stationary)

Parent I/O: `Xl[Sx768]` int8 -> `Y[Sx2304]` int8. Math: `Y = Xl*W^T`,
W:[2304x768] pinned in SRAM, never moves. One tile time-muxes over 768-col
input in chunks of C=256 (3 passes); full inProj = Q/K/V thirds separable
per OLP lane for ATTN handoff. Demo proxy S<=64.

Top ports: `tok_in: in: Sx768 int8` (chunked rows); `y_out: out: Sx2304
int8`; `cfg_scale/cfg_zero: in: 16b per chunk`; clk/rst/valid-ready.
Weights live ONLY in `w_sram` (stationary); tokens stream through FIFOs.

## Inner blocks (per tile, all §00-E RTL)

1. input_vector_fifo (`fifo_sync`). `in_tok: in: 768x8b`; `out_chunk: out:
   256x8b`. Double buffer, 64-entry ring in SRAM.
2. w_sram_bank (`sram_1r1w`, STATIONARY). Holds W slice `[2304x768]` int8
   (1.7MB full; proxy slices smaller). Wide row read, no write port during
   inference; host-loaded once.
3. mac_array (`mac_array #(8,32)`). `avec,bvec: in: 32x8b` -> `psum: out:
   32b`. `psum_out[j] += sum_p a[p]*b[p]` per cycle; 32 MACs/cycle;
   chunk loop over K=768 in 24 passes of 32.
4. accum_regfile (`regfile_dp`). 2304x s32 psums per row (9KB), cleared per
   token row via FSM.
5. bias_add (`adder`). `biased[j] = acc[j]+b[j]`; bias 2304x s32 ROM bank.
6. requant_clip (`requant` + `cmp`). `y = clip_int8((acc*scale)>>shift +
   zero)`; per-chunk scale/zero from coeff SRAM (12 layer-use sets resident,
   selected by `cal_addr.layer4b`).
7. out_fifo (`fifo_sync`). Packs Q/K/V thirds; streams 512b words to ATTN.

## Storage

W: `w_sram_bank` only (stationary). Tokens: input double-buffer SRAM FIFO +
output bank. Coeffs: scale/zero regfile per layer-use. Golden: HF MobileLLM qkv-proj slice; sim: iverilog tb driving `mac_array`
+ requant vs numpy. Pinned in PARAMS §3 (sysclk 100MHz, 1 MAC/cycle/PE, 32-lane
default) + §2 (int8/s32; requant shift/scale per-use sweep).

## Interface integration (09-interface.md)

5-lane OLP drain (p0: olp0-4); QKV thirds separable per lane for direct
ATTN_WAIT handoff. Chunk loop + requant per interface §4-6.
