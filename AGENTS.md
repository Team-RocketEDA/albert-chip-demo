# AGENTS.md — albert-chip-demo (MobileLLM-125M, 100% digital RTL, sky130A)

Vibe-coded AI chip: MobileLLM-125M mapped 1-to-1 to Verilog, one tile at a
time through LibreLane Classic (`sky130_fd_sc_hd`), stitched in `tiles/`.
`mobilellm_top` is simulation-only — silicon comes from stitched block GDS,
never a flat run (OOM kills on 31GB). `./build.sh` is the one driver.

Map: [README.md](README.md) (test/verify, benchmarks, status, roadmap),
`architecture/` (contracts), `src/synth/RUN_ORDER.md` (tile order),
[tiles/README.md](tiles/README.md) (assembly).

## Rules
- GDS: `./build.sh gds [block|all]`, ONE AT A TIME, resumable
  (`clean [block|all]` wipes `out/<TAG>/` first). Keep outputs at
  `src/synth/<block>/out/<TAG>/design/runs/<TAG>/final/gds/`; commit goldens
  to `tiles/` + `renders/` only.
- Memories are never logic: read-only + const ⇒ etched via-ROM; dynamically
  written ⇒ regfile/SRAM macro. Synth blackboxes them; P&R needs their LEF;
  stitching swaps in the etched macros.
- Every memory file carries `(* blackbox *)` under `` `ifdef __librelane__ ``
  (see Lessons). Sim/stitch/netlist/Verilator must never define that macro.
- Clock: `CLOCK_PERIOD` in `config.json` is currently IGNORED (not
  forwarded) — every tile runs the adapter default 10ns. One chip = one
  clock: change it once globally, never per tile.
- Every synth blackbox also needs a liberty stub (checker + STA want cell
  identity): generate with `src/synth/gen_rom_lib.py`, pin widths matching
  the synthesized params, and list it in that tile's `blackbox_models`.

## Lessons
- LibreLane `blackbox_models` with `.v` files is NOT a true blackbox: its
  pyosys helper reads them `read_verilog -lib` with only `keep_hierarchy`
  (only `.lib` files get `-setattr blackbox`). Inferred memories inside
  still hit pass 100 `MEMORY_MAP` — 9.4M muxes, OOM, dead run. The
  `(* blackbox *)` guard above is the fix; verify with
  `yosys ... -D__librelane__ ...; hierarchy -top <tile>; proc; write_json`
  (`attributes.blackbox == 1`), then run the `memory` pass — it must finish
  in seconds mapping only tiny regs.

## Blackbox policy (distil into a skill later)
Razor: blackbox what silicon gets elsewhere; synthesize what this tile is.
Mechanism: `.v` in `blackbox_models` alone blackboxes nothing — the
`(* blackbox *)` attribute under `` `ifdef __librelane__ `` is what makes
it real. The file stays in `VERILOG_FILES`; sim/stitch/netlist/Verilator
never define the macro, so their bodies are untouched.

Blackbox (with case):
- `lm_wrom.v` in `lm_head` — 16x576B weight ROM, one row/cycle; etched
  via-ROM later. Without the guard: 9.4M muxes, synth OOM at pass 103.
- `embed_lut.v` in `embed_top` — 32000x576B token table; baked hex in sim,
  etched ROM in silicon.
- `sram_1r1w.v` / `regfile_dp.v` in layer tiles — dynamic banks; P&R macro
  (LEF) provided, never gates.
- Any foreign/hard IP with no synthesizable body.

Never blackbox (with case):
- The tile's own logic: `mac_array` dots, `seq_fsm`, `fifo_sync`, argmax —
  boxing them tapes out an empty chip.
- Sim/stitch/netlist flows: TBs probe bodies (`$readmemh`, hierarchy);
  the JSON render uses its own `-lib` + `keep` mechanism, not this guard.
- Small regs/flops (`xbuf`, `logits`, skid buffers) — they map cleanly;
  boxing them erases the design.
- Smell test: boxing something because synth is slow (not because silicon
  lives elsewhere) means the tile is too big — split it, don't box it.
