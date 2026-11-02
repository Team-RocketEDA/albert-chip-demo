# 09 — Digital I/O + phase contract (all ports bit-vectors + valid/ready)

Paper grounding: Fig2 caption L58-60 (4 phases, 6 ILP west-in, 6 OLP SN-out,
512-elem vectors, 2x256 mesh concat); L70-72+L88 (throughput constraint,
non-pipelined, no-crossing, 79.4%, 2 keep-outs); L208 (34 tiles,
1.05M/tile, cap-share doubling); L72 (512x512 tiles @4PCM/w); L152-168 (FC2 6-tile worst, FC1 analog-pair sum);
L44/L206 (only 4 FC blocks on-chip); L172/L256 (frame anatomy); L116
(early-exit 0.4%); L230-248 (columnwise scale/offset, drift+recal).
Functional spec only — implementation here is 100% digital RTL.

## Interface inventory (all digital)

| # | Block | Ports | Math | Ground |
|---|---|---|---|---|
| 1 | Lane Router (no arith) | `ilp_in[0..5]:in:128xint8+vr`, `tile_in:out:128xint8+vr`, `tile_out:in:128xint8+vr`, `olp_out:out:128xint8+vr` | identity steer + 2x256→512 implicit concat | L60 |
| 2 | Phase Sequencer (08-D) | `layer_idx:out:5b`, `phase:out:2b`, `tile_sel:out:4b` one-hot/phase, `fifo_lane_en_ilp/olp:out:6b+6b`, `cal_addr:out:{layer5b,block2b,phase2b,chunk6b,col8b}` | p0 INPROJ, p1 OUTPROJ, p2 GATE/UP, p3 DOWN | L58, L70-72 |
| 3 | Lane FIFO ctrl (6 lanes) | `dig_in:in:128xint8+vr`, `tile_out:out:128xint8+vr`, `almost_full:out:1b` | entry 128B DEPTH 8; 1/cyc burst | L58, L70 |
| 4 | INPROJ MAC tile | `tok:in:576xint8`, `qkv:out:960xint8` (Q576+K192+V192) | `Y = X*W^T` chunked over K, requant/chunk | 02 |
| 5 | OUTPROJ MAC tile | `z:in:576xint8`, `zout:out:576xint8` | `Zout = Z*W^T` col-split, concat MUX | 04 |
| 6 | GATE/UP/DOWN MAC tiles + requant | `x:in`, `y:out:int8`, `cfg:per-chunk scale/zero` | MAC + `clip((acc*scale)>>shift+zero)`; 30 resident layer-use sets | L152, L230 |
| 7 | Concatenator | `slices_in:in:3xCxint8`, `row_out:out:576xint8` by column | `Zout=concat(slices)`, zero arithmetic | L60, 04 |
| 8 | Chunk accumulators | per 02/04/06 | K-chunk digital psum + single requant per output | 02/04/06 |
| 9 | Loopback MUX + x_bank | `x_loopback_out:out:576x8`, `layer_done:out:1b`, `overflow:AXI BASE+l*S*576+tok` | `X(l+1)=Layer(Xl)`; ping-pong swap; l<29 loop, l==29 LM head | L44, L172 |
| 10 | Recal Sequencer | `recal_trig:in:1b`, `cal_addr` use-select | use-index advance + coeff CRC verify (no drift in digital) | L230-248 |

## Per-phase routing (locked)

| Phase | Block | Lanes in | Lanes out | Note |
|---|---|---|---|---|
| p0 | INPROJ X→QKV | 0-1 | 0-4 | 5-lane OLP drain; QKV thirds separable per lane → ATTN_WAIT |
| p1 | OUTPROJ | 0-1 | 0-2 | 256+256 concat into one OLP; digital CONCAT MUX |
| p2 | GATE/UP | 0-1 | 0-5 | whole lane fabric, one wave (1536 = 6x256 chunks per mat) |
| p3 | DOWN | 0-5 | 0-1 | 6 chunk passes, digital accum + per-chunk coeffs |

Invariants: west-in / SN-out always; phases never overlap (non-pipelined);
tile groups ordered in phase order along lanes. `tile_sel` one-hot-per-phase,
idle block clock-gated, `cal_addr` picks resident block coeffs. `almost_full`
→ FSM stall; never a weight fetch.

Frame order: `p0→ATTN→p1→RMS1→p2→SILU→p3→RMS2→LOOPBACK→RECAL_CHECK`.
SW legs re-enter through the same valid/ready domain. Single-clock
demo default; CDC only at lane + result FIFOs.

## What is ON-chip now (paper mapped to digital vehicles)

Attention matrix, SwiGLU/softmax, LM head, RMSNorm+residuals,
calibration tables: the paper (L44/L206) kept these off the analog chip in
software; this package implements ALL of them as on-chip digital RTL blocks
(03/05/06/07/08). LM-head tap: last-token slice of X_29 post-LOOPBACK into
LAST_BUF; argmax over 32k classes to the SW GenEval sink (no margin,
no early exit — the 30-layer loop always runs to completion).

## Locked by the paper (functional spec, not implementation)

- Four layer-blocks: inProj (→Q/K/V), outProj, GATE/UP, DOWN — over 99%
  of weights (L34).
- One decoder layer-block set on one chip, outputs fed back as next-layer
  inputs, iterated 30x (L42-44). Fully weight-stationary (L40).
- Four phases per layer in sequence inProj→outProj→FC1→FC2 (L58, L70-72);
  6 ILPs west-in, 6 OLPs south/north-out; 512-elem vectors on 512 wires;
  2x256 implicit concat (L60); no-crossing, non-pipelined (L70-88).
- 7-bit quant + per-tile calib (L152) → implemented as int8 + per-use
  requant tables.
- Calibration: columnwise scale/offset per layer-block PER LAYER USE — 30 uses.
  Digital has no drift: T_RECAL is the coeff-set rotation interval,
  verified by CRC, not by G tracking.
- No early exit carried over (that was an ALBERT 12-layer result, L116);
  the 30-layer loop always runs to completion.

## Demo parameters — OURS to choose, not paper gaps

Sysclk, MAC lanes, chunk factor, mesh latency, frame ms, S target (demo
S≤64 vs HF max 2048), FIFO depths, clock-domain split, LM-head tap
(final-only, no per-layer snoop). The paper measured these on silicon (Supp. Fig. 9);
for a proof-of-concept sim we pick plausible values and document them — they
are inputs, not unknowns.
All picked values live in PARAMS.md (§1–§9); this section is the question
list, PARAMS is the answer sheet.
