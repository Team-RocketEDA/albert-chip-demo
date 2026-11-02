# PARAMS — pinned demo decisions (architecture inputs, not unknowns)

Every value below is a DEMO choice documented for sim, per 09-interface.md
§Demo-parameters ("inputs, not unknowns"). Paper-grounded items cite paper
lines via 09 §Locked; sim-grounded items cite the passing check. Anything
marked SWEEP is a procedure with an acceptance criterion, not a blank cheque.
Reverify list at the bottom; until then these pins are final for greenlight.

## 1. Model config (MobileLLM-125M decoder)

L=30 layers, hidden H=576, Q heads 9 / KV heads 3 (GQA kv3, head_dim 64),
FF=1536 (SwiGLU), vocab=32000, `rms_norm_eps` 1e-5, `rope_theta` 10000.0,
`max_position_embeddings` 2048 (all per the opened training config +
paper Table 9; reverify vs HF `facebook/MobileLLM-125M` at bring-up, §9).
One layer-block set in HW reused 30x loopback (BUILD_MAP, 08-D). Demo S≤64
(default S=32 per 06).
Vehicle (Meta only, user directive): `facebook/MobileLLM-125M` (124.6M,
causal LM, FAIR non-commercial-research license, ungated, custom
`modeling_mobilellm.py` via trust_remote_code, arxiv 2402.1495) for HF
golden + gen-subset eval. Runner-up `facebook/opt-125m` (125M decoder,
license other); large anchor `meta-llama/Llama-3.2-1B` (1.24B, gated, Llama
Community License). Decoder spec: causal mask, KV cache, RoPE, RMSNorm,
SwiGLU, 32k embeddings (tied assumed — card/training-config tie
discrepancy is a §9 reverify item, decides the W_lm bank count),
last-token LM head; eval is zero-shot commonsense/generation vs HF golden,
not classification. Sim proxy on the same parametric RTL:
L=1/H=32/ff=64/S=8/int8 (~12K params, ~70K MACs) — see
DEEP_RESEARCH_tiny-models.md. Proxy dims ride `data_bit_width` + S/H
parameters; full dims need Verilator + MAC array, never iverilog serial.

## 2. Datatypes

- Tile path: token acts int8, accumulators int32 (08-DTYPE; closes 01 proxy
  dtype, 03 fixed-point width at 8b; 4b-equiv stays a SWEEP variant).
- RMSNorm: FXP16 Q8.8, ACC32 Q16.16 guard (05, pinned; sweep for sign-off).
- SiLU internal: Q4.12 (06 pinned).
- Attention scale: arith >>3, Q6.10 (03, pinned).
- LM head: INT8 weights Q1.7, INT16 acts, INT32 accum, INT16 logits
  (07, pinned).
