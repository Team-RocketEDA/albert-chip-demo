# Via-ROM MVP Plan — MobileLLM on a cartesian MAC fabric (PLAN MODE, no execution)

Status: planning only. Nothing below has been run. The gdsfactory
install already in flight is the only background work; every step
here names its entry criteria so we can start anywhere green.

## 0. Locked decisions (from the research lanes)

- **GDS drawing: klayout-pya.** gdsfactory is not installed anywhere
  on this box today (checked all four venvs). The install now running
  makes it the growth path (netlists, DRC decks, PCells later), but
  Phase 2 is written for `klayout -b -r` + bundled `pya`: a via-ROM
  is rects plus arrays, and GF's strengths (routing, PDK devices)
  don't apply to it. Same geometry code works under either API.
- **Bit cell: NOR, via-programmed.** Bit = presence/absence of one
  `VIA1` cut between `MET1` strap and `MET2` bitline (reported as
  `VIA1 68/44`, `MET1 68/20`, `MET2 69/20`, wordline `poly 66/20`,
  always-present `mcon 67/44` + `li1 67/20` — **verify against
  `libs.tech/magic/sky130A.magicrc` + tech LEF in Phase 0**).
  Diffusion-contact programming rejected (front-end mask, hard ECO).
  Readout: weak-PMOS pull-up + inverter per column, combinational,
  no sense amp. Tables under ~32 kbit stay synthesized `case()` ROMs.
- **Env: package parity, not byte-copy.** A literal venv copy breaks
  absolute shebangs/pyvenv paths. albert-chip-demo/.venv gets the
  engine dep set (verbatim pyproject, already synced) plus
  `gdsfactory>=9.51,<10`. Use the engine venv's python directly
  where convenient; never `cp -r` a venv.

## 0b. Why the macro takes space (tie vias are free; wires are not)

A constant bit IS just a via to GND/VDD — the cut itself
(~0.17 µm) plus enclosure is a fraction of a µm², and synthesis
already does exactly this (tiehi/tielo cells) wherever a weight
feeds combinational logic with no runtime addressing. Those cases
need no macro at all: biases, zero-points, config constants
constant-propagate today and cost ~nothing.

The macro exists for the addressed case only. inproj/outproj/ffn
weight rows are indexed at runtime by fold counters, so each bit
must be *selectable*, not just tied: that needs shared wordlines,
bitlines, row drivers, and per-column readout. The ~1 µm²/bit
planning number is ~5% via, ~95% wire pitch + drivers + readout
amortized per bit, plus periphery. A fully-spatial alternative
(125M individual tied nets, no array) is worse, not better: every
net needs a routing track, and congestion explodes long before
area does — the array is the price of *sharing* wires across bits.

Rule, locked: compile-time-constant weights → synthesis ties
(free, no macro). Runtime-addressed weights → array ROM macro.
The inventory in §4 already follows this split (RoPE/gamma stay
synthesized `case()` ROMs; only folded-table reads get macros).

## 1. Cartridge: what the fabric is

- **Columns = 30 layers.** `decoder_etched_stack.v` already is this:
  30 identical `layer_etched` stamps chained x_out(m) -> x_in(m+1)
  with frame-valid rippling down the chain. No new top wiring.
- **Rows = N spatial MAC rows per layer.** Each row entry = one MAC
  block + its via-ROM weight slice. Today N already exists in
  miniature: `mac_array P=32` = 32 physical MACs, time-folded over
  `C=256` chunks in inproj. The scale-out knob is an RTL `ROWS`
  parameter (replicate the array + slice the ROM address), default 1.
- **m -> m+1** = the existing inter-macro buses (`d[i]`, `vld[i]`);
  abutted columns share one address/valid spine (see §6).
- **N is OUR parameter; PnR never chooses it.** PnR places and routes
  exactly what RTL instantiates. N is picked from the area formula
  in §5 before any tool runs.

## 2. Area math (why monolithic is off the table)

- Model: 125M int8 params = 1 Gbit of ROM.
- Planning number 1 µm²/bit → **~1000 mm² of bit cells alone**,
  plus ~30% periphery, plus MAC logic, plus routing.
- Sky130 practical ceiling: ~10 mm² (MPW) to ~100 mm² (reticle).
  Monolithic full-chip is impossible by 10-100×. Tiling is required,
  not optional — which is exactly your separate-chips instinct.
- Per layer: ~3.5 MB weights = ~28 Mbit ≈ **28 mm² ROM + logic**.
  One layer fits a large sky130 die (~6×6 mm). So the natural chip
  is **one layer macro**; thirty of them make the model.
