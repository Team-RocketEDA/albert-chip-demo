# tiles/ — tracked per-block GDS output

Each hardened block lands here as its own GDS, one file per macro, so the
Magic/KLayout stitch script has stable inputs to wire into `mobilellm-125m.gds`.

## Layout

- `layer{0..29}_etched.gds` — one per unrolled decoder-layer macro
  (3,538,944 INT8 weights each; demo slice binds layer-0 goldens).
- `embed_top.gds`, `attention_core.gds`, `outproj_tile.gds`,
  `rmsnorm_stage.gds`, `ffn_tile.gds`, `lm_head.gds` — major areas.
- `mobilellm-125m.gds` — final stitched full-chip output (repo root of this
  folder's purpose; produced by the stitch script, not by LibreLane).

## Rules

- GDS files here are committed deliberately (demo goldens), unlike
  `weights/bake/` output which stays gitignored.
- Only GDS + this manifest live here: no logs, no reports, no Lewis.
- Source of truth for how each GDS was made: `src/synth/<block>/config.json`
  plus the bake manifest (`weights/bake/INDEX.md`).
- Toolchain rule (repo-wide): every `run.sh` resolves tools from the
  provisioned sister folder `../rocket-engine` (`RE_ROOT` override wins);
  Magic comes from PATH (source build, canonical).

## Current contents

- `mac_array.gds` — seed: proven block (P=32, 12,401 cells, zero DRC),
  copied from `renders/mac_array.gds`. Per-layer/per-area GDS land here as
  the user runs each block's LibreLane flow.
