# L1.7 LM_HEAD (digital, last-token classifier)

Parent I/O: `x = X_29[last]` (576,) s8 -> `z_k = Wlm[k,:]*x`, k=0..31999
-> `yhat = argmax z` (15b token id).
Dtypes: INT8 weights (Q1.7), INT16 acts, INT32 accum, INT16 logits;
host quantizes from HF golden. W_lm/B_lm sharing with the embed table is
ASSUMED tied per the model card (§9 reverify: one shared 18MB bank vs two).

Top ports: `x_last_in: in: 576xW_ACT` (FIFO valid/ready);
`x_valid: in: 1b`; `pred_out: out: 15b` (predicted token id);
`done: out: 1b`.

## Inner blocks

A. LAST_BUF (last-slot select). `last_vec = stream[S-1]`; earlier slots
   drained. Entry arrives int8 → W_ACT (Q8.8) via s8<<8 (PARAMS §2).
   Inner: input double-buffer FIFO (depth 4, 576B entries, ping-pong) +
   slot counter + valid MUX. OSS: OpenTitan `prim_fifo_sync` / Forencich
   FIFO; Sky130 stdcells.
B. WLM_SRAM (`sram_1r1w`, STATIONARY). Holds Wlm rows `[32000x576]` int8
   (18MB; 32000 of 32768 rows used). Row read, no write port during
   inference; host-written once. OSS: OpenRAM `sram1rw` banked.
C. LM_MAC (`mac_array #(8,32)`). `psum[k] += sum_p x[p]*Wlm[k,p]` over
   576/32 = 18 passes per class row; 32000 rows sequenced by the head FSM.
   OPERATION mul/add: digital synthesized ALU. Full-576 vs 32-lane
   time-mux tradeoff: 32-lane pinned (PARAMS §5).
D. ARGMAX tree (`cmp` stages). `pred = argmax_k z_k` (15b id); streaming
   max+index compare over the 32k logit stream. Inner: CMP (subtractor +
   sign) -> IDX_MUX.
E. PRED_FIFO (FIFO, 128 x 15b). Buffers pred ids to the SW testbench; the
   gen-subset compare (hits/total) lives in SW, NOT on chip — no
   scoreboard, no label FIFO, no margin tap (the MARGIN/early-exit path
   died with the ALBERT encoder).

WEIGHT-STATIONARY: Wlm in OpenRAM; only the last-token vector/logits move.
Pinned in PARAMS §2 (INT8 Q1.7 / INT16 / INT32) + §5 (32-lane MAC, 256b/cycle
SRAM, FIFO depths at S≤64).

## Interface integration (09-interface.md)

FINAL-only tap: last-token slice of X_29 post-LOOPBACK into LAST_BUF,
concurrent with nothing (loop is done — `loop_done` gates `x_valid`).
`pred_out` streams to the SW GenEval sink (TESTBENCH).
