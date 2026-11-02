# PARAMS — pinned demo decisions (architecture inputs, not unknowns)

Every value below is a DEMO choice documented for sim, per 09-interface.md
§Demo-parameters ("inputs, not unknowns"). Paper-grounded items cite paper
lines via 09 §Locked; sim-grounded items cite the passing check. Anything
marked SWEEP is a procedure with an acceptance criterion, not a blank cheque.
Reverify list at the bottom; until then these pins are final for greenlight.

## 1. Model config (ALBERT-base)

L=12 layers, hidden H=768, heads=12, d_k=64, FF=3072, vocab=30000,
max positions 512. H=12/d_k=64 closes 03: 768/12=64 by construction;
reverify vs HF `albert-base-v2` config at bring-up (§9). One shared layer in
HW reused 12x loopback (BUILD_MAP, 08-D). Demo S≤64 (default S=32 per 06;
paper cites both 512 positions and ≤128 test lengths — demo picks 64 max and
notes the paper range, no contradiction for a 1-2 tile proxy).
Open-weight vehicle (Meta only, user directive): `facebook/MobileLLM-125M`
(124.6M, 30 layers / 576 hidden / GQA, causal LM, FAIR non-commercial-research
license, ungated, custom `modeling_mobilellm.py` via trust_remote_code,
arxiv 2402.14905) for HF golden + gen-subset eval. Runner-up `facebook/opt-125m`
(125M decoder, license other); large anchor `meta-llama/Llama-3.2-1B` (1.24B,
gated, Llama Community License). Decoder-only delta vs the ALBERT encoder
spec: causal mask, no CLS pooler in the same sense; eval is zero-shot
commonsense/generation vs HF golden, not classification. Sim proxy on the
same parametric RTL:
L=1/H=32/ff=64/S=8/int8 (~12K params, ~70K MACs) — see
DEEP_RESEARCH_tiny-models.md. Proxy dims ride `data_bit_width` + S/H
parameters; full dims need Verilator + MAC array, never iverilog serial.

## 2. Datatypes

- Tile path: token acts int8, accumulators int32 (08-DTYPE; closes 01 proxy
  dtype, 03 fixed-point width at 8b; 4b-equiv stays a SWEEP variant).
- LayerNorm: FXP16 Q8.8, ACC32 Q16.16 guard (05, pinned; sweep for sign-off).
- GELU internal: Q4.12 (06 pinned).
- Attention scale: arith >>3, Q6.10 (03, pinned).
- Pooler/head: INT8 weights Q1.7, INT16 acts, INT32 accum, INT16 h/logits
  (07, pinned); tanh PWL 32-seg (lower end of 07's 32-64; sweep to 64 only
  if gen-subset accuracy misses §9).
- LN eps = 1e-12 to match HF `AlbertLayerNorm` (closes 05; reverify §9).
- Requant shift/bias: SWEEP vs HF golden per layer-block; acceptance = gen-subset within budget (TESTBENCH). Boundary rule (pins 03/05/07 handoffs): tile/loop int8 → island Q8.8 by s8<<8 (exact, no rounding); island Q8.8/ACC → tile int8 by requant (shift+clip, per-use sweep); resid acc → saturate-to-s8 then <<8 (acceptance: gen-subset within the paper's −1.8% budget ref).

## 3. Digital timing (sim-proven values)

sysclk = 100 MHz single-clock; 1 MAC/cycle/PE; 32-lane `mac_array` default
(02/04/06). Chunk factor 256 over K. Proxy cycle budget (L=1/H=32/ff=64/S=8):
~70K MACs → ~6 s serial in iverilog @11.3k cycles/s, sub-second with an 8-wide
array, no VCD (DEEP_RESEARCH_tiny-models.md). Closes the 02/04 throughput items:
- MAC = int8 x int8 → s32 accum, exact, then requant per chunk.
- Requant = `(acc*scale)>>shift + zero`, clipped to int8; absolute scale
  absorbed by per-chunk slope calibration (09-#6, per layer-use tables, L230).
- 768-wide rows split 3x256 chunks, accumulated digitally in accum regfiles.
  Closes 02 remainder item.

## 4. Tile population (paper count: 34, L208 — functional map only)

34 total is paper-text (L208; Fig 2h/i) and stays the functional map.
Implementation here: 4 digital MAC tiles (p0..p3), each time-muxed over
chunks (inProj/outProj/FC1: 3x256; FC2: 12x256). `tile_sel` is 4b
one-hot/phase, `cal_addr.chunk6b` addresses chunk passes (09-#2, 08-D4).
Demo proxy instantiates 1 tile per phase, time-muxed over chunks.
Closes 04 tile-grid and 06 partition items.

## 5. Memory and FIFO

- Stream FIFOs: DEPTH 8 @S≤64 (09-#3, 08-C: `max(8, 512/64)`); DEPTH 16 is
  reserved for S>64 only. ID_FIFO depth 64 (01); E128 skid depth 2-4 (01);
  attn out_fifo depth 4 (03); GELU pipe FIFOs depth 8 (06); CLS input FIFO
  depth S (07); LabelFIFO 128 (07). Closes the 07/08 depth items.
- Pooler MAC: 32-lane time-mux pinned (07 tradeoff closed; full-768 rejected
  on demo area); SRAM read width 256b/cycle (32 lanes × 8b).
- x_bank/resid/wcal sizes per 08-A/B at S=64 (290KB demo); overflow parked
  (BUILD_MAP).

## 6. Clocks

Single-clock demo default: sysclk 100 MHz; chunk passes counted in
sysclk cycles. CDC (2-flop + gray) ONLY at lane and result
FIFOs (09 frame-order note). Closes the 08 clock-split item.

## 7. Pooler placement

FINAL-only for scoring + concurrent per-layer snoop of `X_l[0]`
post-LOOPBACK into the CLS MUX for early exit on MCU margin policy
(paper L116: layer-11 within 0.4%; 09 §What-stays-off-chip). The snoop is
non-intrusive and concurrent with the next layer. Closes 08 pooler item.

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

1. H/d_k/vocab/eps vs HF `albert-base-v2` config + `AlbertLayerNorm`;
   `facebook/MobileLLM-125M` config (30L/576H/GQA) + tokenizer hash.
2. Requant shifts, 4b-equiv and tanh-64seg sweeps vs HF golden, gen-subset
   within −1.8% ref.
3. T_RECAL/alpha from measured drift; nu fit from tile sims.
4. S=64 full-frame run; DEPTH-16 only if S grows past 64.
