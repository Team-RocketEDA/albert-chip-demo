# MobileLLM-125M Decoder Chip — vibe-coded silicon

A 100%-digital MobileLLM-125M decoder (`L=30/H=576/GQA-kv3/SwiGLU/RMSNorm/RoPE`),
designed and verified block by block as an agentic coding demo, with a first block
taken through place-and-route to GDS. Everything below is real: every number was measured in this repo, every waveform captured
from simulation, the GDS drawn by an open-source P&R flow on the sky130A PDK.

Built with **Muse Spark 1.3** through the **rocket-engine MCP**.

![mac_array block GDS, sky130A, 480x480 um](renders/mac_array_top.png)

*First layout: `mac_array` (P=32) placed and routed in sky130A —
12,401 cells, 13,915 nets, 485,719 shapes, zero DRC. Full-chip GDS waits
on the stitching; the hierarchy above the leaves is still structural.*

## What this is

The repo retargeted from ALBERT to a **MobileLLM-125M decoder** (repo name
predates the switch and will be renamed). Contract-first, weight-stationary,
INT8 datapaths with Q8.8/Q4.12 fixed-point islands:

- `src/components/` — parametric RTL (`data_bit_width` everywhere, Yosys
  infers `+`/`-`/`*`, muxes are `if`/`case`)
- `architecture/` — the human-readable contract: hierarchy docs plus
  hand-rolled drill-down schematics ([top-level](architecture/mobilellm-top.html),
  [block tree](architecture/blocks-tree.html),
  [router](architecture/mobilellm-router.html), one page per block in
  [architecture/pages/](architecture/pages/))
- `weights/` — fetch script and manifest. The baked INT8 tables and goldens in
  `weights/bake/` (272 tensors verified from the finetuned safetensors) are local
  and gitignored
- `src/sim_verilator/` — readable Verilator benches with Surfer waveforms
- `src/synth/mac_array/` — one-config LibreLane flow to GDS
- `renders/` — committed demo goldens (GDS + screenshot)

## How to test and verify

You need Icarus Verilog, Verilator, Yosys and SymbiYosys, LibreLane for the GDS
flow, and Surfer for waves. Every command runs from the repo root.

| Gate | Command | Current status |
|---|---|---|
| Architecture contract | `python3 -m unittest discover -s architecture/tests` | 52 pass, 7 skip (tools or local files absent; run `-v` for reasons) |
| Elaboration | `bash src/scripts/elab.sh` | ELAB-OK |
| Unit sims (per block) | `iverilog -g2012 -s <tb> src/components/*.v src/tb/<...>.v && vvp a.out` | all PASS |
| Verilator tokens | `make -C src/sim_verilator embed` | `EMBED_VLT PASS (8 ids)`, byte-exact |
| Prompt test | `make -C src/sim_verilator prompt PROMPT_IDS="1 2 0x42"` | token ids in, vectors out, `waves_prompt.fst` |
| Dashboard | `python3 src/sim_verilator/dashboard.py` | `renders/dashboard.html` — live transcripts + GDS + links |
| Verilator norms | `make -C src/sim_verilator rmsnorm` | `RMSNORM_VLT PASS (576 lanes, tol=3 LSB)`; needs local `weights/bake/` |
| Verilator top smoke | `make -C src/sim_verilator top` | builds, 29 modules (outputs float: top is structural) |
| Formal proofs | `sby -f src/tb/rmsnorm_d/rmsnorm_d.sby` | PASS, 7m28s |
| Regressions | `tb_dotK_k128`, `tb_mac_array_p32` | PASS at shipped defaults |
| Synth + P&R | config in `src/synth/mac_array/` | GDS, zero DRC (see below) |

Waves land next to the benches — open them in Surfer:

```sh
surfer src/sim_verilator/waves_embed.fst    # token_id -> vec
surfer src/sim_verilator/waves_rmsnorm.fst  # x, gamma -> y, y_valid
surfer src/sim_verilator/waves_top.fst      # ids_in, pred_out, done
```

The terminal transcript is the readable reference (every input printed
with its output); the FST is the inspectable proof.

Weights are gated Meta files: put your `HF_TOKEN` in the environment and
run `weights/fetch_weights.sh`. The bake script and its output in `weights/bake/` are
not committed, so benches that read them (`rmsnorm`, `tb_rmsnorm_d`) need a local bake.
Weight binaries are never committed; `renders/` keeps one demo GDS.

## Benchmarks (all measured here)

**Synthesis to sky130_fd_sc_hd (tt), yosys 0.62:**

| Block | Cells | ABC time |
|---|---|---|
| `mac_unit` | 528 | <1 s |
| `mac_array` P=32 (shipped default) | 12,401 | 52 s (Booth-recoded; unrecoded never converged in 20+ min) |
| `dotK` K=128 (shipped default) | 48,939 | 31 min single-threaded |

**Place & route (`mac_array`, OpenROAD 2026-02-17, 480x480 um die):**
13,915 nets, 363,757 um routed wire, utilization 0.47, **zero DRC
violations**, GDS 33 MB with 485,719 shapes across 24 layers.

**Verification:** contract tests (52 pass, 7 skip on a clean clone), full-domain LUT sweeps (65,536
codes vs Python oracle), K=128/P=32 default-parameter regressions,
rmsnorm formal proof PASS.

## How rocket-engine helped

The engine is what makes vibe-coding a chip tractable instead of a
thousand lost files:

- **Project format** (`src/project.yaml`, `.rocket/` ledger) — every
  module has a doc contract and an RTL path; the ledger records each
  plan, proof, and bake as an event, so any agent (or human) can pick up
  exactly where the last one stopped.
- **Contracts first** — `architecture/blocks/*.md` are the source of
  truth; the HTML schematics are hand-rolled views of the same contracts,
  with typed I/O on every port before any logic was written.
- **Elaboration gate** (`src/scripts/elab.sh`) — the wiring-only skeleton
  elaborates clean at every step, so integration never rots while leaves
  are implemented in parallel.
- **One-config silicon** — `src/synth/mac_array/config.json` is the whole
  tapeout flow: PDK, corners, die size. LibreLane Classic does the rest;
  the repo keeps no TCL except two tiny stage scripts.

## Status and next steps

- DONE: leaf logic + unit sims + formal proofs + default-parameter
  regressions + Verilator benches with waves + first block GDS.
- NEXT: stitch the hierarchy (embed -> 30x loop -> head) so `pred_out`
  goes live; the `top` bench becomes the token-in/token-out demo the day
  it does. Then: full-model Verilator run, Sky130 signoff steps (CTS, PDN,
  LVS), and the full-chip GDS.