- Area driver is ROM, not MACs: one `mac_array` P=32 = 12,401 cells
  ≈ 0.1-0.15 mm² (dashboard census). A layer's MAC logic is < 1 mm²
  against ~28 mm² of ROM. **N (MAC rows) is a throughput knob with
  small area cost; the tiling problem is a ROM problem.**
- Demo N: keep P=32, ROWS=1 (current folded design, already proven
  in sim). Throughput scales ~linearly with ROWS when we need it.

## 3. What actually gets synthed separately (the whole list)

1. `rom<GEOM>` × 7 geometries — each hardened ONCE, GDS reused for
   every same-geometry instance (content variants are per-instance
   via plots from the same script, same footprint).
2. The layer logic macro — synth + P&R ONCE with all ROMs blackboxed.
3. The top assembly — placement of 30 stamps + spine routing only,
   never re-hardens the macro.
4. Small tables (RoPE, norms) ride inside logic synth as `case()` ROMs.

Everything else is instantiation. Total: **~8 synth/P&R jobs +
1 assembly**, versus today's 30× full elaboration. That is what
fixes both the LibreLane walk and the Verilator build blowup.

## 4. SRAM inventory and removal map (via-ROM only)

Weight SRAMs (INIT_FILE-bound → become `rom_1r` + macro):

| Instance | Table | Macro |
|---|---|---|
| `ffn_tile` u_gatew/u_upw/u_downw | WG/WU/WD (884736 B ea) | rom884736x8 |
| `inproj_tile` u_wqbank/u_wkbank/u_wvbank | WQ/WK/WV wide (110592 B ea) | rom110592x8 |
| `outproj_tile` u_wsram | WO wide (331776 B) | rom331776x8 |
| `lm_head` u_wlm (4608×32768, zero-filled!) | full-vocab, currently dead weight | **verify-then-delete** (subset path uses wmem) |

Narrow `*_FILE` `$readmemh` (inproj 93-95, outproj 77, ffn equiv,
attention COS/SIN, rmsnorm GN, embed INIT) stay as `rom_1r`
preload paths for sim; synthesis sees only the stub.

Buffer SRAMs (no INIT → keep behavioral for sim, stub for synth):

- `attention_core`: u_qbuf/u_kbuf/u_vbuf, u_kcache/u_vcache, u_score
- `embed_top`: u_dbuf (36864 B frame store)
- accumulators `regfile_dp` (inproj/outproj/ffn): small, may stay
  flops — decide per macro by cell count at Phase 6.

Dead code to prune from build file lists (elaborated but never
instantiated): `loop_mem_seq.v` (loop is gone), `dram_ctrl.v`
(check refs first). tb_top build uses `components/*.v` — switch to
an explicit file list per target.

## 5. Blackbox markers (when + how, exact mechanism)

**When:** with the `rom_1r.v` swap (first execution step, Phase 1).
NOT via `(* blackbox *)` attributes in shared RTL (that would break
sim). The file-based pattern:

- NEW `macros/via_rom/verilog/rom_stub.v` — empty modules, same
  port lists as `rom_1r.v` (one per geometry name).
- `run_tile.py`: split file lists into SIM_FILES (behavioral,
  including `rom_1r.v` + `sram_1r1w.v`) vs SYNTH_FILES (logic only)
  + `EXTRA_VERILOG_MODELS` (stubs). Forward all four EXTRA_* keys
  (currently forwarded: none).
- Tile `config.json`s gain the four EXTRA_* lists; `gen_layer_configs.sh`
  / `gen_chunk_configs.sh` emit them for generated configs.
- Existing behavioral `.v` files are never deleted; sim never sees
  a stub, synth never sees a memory array.

## 6. Abutment spec (separate tiles, one chip story)

Abutment holds iff, per stamp: identical height (fixed macro
footprint); PG rails at identical Y (continuous across seams);
edge pins on the manufacturing grid, mirrored N/S-E/W pairs;
OBS margin ≥ 1 pitch inside every edge; clock spine enters at a
fixed port. Assembly = LEF BLOCK macros + a placement script
stamping at computed pitches (OpenROAD odb or klayout pya),
followed by seam-only DRC + full LVS. Verify: DRC on a 2-stamp
seam test FIRST (Phase 6), 30-stamp only after the seam is clean.

## 7. Scripting LibreLane from Python (PyPI path)

`uv pip install librelane` resolves (29 packages: engine, ciel,
click, cloup…). Confirm-then-write: read the installed
`librelane/flows/` (Classic entry), `librelane/config.py`
(Config object + EXTRA_* key names), and `python3 -m librelane.steps
--help` (already known-good CLI surface). Target script
`albert-chip-demo/src/synth/assemble.py`:

1. Build one Config per macro (from the Phase 5 config.jsons).
2. Run Classic per macro in-process (shared state, no subprocess
   parsing — this is what the PyPI lib buys over the CLI).
