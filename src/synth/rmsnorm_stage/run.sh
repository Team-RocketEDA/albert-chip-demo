#!/usr/bin/env bash
# rmsnorm_stage sky130 P&R demo (librelane-devshell toolchain, repo-driven flow).
# Real GDS for rmsnorm_stage with its baked weight tables etched ($readmemh ROMs
# elaborated by yosys from REPO root so the bake paths resolve).
#   bash run.sh [TAG]  # synth -> P&R -> GDS -> PNG screenshot into out/<TAG>/
# TAGs: v1_2d = etched-weight 2D tile (default); v1_sram = SRAM-macro
# variant (reserved: same matrix, only the weight-layer shape changes).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
# rocket-engine (sister folder, provisioned): tools resolve from it.
# RE_ROOT override wins; PATH gains its oss-cad-suite + klayout bins.
RE_ROOT="${RE_ROOT:-$REPO/../rocket-engine}"
export RE_ROOT PATH="$RE_ROOT/.tools/oss-cad-suite/bin:$RE_ROOT/.tools/klayout-0.30.12/bin:$PATH"
PDK="${PDK:-$HOME/.local/share/pdk/sky130A}"
LIB="$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_100C_1v80.lib"
NIX=/tmp/librelane-shell/squashfs-root/nix/store
YOSYS=$(echo $NIX/*-yosys-0.62/bin/yosys)
OPENROAD=$(echo $NIX/*-openroad-2026-02-17/bin/openroad)
MAGIC=${TOOL_MAGIC:-$(command -v magic)}
KLAYOUT=$(echo $NIX/*-klayout-0.30.7/bin/klayout)

TILE="rmsnorm_stage"
TAG="${1:-v1_2d}"
OUT="$HERE/out/$TAG"
export REPO PDK LIB TILE TAG OUT
mkdir -p "$OUT/nl" "$OUT/pnr"
echo "[1/4] synth (yosys) [$TAG]";       sed -e "s|@REPO@|$REPO|g" -e "s|@LIB@|$LIB|g" -e "s|@OUT@|$OUT|g" "$HERE/synth.ys.in" > "$OUT/synth.gen.ys" && (cd "$REPO" && "$YOSYS" -q -s "$OUT/synth.gen.ys") 2>&1 | tail -5
echo "[2/4] place [$TAG]";                "$OPENROAD" -no_splash -exit "$HERE/pnr.tcl" 2>&1 | tee -a "$OUT/run.log" | tail -3
echo "[2b/4] route [$TAG]";               "$OPENROAD" -no_splash -exit "$HERE/pnr_route.tcl" 2>&1 | tee -a "$OUT/run.log" | tail -5
echo "[3/4] GDS merge (magic) [$TAG]";   (cd "$OUT" && "$MAGIC" -dnull -noconsole -rcfile "$PDK/libs.tech/magic/sky130A.magicrc" "$HERE/merge.tcl" 2>&1 | tail -3)
echo "[4/4] screenshot (klayout) [$TAG]"; "$KLAYOUT" -b -r "$HERE/shot.py" 2>&1 | tail -3
echo "done [$TAG]: $OUT/${TILE}_${TAG}.gds $OUT/${TILE}_${TAG}_top.png"
