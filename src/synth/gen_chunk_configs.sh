#!/usr/bin/env bash
# gen_chunk_configs.sh — per-slice LibreLane Classic configs (--chunk path).
#
# One dir per (layer, slice): src/synth/layer{N}_inproj_c{K}/ with the same
# 7-file flow as gen_layer_configs.sh (config.json, synth.ys.in, run.sh,
# pnr.tcl, pnr_route.tcl, merge.tcl, shot.py), DESIGN = layer{N}_inproj_c{K}
# matching the emit_chunks.py leaf wrapper. One slice per run only — never
# the full layer in one run (OOM kills; keep each block small).
#
# DIE heuristic: slice logic scales ~1/C but control/FIFO/MAC floor does
# not, so die = max(500, 2000/sqrt(C)). Calibrate from the pilot slice
# (shrink while route DRC stays clean, grow on congestion) — the number is
# a starting point, not silicon truth.
#
# Usage: bash src/synth/gen_chunk_configs.sh --chunks C [--layers 0-29]
# (run from repo root; run chunk.py + emit_chunks.py first so the slice
# hex files and leaf wrappers the configs point at exist before synth).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# Template machinery only (sourced file has a main guard: no side effects).
# shellcheck source=gen_layer_configs.sh
source "$HERE/gen_layer_configs.sh"

PY="${RE_PY:-python3}"
CHUNKS_REQ=""
LAYERS_SPEC="0-29"
while [ $# -gt 0 ]; do
  case "$1" in
    --chunks) CHUNKS_REQ="$2"; shift 2 ;;
    --layers) LAYERS_SPEC="$2"; shift 2 ;;
    *) echo "usage: gen_chunk_configs.sh --chunks C [--layers 0-29]"; exit 1 ;;
  esac
done
[ -n "$CHUNKS_REQ" ] || { echo "missing --chunks C"; exit 1; }

C="$("$PY" weights/bake/chunk.py --resolve "$CHUNKS_REQ")"
if [ "$C" -le 1 ]; then
  echo "monolithic (C=1): gen_layer_configs.sh already covers this"
  exit 0
fi
DIE="$("$PY" -c "import math; print(max(500, int(round(2000/math.sqrt($C)))))" )"

INPROJ_FILES="src/components/inproj_tile.v src/components/fifo_sync.v src/components/mac_array.v src/components/regfile_dp.v src/components/requant.v src/components/seq_fsm.v src/components/sram_1r1w.v"

# Expand --layers 0-29 / 0,1,2 via the chunk module (single source).
LAYERS="$("$PY" -c "
import sys; sys.path.insert(0, 'weights/bake')
from chunk import parse_layers
print(' '.join(map(str, parse_layers('$LAYERS_SPEC'))))")"

count=0
for n in $LAYERS; do
  for k in $(seq 0 $((C - 1))); do
    emit_block "layer${n}_inproj_c${k}" "layer${n}_inproj_c${k}" "$DIE" \
      "$INPROJ_FILES src/generated/layer${n}_inproj_c${k}.v"
    count=$((count + 1))
  done
done
echo "OK: $count slice configs (C=$C, die $DIE)"
