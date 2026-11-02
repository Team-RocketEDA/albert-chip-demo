# 09 — Analog/digital interface (fuses the two islands)

Paper grounding: Fig2 caption L58-60 (4 phases, 6 ILP west-in, 6 OLP SN-out,
512-elem duration vectors, 2x256 mesh concat); L70-72+L88 (ILP/OLP throughput
constraint, non-pipelined, no-crossing, 79.4%, 2 keep-outs); L208-210 (34 tiles,
512x512@4PCM, cap-share doubling); L152-168 (FC2 6-tile worst, FC1 analog-pair
cleanest); L44/L206 (only 4 FC blocks on-chip); L172/L256 (frame anatomy);
L116 (early-exit 0.4%); L230-248 (columnwise scale/offset, drift+recal).
`[H]` = hypothesis (no paper/repo value exists).

## Interface inventory

| # | Block | Ports | Math | Ground |
|---|---|---|---|---|
| 1 | Mesh Router (digital, no arith) | `ilp_in[0..5]:in:512x1b`, `west_out:out:512x1b` to tile west, `sn_in:in:512x1b`, `olp_out:out:512x1b` | identity steer + 2x256→512 implicit concat | L60 |
| 2 | Phase Sequencer (08-D) | `layer_idx:out:4b`, `phase:out:2b`, `tile_sel:out:34b` one-hot/phase, `fifo_lane_en_ilp/olp:out:6b+6b`, `cal_addr:out:{block2b,phase2b,tile6b,col10b}` | p0 INPROJ, p1 OUTPROJ, p2 FC1, p3 FC2 | L58, L70-72 |
| 3 | ILP FIFO ctrl (6 lanes) | `dig_in:in:128xint8+vr`, `mesh_out:out:128xint8+vr`, `almost_full:out:1b` | entry 128B DEPTH 8; 1/cyc burst, 1/512 drain | L58, L70 |
| 4 | Duration Encoder + row driver | `tok:in:512xint8`, `pulse:out:512x analog T_on + sign` | `T_on[i]=\|x[i]\|*T_lsb` [H: T_lsb/V_read/T_window unknown] | L60 |
| 5 | PCM tile + integrator | `v_row:in:analog`, `i_col/v_int` internal | `I_j=sum V_i*(G+-G-)`, 4PCM/w; `V=(1/C)int(I)-Vcm` | L72, L208 |
| 6 | OLP Digitizer + Calib | `v_int:in:analog`, `d_raw:512x7b`, `y_cal:out:int8 = clip(d_raw*slope+off)` | 7-bit SAR + per-col scale/offset; 12 coeff sets per 12x-reused block | L152, L230 |
| 7 | Concatenator | `slices_in:in:3xCxint8`, `row_out:out:768xint8` by column | `Zout=concat(slices)`, zero arithmetic | L60, 04 |
| 8 | FC1 pair / FC2 shiftacc | per 06 | FC1 analog-sum-then-one-digitize; FC2 6x digital accum (6x ADC noise path) | L152/168 |
| 9 | Loopback MUX + x_bank | `x_loopback_out:out:768x8`, `layer_done:out:1b`, `overflow:AXI BASE+l*S*768+tok` | `X(l+1)=Layer(Xl)`; ping-pong swap; l<11 loop, l==11 pooler | L44, L172 |
| 10 | Recal Sequencer | `recal_trig:in:1b`, ref ports to cal SRAM | `s_eff=s*(1+alpha*(t-t0))`; `s_new=s_old*(ref_exp/ref_meas)`; per-block (not per-tile) reload | L128-147, L230-248 |

## Per-phase routing (locked)

| Phase | Block | ILP lanes | OLP lanes | Note |
|---|---|---|---|---|
| p0 | INPROJ X→QKV | 0-1 | 0-4 | 5-lane OLP drain; QKV thirds separable per lane → ATTN_WAIT |
| p1 | OUTPROJ | 0-1 | 0-2 | 256+256 mesh-concat into one OLP; digital CONCAT MUX |
| p2 | FC1 | 0-1 | 0-5 | whole OLP fabric, one wave (6x512=3072 exact); cap-share analog-sum mode |
| p3 | FC2 | 0-5 | 0-1 + half-share | 6 tiles digitized separately, digital 6x accum (worst variation) |

Invariants: west-in / SN-out always; phases never overlap (non-pipelined);
tile groups ordered in phase order along mesh; shared tiles must be an
ADJACENT phase-order pair; 2 white squares are hard keep-outs; FC2 6-stack
gets the widest straight corridor. Tile-share arbitration is pure time-mux:
`tile_sel` one-hot-per-phase, idle block tristated, `cal_addr` picks resident
block coeffs. `almost_full` → FSM stall; never a weight fetch.

Frame order: `p0→p1→ATTN_WAIT→p1drain→LN1→p2→GELU_WAIT→p3→LN2→LOOPBACK→RECAL_CHECK`.
SW legs re-enter through the same ILP/OLP valid/ready domain. Single-clock
demo default; CDC only at ILP/OLP + SW-result FIFOs.

## What stays off-chip (paper = demo)

Attention matrix, GELU/softmax/tanh, pooler/classifier, LayerNorm+residuals,
calibration-compute host (paper L44/L206). Digital sits next to ILP/OLP pairs
(L256) but is modeled as SW FIFOs; no on-chip digital pipelining (L178 future
work). Pooler tap: non-intrusive snoop of `X_l[0]` post-LOOPBACK into CLS MUX,
concurrent with next layer; exit on margin (L116: layer-11 within 0.4%).

## Locked by the paper (not open questions)

- Four layer-blocks in hardware: inProj (→Q/K/V), outProj, FC1, FC2 — over 99%
  of weights (L34). Everything else — attention matrix compute, GELU/softmax/
  tanh, pooler, classifier — off-chip in software (L44, L206).
- One ALBERT layer on one chip, outputs fed back as next-layer inputs, iterated
  12x (L42-44). Fully weight-stationary (L40).
- Four phases per layer in sequence inProj→outProj→FC1→FC2 (L58, L70-72);
  6 ILPs west-in, 6 OLPs south/north-out; 512-elem duration vectors on 512 wires;
  2x256 implicit mesh concat (L60); no-crossing, non-pipelined, ILP/OLP are the
  throughput constraint, 79.4% of 34 tiles, 2 keep-out squares (L70-88).
- inProj/outProj split across partial/shared tiles; FC1 analog-pair sum (cleanest);
  FC2 6-tile/6-half-tile sum (worst variation) (L168). 512x512@4PCM, 1.05M/tile,
  cap-share doubling (L208-210). 7-bit OLP quant + per-tile calib (L152).
- Calibration: columnwise scale+offset per layer-block PER LAYER USE — 12 uses
  of FC1 = 12 coeff sets, excitation distributions differ per layer (L230).
  Drift: log-G decay, nu 0.01-0.10, recal tracks the mean (L236-248).
- Early exit: post-layer-11 within 0.4% of layer-12 (L116). Analog MAC cost
  includes edge delivery + ILP/OLP conversion; digital assumed next to ILP/OLP
  pairs (L256).

## Demo parameters — OURS to choose, not paper gaps

T_lsb / V_read / T_window, ADC cycles, mesh latency, frame ms, S target (demo
S≤64 vs paper ≤128), column factor, FIFO depths, clock-domain split, pooler
per-layer-tap vs final-only. The paper measured these on silicon (Supp. Fig. 9);
for a proof-of-concept sim we pick plausible values and document them — they
are inputs, not unknowns. Fig2h/i per-tile identities are immaterial to a 1-2
tile proxy and were never needed.
