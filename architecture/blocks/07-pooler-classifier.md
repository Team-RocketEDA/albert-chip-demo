# L1.7 POOLER_CLASSIFIER_HEAD (digital)

Parent I/O: `x = X12[0]` (768,) -> `pre = Wp*x + b` (768,) -> `h = tanh(pre)` ->
`z_k = Wc[k,:]*h + bc[k]`, k=0..C-1 (C=2, 3 for MNLI) -> `yhat = argmax z`.
Dtypes: INT8 weights (Q1.7), INT16 acts (Q4.12/Q8.8), INT32 accum, INT16
h/logits; host quantizes from HF golden.

Top ports: `tok_stream_in: in: 768xW_ACT` (FIFO valid/ready); `seq_start: in: 1b`;
`label_in: in: 2b`; `cfg_num_classes: in: 2b`; `logits_out: out: 3x16b` (debug);
`pred_out: out: 2b`; `correct/total_count: out: 32u`; `done: out: 1b`.

## Inner blocks

A. CLS-slot MUX (select token 0). `fifo_dout: in: 768xW_ACT`; drop/forward so
   `cls_vec = stream[0]`; rest drained. Inner: input double-buffer FIFO
   (depth S<=64, 96KB @16b / 48KB @8b, ping-pong) + counter + valid MUX.
   OSS: OpenTitan `prim_fifo_sync` / Forencich FIFO; Sky130 stdcells.
B. Pooler engine `h = tanh(Wp x + b)`, Wp 768x768, b 768:
   - weight SRAM: `rd_addr: in: 10b`; `rd_data: out: 768xW_WT` row.
     768*768B = 576KB INT8 (1.15MB @16b); bias 3KB. Stationary, host-written once.
     OSS: OpenRAM `sram1rw` banked 8x 768x96B.
   - MAC array: `pre[i] = sum_j Wp[i,j]*x[j] + b[i]`. MultiplierLane
     (multiplier) -> AdderTree (adder + accumulator regfile).
     OPERATION mul/add: digital synthesized ALU (analog op-amp mapping applies
     only if ported to a PCM tile). OSS: Verilog MAC, cocotb+Verilator; golden:
     HF pooler. Full-768 vs 32/64-lane time-mux tradeoff open.
   - Tanh unit: `h = tanh(pre)` via PWL/LUT+lerp: RangeCompare (comparator) ->
     CoefLUT (SRAM/ROM 32-64 segs) -> LerpMAC (multiplier+adder).
     Analog alt: diff-pair amplifier tanh (not used here).
C. Classifier `z = Wc h + bc` (2-3 rows only): same MAC reuse or dedicated
   3-lane MAC; tiny SRAM 3x768B = 2.3KB + 3x4B bias.
D. Argmax tree: C=2: `pred = (z1>z0)`; C=3: two-stage max.
   Inner: Comparator2 (subtractor+sign) -> PredMUX.
E. Label FIFO + scoreboard: `hit = (pred==label)`; `correct += hit; total += 1`
   (divide left to host SW). Inner: LabelFIFO (FIFO, 128-1024 x 2b) ->
   EqCompare (comparator) -> Counters (adder+reg). Verified vs HF `run_glue.py`.

WEIGHT-STATIONARY: Wp/Wc/b in OpenRAM; only token vectors/results move.
Unresolved: fixed-point widths + tanh PWL segs vs accuracy (needs quant sweep);
MAC parallelism vs SRAM read width; FIFO depths beyond S<=64 assumed.

## Interface integration (09-interface.md)

Early-exit per-layer tap: snoop X_l[0] post-LOOPBACK into CLS MUX, concurrent
with next layer; MCU margin policy (paper L116: layer-11 within 0.4%).