- RMS eps = 1e-5 to match HF `rms_norm_eps` (closes 05; reverify §9).
- Requant shift/bias: SWEEP vs HF golden per layer-block; acceptance = gen-subset within budget (TESTBENCH). Boundary rule (pins 03/05/07 handoffs): tile/loop int8 → island Q8.8 by s8<<8 (exact, no rounding); island Q8.8/ACC → tile int8 by requant (shift+clip, per-use sweep); resid acc → saturate-to-s8 then <<8 (acceptance: gen-subset within the paper's −1.8% budget ref).

## 3. Digital timing (sim-proven values)

sysclk = 100 MHz single-clock; 1 MAC/cycle/PE; 32-lane `mac_array` default
(02/04/06). Chunk factor 256 over K. Proxy cycle budget (L=1/H=32/ff=64/S=8):
~70K MACs → ~6 s serial in iverilog @11.3k cycles/s, sub-second with an 8-wide
array, no VCD (DEEP_RESEARCH_tiny-models.md). Closes the 02/04 throughput items:
- MAC = int8 x int8 → s32 accum, exact, then requant per chunk.
- Requant = `(acc*scale)>>shift + zero`, clipped to int8; absolute scale
  absorbed by per-chunk slope calibration (09-#6, per layer-use tables, L230).
- H-wide rows split into 256-wide chunks (H=576: 2x256 + 64-tail; K/V 192:
  single pass; SwiGLU mats 1536: 6x256), accumulated digitally in accum
  regfiles. Closes 02 remainder item.

## 4. Tile population (paper count: 34, L208 — functional map only)

34 total is paper-text (L208; Fig 2h/i) and stays the functional map.
Implementation here: 4 digital MAC tiles (p0..p3), each time-muxed over
chunks (Q/outProj: 2x256 + 64-tail; K/V: single 192 pass; gate/up/down:
6x256). `tile_sel` is 4b
one-hot/phase, `cal_addr.chunk6b` addresses chunk passes (09-#2, 08-D4).
Demo proxy instantiates 1 tile per phase, time-muxed over chunks.
Closes 04 tile-grid and 06 partition items.

## 5. Memory and FIFO

- Stream FIFOs: DEPTH 8 @S≤64 (09-#3, 08-C: `max(8, 512/64)`); DEPTH 16 is
  reserved for S>64 only. ID_FIFO depth 64 (01); XBUF 576B skid depth 2
  (01); attn out_fifo depth 4 (03); SiLU pipe FIFO depth 8 (06);
  LAST_BUF 576B depth 4 + PRED_FIFO 15b depth 128 (07). Closes 07/08
  depth items.
- LM-head MAC: 32-lane time-mux pinned (07 tradeoff closed; full-576
  rejected on demo area); SRAM read width 256b/cycle (32 lanes × 8b).
- x_bank/resid sizes per 08-A at S=64 (216KB demo); wcal 720KB per 08-B;
  overflow parked (BUILD_MAP).

## 6. Clocks

Single-clock demo default: sysclk 100 MHz; chunk passes counted in
sysclk cycles. CDC (2-flop + gray) ONLY at lane and result
FIFOs (09 frame-order note). Closes the 08 clock-split item.

## 7. LM-head placement

FINAL-only: last-token slice of X_29 post-LOOPBACK into LAST_BUF;
`logits = x_last*W_lm^T` over 32k classes, argmax -> pred id (07). No CLS
slot, no tanh, no scoreboard: the SW testbench compares the gen-subset vs
HF golden (TESTBENCH). W_lm/embed-table sharing is ASSUMED tied per the
model card and must be reverified vs the training config at bring-up (tie
discrepancy, §9). Closes 08 head item.

## 8. Requant rotation (no drift in digital)

Digital has no G-drift: T_RECAL is the coeff-set rotation interval and the
check is a CRC verify per layer-use, not a compensation loop (08-E).
Sweep T_RECAL vs frame budget at bring-up; acceptance = zero CRC mismatches
over the gen-subset run. Closes 08 drift/T_RECAL item.
Phase map p0..p3 = INPROJ/OUTPROJ/FC1/FC2 is LOCKED (09 §Per-phase routing,
08-D2; closes 08 sign-off item — no further sign-off needed).
wcal holds all 30 layer-uses resident: 720KB (inProj QKV 3.75 + outProj 2.25
+ SwiGLU gate/up/down 18 KB per use; S-independent) + ~0.2KB spare;
`cal_addr` carries `layer5b` (23b total) to select the use.

## 9. Reverification (bring-up checklist, not architecture gaps)

1. H/heads/vocab/eps/RoPE vs HF `facebook/MobileLLM-125M` config (30L/576H/
   9Q+3KV/1536/32000, `rms_norm_eps` 1e-5, `rope_theta` 10000.0,
   `max_position_embeddings` 2048) + tokenizer hash; tie_word_embeddings
   discrepancy (card says shared, training config says false) decides the
   W_lm bank count (one shared 18MB vs two).
2. Requant shifts and 4b-equiv sweeps vs HF golden, gen-subset
   within −1.8% ref.
3. T_RECAL from frame budget (CRC rotation, no drift — 08-E); RoPE
   sin/cos table width vs gen-subset from tile sims.
4. S=64 full-frame run; DEPTH-16 only if S grows past 64.
