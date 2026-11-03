# Full-model stitch plan — close out all Verilog, wire the whole decoder

Goal: every `STRUCTURAL ONLY` skeleton in `src/components/` becomes real
wired logic; `mobilellm_top` goes ids-in → pred-id-out in sim; then
Verilator token sim + GenEval + per-macro GDS. Leaves already done
(`mac_unit/array`, `dotK`, `requant`, `div`, `fifo`/`irq_sync`,
`sram_1r1w`, `regfile_dp`, `dram_ctrl`, `seq_fsm`, `embed_lut`,
`silu/exp_lut`, `rmsnorm_d`, `softmax_d` — all simmed, most proven).

Status today: 10 structural files float outputs by design —
`mobilellm_top`, `embed_top`, `loop_mem_seq`, `inproj_tile`,
`attention_core`, `outproj_tile`, `rmsnorm_stage`, `ffn_tile`,
`lm_head`, `dff`. Math oracle is ALWAYS baked checkpoint bytes via
independent pure-stdlib python — never the RTL under test.
Constraints inherited: ports/topology frozen (skeletons are the
contract); `data_bit_width` parametric; inferred `+ - *` / `if`-`case`
only, no new single-operator modules ever; run every bench from the
repo root; shared files (`project.yaml`, tests, docs) are
integrator-owned — workers touch only their block + its tb.
Out of scope: retraining, new quant schemes (absmax only), pushing
binaries to git, any RV32, any analog/mixed-signal, signoff/P&R beyond
demo-clean (no CTS/PDN required).

## Phase 0 — Stitch harness + proxy stimulus (no DUT change)

Add `src/tb/stitch/` harness in the house style (run-from-root,
`$readmemh`, no delays in Verilator paths): loads layer-0 baked tables
(`weights/bake/layer0_{q,k,v,o,gate,up,down}_proj.hex`, norms,
`embed_full.hex`) + every `tv_*` act/golden pair. Confirm coverage:
each stage below names its act/golden; any gap gets a `bake.py`
extension first.
Acceptance: all hex loads clean in iverilog; suite 59 green; elab clean.

## Stage A — `embed_top`: ids -> X0 frame

Wire `u_idfifo -> u_emb_lut -> u_xbuf -> u_dbuf -> x0_out`; `ids_ready`
= fifo_rd, `x0_valid` = layer_done from `u_ctrl`. Implement `dff`
here too (single flop, same pattern). Drive S=64 ids from
`tv_embed_ids.hex`, collect the 64x576 frame, compare
`tv_embed_golden.hex` byte-exact. Fidelity note: sim may use the full
18 MB `embed_full.hex` ($readmemh handles it); sparse proxy only if
sim time forces it — document the choice.
Acceptance: byte-exact frame + edges (id 0/31999, OOR reads zero).

## Stage B — `inproj_tile`: X -> packed QKV

Chunk loop over the 576B rows (C=256): `u_infifo` -> `mac_array`
(P=32) K-fold with `acc_in` fold -> `u_accum` (960 s32) -> `requant`
per chunk with `cfg_scale/cfg_zero` -> `u_outfifo`; `u_ctrl` sequences
chunk/col via `seq_fsm` IRQs. Wire `y_out` as packed Q|K|V thirds.
Acceptance: Q/K/V thirds vs `tv_{q,k,v}_golden.hex` — mac part exact,
requant path bit-exact vs the python golden (same formula); any
deviation is a bug, not tolerance.

## Stage C — `attention_core`: QKV -> Y

Split thirds; **RoPE sub-step (arch-cited):** `03-attention-core.md`
item 4 already specifies `rope_Q`/`rope_K` as named inner blocks
(mult pairs + constant sin/cos tables), and the skeleton (`attention_core.v:40`)
states rotation as inferred mult-add pairs — so no new file, same as
`rowmax_tree`/`q_buf`: implement as named generate-looped instance
groups `u_rope_q`/`u_rope_k` (pair split -> mult-add -> concat) fed by
a baked sin/cos Q4.12 ROM; extend `bake.py` (pure stdlib) to emit it
from `rope_theta` 10000.0; acceptance vs python RoPE within 1 LSB.
Then QK dots -> scale -> `softmax_d` (causal=1, **reset `row_q` at
frame start** — counter alignment is a known integration trap) -> AV
-> Y; K/V cache SRAM banks for decode, streaming prefill.
Acceptance: Y vs python float reference within the documented
fixed-point budget (softmax itself: 16 LSB Q4.12, row-sum ~= 1.0).

## Stage D — `outproj_tile`: Z -> Zout

