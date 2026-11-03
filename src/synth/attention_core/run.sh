#!/usr/bin/env bash
# attention_core sky130 P&R demo (librelane-devshell toolchain, repo-driven flow).
# Real GDS for attention_core with its baked weight tables etched ($readmemh ROMs
# elaborated by yosys from REPO root so the bake paths resolve).
#   bash run.sh   # synth -> P&R -> GDS -> PNG screenshot
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

export REPO PDK LIB
mkdir -p "$HERE/nl" "$HERE/pnr"
echo "[1/4] synth (yosys)";       sed -e "s|@REPO@|$REPO|g" -e "s|@LIB@|$LIB|g" -e "s|@HERE@|$HERE|g" "$HERE/synth.ys.in" > "$HERE/synth.gen.ys" && (cd "$REPO" && "$YOSYS" -q -s "$HERE/synth.gen.ys") 2>&1 | tail -5
echo "[2/4] place";                "$OPENROAD" -no_splash -exit "$HERE/pnr.tcl" 2>&1 | tee -a "$HERE/run.log" | tail -3
echo "[2b/4] route";               "$OPENROAD" -no_splash -exit "$HERE/pnr_route.tcl" 2>&1 | tee -a "$HERE/run.log" | tail -5
echo "[3/4] GDS merge (magic)";   (cd "$HERE" && "$MAGIC" -dnull -noconsole -rcfile "$PDK/libs.tech/magic/sky130A.magicrc" merge.tcl 2>&1 | tail -3)
echo "[4/4] screenshot (klayout)"; "$KLAYOUT" -b -r "$HERE/shot.py" 2>&1 | tail -3
echo "done: $HERE/attention_core.gds $HERE/attention_core_top.png"