3. Custom top step: floorplan + 30 stamps at abutment pitches +
   spine route, using the same odb handles the flow uses.
4. Emit tape-out bundle paths (top GDS + 7 macro GDS + LEF + LIB).

The engine adapter stays the single-tile path; `assemble.py` is
the macro+top path. Both read the same config.jsons.

## 8. Assembly order (the build sequence)

1. `rom_1r.v` + stubs; file-list split in `run_tile.py`; prune dead files.
2. `gen_rom_gds.py` → 7 macro GDS (via count == popcount(hex) check).
3. `gen_rom_lef.py` + `gen_rom_lib.py` → LEF/LIB/stubs.
4. Single-macro Classic (rom331776x8 family first) → DRC/LVS clean.
5. Layer-macro Classic with blackboxed ROMs → tile GDS.
6. 2-stamp seam test → 30-stamp top assembly → full GDS.
7. Verilator full-stack sim green on behavioral ROMs end-to-end
   (unchanged TB except INIT paths); text-in/text-out proof re-run.

## 9. Exit criteria / risks

- Exit: tile GDS + macro GDS + seam DRC clean + Verilator talking-bot
  green + tape-out bundle. README gets input-vs-output text.
- Risks: via geometry vs tech LEF mismatch (Phase 0 check);
  LIB timing correlation (flagged PRELIMINARY, re-measure at Phase 6);
  Verilator build RAM on 30× stack (mitigated: blackboxed weights
  shrink elaboration ~10×); GF API drift (plan is pya-first, GF is
  additive).

## 10. Trunk/branch execution (locked)

No RTL rewrites on trunk. Trunk keeps SRAM-capable RTL; dev de-SRAMs
for the via-ROM transfer.

- Trunk checkpoint 1: ONE MAC tile with SRAM-baked weights, macros
  blackboxed (stub views: PDK 1k/2k macros don't fit Mbit banks, so
  stubs by construction; LVS waived on trunk), through LibreLane to
  GDS. Candidate: inproj wide banks (~4.4 Mbit) or outproj slice.
  Before that, one cheaper gate: const-register synthesis (tie the
  weight nets to constants, no via-ROM, no RTL rewrite beyond an
  additive ifdef) to prove the flow without memory blowup.
- Trunk checkpoint 2: every NON-weight tile synths standalone.
- Merge trunk tiles.
- Dev: via-placement script on a single MAC GDS tile; correctness =
  tile TB vs numpy software reference on baked hex (prove one tile,
  true for all by construction). That is the via-ROM unit test.
- Dev: 30-col x 1-row MACs, via-ROMs placed + replicated (synth ONE
  MAC, rest is macros + abutment).
- Dev: full layer macro'd and connected (symmetric, abut-ready).
- Rest: typical LibreLane synth for other blocks, abut per RTL, stitch.
- Research item: after layer GDS, blackbox the layer as a macro
  (extern ports + size) and re-run LibreLane with every module so
  top-level PNR wires everything under constraints — no man’s land
  between dies. Needs real (not preliminary) LIBs to mean anything.

DOD (locked): tokens in, tokens out, verified MATHEMATICALLY against
the software model, plus LVS (netgen ex2spice) on the FINAL GDS
proving the GDS is the working model. Area unconstrained. Timing
closure required at least (sky130 is what it is).

## 11. Weight embodiment: literals for synth, vias for layout (locked)

Weights enter synthesis as Verilog literals (`localparam`/assign
constants per tile, metaprogrammed from bake hex), never as
$readmemh-preloaded memories. yosys `opt_const` + ABC then do what
they do: constant-propagate, collapse constant-coefficient
multipliers (mult-by-9 becomes shift+add), dead-code the rest.
$readmemh was the blowup (memory elaborated to flops BEFORE
optimization); literals skip that stage entirely. Sim uses the same
emitted file, so sim/synth cannot diverge. The via-ROM generator
consumes the same hex: metaprogram once, emit twice (literals for
synth, via plots for GDS). DOD oracle: straight HF python inference
on the finetune; demo prompts chosen where HF argmax is confident
(quant noise can flip close calls — compare top-k/logits, and lead
with a confident prompt).

## 12. readmemh hygiene rule (locked)

$readmemh is testbench-only. Synthesis gets weights as metaprogrammed
literals, never as preloaded memories. `src/scripts/check_synth_hygiene.py`
is the gate: GUARDED sites (parameter-constant false-by-default, folded
away) may stay textually; GRANDFATHERED unconditional sites
(attention RoPE x2, lm_head WLM, norm GN) must become literals on dev;
its binding list is the literal emitter's exact hit list. --strict
fails the build once literals land.