Same MAC-tile pattern as B (own instances, no premature sharing):
`W:[576x576]`, col-split, concat MUX, requant per chunk.
Acceptance: vs `tv_o_golden.hex`, same exactness rule as B.

## Stage E — `rmsnorm_stage` x2 (LN1/LN2 + resid)

s8 -> `s8<<8` widen, resid add with `sat16`, `rmsnorm_d` D=576 framed
streaming (64 rows = 64 frames), requant fxp16->int8 narrow.
Acceptance: vs `tv_rmsnorm_golden.hex` within 3 LSB; zero-frame and
saturation corners carried over from the leaf tb.

## Stage F — `ffn_tile`: gate/up -> silu*up -> down

Gate/up mats in parallel (`tv_gate/tv_up` act+golden), `silu_lut` on
the gate psum (mind the Q4.12 domain at the LUT input), inferred
elementwise `gate*up` (mind the width: fxp16 x fxp16 -> rescale),
down proj (`tv_down`), accum + requant.
Acceptance: bit-exact vs goldens (same formula as the bake oracle).

## Stage G — `lm_head`: last-token -> pred id

Slice X_29 last row -> `LAST_BUF` -> dots over W_lm (embed copy).
Full 32k x 576 = 18.4M MACs serial is too slow for iverilog: default
to the baked vocab subset (`tv_lmhead_*`, 16 rows), full vocab as the
Verilator stretch in Stage J. argmax as an inferred compare loop;
`pred_out` + 1-cycle `done`.
Acceptance: subset logits bit-exact; argmax picks the golden id;
`done` pulses exactly once per `x_valid`.

## Stage H — `loop_mem_seq`: the 30x loopback

xbank ping-pong, resid paths (`x_in` -> RMS1 resid, attn_y -> RMS2
resid), `layer_idx` 0..29 from `seq_fsm`, iterate
`p0->ATTN->p1->RMS1->p2->SILU->p3->RMS2->LOOPBACK`, `layer_done`
exactly at l==29 with `x_out` = X_30. First prove the protocol with
stubbed tiles (layer_idx sequence + done timing), then plug the real
tiles; determinism check: loop layer-0 tables twice, identical out.
Acceptance: 30-iteration protocol exact; no phase overlap (locked
invariant); `almost_full` -> FSM stall demonstrated, never a weight
fetch.

## Stage I — `mobilellm_top`: ids -> pred id

Wire EMBED -> LOOP30 -> HEAD (last-token slice already in the
skeleton) with `x_valid && loop_done` gating the head. Verilator-first
for the top (harness exists in `src/sim_verilator/`; add
`--trace-max-width` for wide buses as already documented);
tile-level iverilog stays for debugging. Proxy run: S=64 ids from
`tv_embed_ids.hex` through all 30 layers (layer-0 weights looped per
the determinism check — full 30-layer bake is the stretch).
Acceptance: `pred_out` live (no floats), `done` protocol exact,
contract suite green, elab + slang + Verilator lint clean.

## Stage J — full Verilator token sim + GenEval + dashboard

Extend the C++ driver with gen-subset prompts (baked tv ids), pred
ids out, SW compare via `testbench/tb_scoreboard.py` vs the HF
golden. Regenerate `renders/dashboard.html` from the live runs
(transcripts are the reference, FSTs the proof).
Acceptance: dashboard shows ids -> preds end to end; scoreboard runs;
new `waves_top.fst` carries a real token wave, not X.

## Stage K — synth/P&R per macro + top assembly

Extend the `mac_array` LibreLane pattern (`src/synth/mac_array/`,
one `config.json` per macro) to embed/inproj/attn/outproj/norm/
ffn/head/loop blocks: synth stats, routed DEF, zero-DRC GDS each.
Weight banks come from `sky130_fd_bd_sram` (in-PDK — RTL RAMs as
flops stop being viable past the leaf demo; 125 MB stays a bake
artifact for sim, never taped out). Top assembly vs BUILD_MAP.
Acceptance: one GDS per macro in `renders/`; synth clean.

## Working agreements (locked for this plan)

- One stage = one commit, Conventional Commits, neat; never mix a
  stage commit with workflow-owned or unrelated files.
- Every stage: elab clean, integration tb vs golden, no new
  structural floats (`y_out`-style ports driven), suite green.
- Verilator benches run from the repo root; waves land next to the
  benches; Surfer is the viewer, transcripts are the reference.
- If a golden is missing, the stage starts with the `bake.py`
  extension, not with a placeholder.
- Gen-subset compare lives in SW (`testbench/`); the chip only ever
  emits pred ids.

