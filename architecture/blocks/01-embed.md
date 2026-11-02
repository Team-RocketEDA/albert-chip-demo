# L1.1 EMBED_TOP (digital, weight-stationary)

Parent I/O: `ids[S]` u15 (vocab 32000, S<=64 demo) -> `X0[Sx576]` s8.
Math: `X0 = E576[ids]` (Sx576 s8, direct tied-embedding lookup, no
factorized projection). Tied with the LM-head table assumed (card says
shared; training config says `tie_word_embeddings: false` — §9 reverify
decides one shared bank vs two).

## Inner blocks

1. ID_FIFO (FIFO, stop). `push: in: u15+valid/ready`; `pop: out: u15+valid/ready`.
   Queue, depth 64 (~120B). OSS: lowRISC `prim_fifo_sync`.
2. EMB_LUT_BANK (SRAM, stop). `token_id: in: u15`; `vec: out: 576x s8`.
   `e[k]=E576[ids][k]`. 32000x576 s8 = 18MB (banked; proxy slices smaller).
   OSS: OpenRAM/Sky130 macros + decode MUX.
3. XBUF (FIFO skid, stop). 4608b in/out (one 576B row), depth 2.
4. X0_DBUF (SRAM double buffer, stop). 2 banks x S*H s8 = 2x36KB @S=64
   ping-pong (second bank at implementation).
5. CTRL_FSM (`seq_fsm` leaf). Per token: pop id -> LUT read -> write DBUF
   row; frame done -> `x0_valid`. Phase/layer/cal fields fan out unused
   here.

## Storage / OSS

Tokens only in ID_FIFO/XBUF/X0_DBUF. Weights (E576 table) stationary in
SRAM — no Wp/bias banks, no DOT128 MAC: the factorized 128-dim projection
path is deleted (tied E=576 needs none). Golden: HF MobileLLM
`modeling_mobilellm` embedding lookup. Pinned in PARAMS §1 (vocab 32000,
tie reverify) + §2 (int8 rows, no requant on this path).
Scope: single-sentence bring-up only — no segment-id banks; sentence-pair
tasks ride the same ID_FIFO valid/ready path with packed ids at step 3
(see 01 scope note in TESTBENCH).

Interface tag: SW/digital-only; re-enters via ILP/OLP valid/ready (09 §2).
