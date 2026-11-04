#!/usr/bin/env bash
# outproj_tile via rocket-engine's LibreLane adapter (no handrolled P&R).
#   bash run.sh [TAG]   # one librelane Classic call, outputs in out/<TAG>/
# TAGs: v1_2d = etched-weight 2D tile (default); v1_sram = SRAM-macro
# variant (reserved: same matrix, only the weight-layer shape changes).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
RE_ROOT="${RE_ROOT:-$REPO/../rocket-engine}"
export RE_ROOT
exec "$RE_ROOT/.venv/bin/python" "$REPO/src/synth/run_tile.py" "outproj_tile" "${1:-v1_2d}"
