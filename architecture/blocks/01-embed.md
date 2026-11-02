# L1.1 EMBED_TOP (digital, weight-stationary)

Parent I/O: `ids[S]` u15 (vocab 30000, S<=64 demo) -> `X0[Sx768]` s8.
Math: `E = Wemb[ids]` (Sx128 s8); `X0 = requant(E @ Wp + b)`, Wp 128x768 s8.

## Inner blocks

1. ID_FIFO (FIFO, stop). `push: in: u15+valid/ready`; `pop: out: u15+valid/ready`.
   Queue, depth 64 (~120B). OSS: lowRISC `prim_fifo_sync`.
2. EMB_LUT_BANK (SRAM, stop). `addr: in: u15`; `row: out: 128x s8`.
   `e[k]=Wemb[addr][k]`. 30000x128 s8 = 3.84MB (8x 480KB banks);
   pruned 5k vocab -> 625KB. OSS: OpenRAM/Sky130 macros + decode MUX.
3. E128_FIFO (FIFO, stop). 1024b in/out, depth 2-4 (~512B skid).
4. PROJ_W_BANK (SRAM, stop, STATIONARY). `row_addr: in: u7`; `rdata: out: 768x s8`.
   128x768 s8 = 96KB, wide-read, no write port during inference.
5. DOT128_MAC (OPERATION: multiplier+adder tree). `e_vec: in: 128x s8`;
   `w_row: in: 768x s8`; `psum: inout: 768x s32`.
   `psum_out[j] += e[k]*w[k][j]`, k streamed 0..127.
   Circuit: digital fixed-point multiplier + carry-save adder lane
   (analog alt: Gilbert mixer + op-amp summer, not used).
6. ACCUM_RF (regfile, stop). 768x s32 psums (3KB), cleared per token.
7. BIAS_ADD (OPERATION: adder). `biased[j]=acc[j]+b[j]`. Bias 768x s32 ROM bank.
8. REQUANT_CLIP (OPERATION: shifter+comparator). `x0=clip_sat(round(biased>>shift))`.
9. X0_DBUF (SRAM double buffer, stop). 2x64x768 s8 = 96KB ping-pong.
10. CTRL_FSM (counter+comparator+MUX, stop). Per token: pop id -> LUT read ->
    128 k-step MAC loop -> bias+requant -> write DBUF row; swap buffers per S.

## Storage / OSS

Tokens only in ID_FIFO/X0_DBUF. Weights (Wemb, Wp, bias) stationary in SRAM.
Golden: HF `AlbertTokenizer` + `modeling_albert` embedding lookup + matmul.
Pinned in PARAMS §1 (full vocab 30000, pruned-5k option) + §2 (int8/s32;
requant shift/bias via sweep vs HF golden).
Scope: single-sentence bring-up only — no segment/position embedding banks
yet. Sentence-pair tasks add a SegEmb SRAM bank (`E += Seg[seg]`) + driver
seg column at step 3; segment ids ride the same ID_FIFO valid/ready path.

Interface tag: SW/digital-only; re-enters via ILP/OLP valid/ready (09 §2).
