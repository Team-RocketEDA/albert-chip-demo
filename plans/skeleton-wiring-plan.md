# Plan: implementation-less Verilog skeletons per block (contracts first)

Objective: one wiring-only Verilog skeleton per architecture block, ports from
the typed I/O tables, hierarchy mirroring blocks/01–09. Zero implementation.
Implementation is a later parallel pursuit, leaf by leaf.

Mode: git-backed repo. Engine project `albert-chip-demo`
initialized via `ProjectService.create_project` (ledger at
`.rocket/projects/albert-chip-demo/`, head p12). Engine project id stays
`albert-chip-demo` until the repo itself is renamed (user owns that step).
Sources live in-repo at `src/` per engine `components/` + `scripts/`
conventions.

## Steps

1. DONE — engine project init (this plan's predecessor step; ledger exists).
2. `src/project.yaml` — project manifest: id, ledger pointer, block→doc map.
3. `src/scripts/elab.sh` — elaboration gate (`iverilog -tnull`, all sources).
4. §00-E leaves (ports only): fifo_sync, regfile_dp, sram_1r1w, dram_ctrl,
   muxN, adder, sub, mult, mac_unit, mac_array, dotK, dff, alu_bit, shifter,
   requant, cmp, exp_lut, silu_lut, rmsnorm_d, softmax_d, div_unit,
   embed_lut, irq_sync, seq_fsm. Two are wiring mid-levels (softmax_d,
   rmsnorm_d) since the docs give their inner pipes. (`gelu_lut.v` and
   `tanh_lut.v` retired to `/tmp/retired-20261102/` with the ALBERT encoder.)
5. L1 wiring (one file per top-level block): mobilellm_top, embed_top,
   loop_mem_seq, inproj_tile, attention_core, outproj_tile, rmsnorm_stage,
   ffn_tile, lm_head. Children + wires only.
6. Handroll HTML refresh (mobilellm-top.html, blocks-tree.html, phase pages) —
   digital labels/sublabels/tags/cards; drill links re-pointed by route.
7. Park `rtl/embed` + `rtl/common` implementation spikes under
   `rtl/reference-spikes/` (evidence preserved, out of the contract tree).
8. Contract tests (`TestSkeleton`): module-per-file, hierarchy closure
   (every instantiated module has a file), no `always`/`assign`/`initial`
   outside comments, `elab.sh` exit 0. Full suite GREEN.
9. Review gate: subagent checks skeleton ports vs doc I/O tables.

## Invariants after every step

- `python3 -m unittest discover -s architecture/tests` stays GREEN.
- No implementation code in `src/` (checked by test, not by eye).
- Drill links / router routes untouched by HTML edits.
