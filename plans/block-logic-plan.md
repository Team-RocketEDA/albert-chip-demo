# Block-logic implementation plan (MobileLLM-125M decoder, on-chip weights)

Goal: fill every structural skeleton in `src/components/` with real logic,
one block at a time, red-green-refactor per block, unit-tested in iverilog
and formally checked with sby where the property fits. Integrator (me)
stitches and runs the Verilator + testbench check; Sky130/LibreLane synth
closes the run after the Verilator check passes.

## Step 0 — Weight bake (prerequisite for goldens)

Source: `weights/mobilellm-125m/finetuned/` (verified: 272 tensors =
30x9 + embed + final norm; shapes EXACTLY match the RTL dims: Q 576x576,
K/V 192x576, O 576x576, gate/up 1536x576, down 576x1536, norms 576,
embed 32000x576, fp32, no biases anywhere; architecture identical to
base MobileLLM-125M. No `lm_head` tensor ships — W_lm is baked as an
embed copy, two 18MB banks).
Bake script (pure-python stdlib, no numpy/torch on this box): per-channel
absmax int8 quant of each tensor → `$readmemh` hex tables per SRAM bank +
quant report (max abs err per tensor). FIRST: per-block test vectors +
proxy layer-0 tables (minutes). STRETCH: full 125MB bake.
Acceptance: shapes match every `sram_1r1w` bank; dequant error within the
PARAMS §2 budget; proxy tables load in iverilog.
Out of scope: retraining, new quant schemes (absmax only), pushing binaries
to git (gitignored).

## Steps 1–11 — Block logic (one agent per step, red-green-refactor)

Loop per block: RED (iverilog tb fails against the skeleton) → GREEN
(minimal logic) → REFACTOR (clean, parametric) → VERIFY (tb + `slang`
+ block sby properties). Math oracle is ALWAYS the baked checkpoint
bytes via an independent pure-python golden — never the RTL under test.
Constraints: keep module ports/topology (skeletons are the contract);
`data_bit_width` parametric; no `always` outside sync regs... (sync
`always @(posedge)` allowed now — logic phase); shared files
(`project.yaml`, tests, docs) are integrator-owned, agents touch only
their `src/components/<block>.v` + new `src/tb/tb_<block>.v`.

1. MAC family (`mac_unit`, `mac_array`, `dotK`). Formal: accumuland
   equals unbounded python sum (sby assert). Acceptance: randomized
   int8 vectors incl. saturation corners match golden bit-exact.
2. Arith glue (`adder`, `sub`, `mult`, `shifter`, `alu_bit`, `dff`,
   `muxN`, `cmp`). Acceptance: exhaustive (small widths) + randomized
   iverilog tb; yosys sat-equiv vs `+`/`*` inference.
3. `requant` (shift/scale/clip). Formal: clip boundaries + shift exactness.
4. `fifo_sync` (+ `irq_sync`). Formal: no overflow/underflow, full/empty
   correctness, FWFT ordering.
5. Memories (`sram_1r1w`, `regfile_dp`, `dram_ctrl`). Acceptance: init
   from baked hex, read/write protocol checks, spill path.
6. `seq_fsm` (phase/layer/`cal_addr`). Formal: one-hot phases, 30-state
   reachability, `layer5b` format, no dead state.
7. `embed_lut` (baked 32k×576 table). Acceptance: spot lookups vs baked
   bytes; token-id edge cases (0, 31999).
8. `silu_lut` + `exp_lut` (table contents). Acceptance: vs pure-python
   silu/exp within PARAMS Q4.12 tolerance.
9. `softmax_d` (causal). Acceptance: vs python float softmax within fixed
   tolerance, causal mask enforced, row-sum ≈ 1.
10. `rmsnorm_d`. Acceptance: vs python RMSNorm with baked gamma, eps 1e-5.
11. `div_unit`. Acceptance: reciprocal/division vs python within 1 ulp-ish
    bound per PARAMS.

## Step 12 — L1 stitch + sim (integrator, me)

Wire-up unchanged (already elaborates); run proxy layer-0 through the new
logic in iverilog, then Verilator lint + sim with `testbench/` golden
compare. Acceptance: suite 59 green, elab + slang clean, Verilator sim
matches HF golden within §9 budget on the proxy subset.

## Step 13 — Sky130 synth (after Step 12)

Yosys `synth` → LibreLane via the `librelane-devshell` AppImage (no
`openlane`/`librelane` on PATH; devshell is the vehicle). SRAM macros via
OpenRAM cuts sized per bank; 125MB stays a bake artifact for sim, NOT a
tapeout target (stated scope: proof-of-concept). Acceptance: synth clean,
one GDS per macro, top assembly vs BUILD_MAP.

## Tool gates (every step)

`iverilog+vvp` unit sims, `slang --lint-only`, `sby` for safety/math
props, `verilator --lint-only` pre-sim, repo suite green before handoff.
No torch/numpy/transformers on this box — goldens are stdlib python.
