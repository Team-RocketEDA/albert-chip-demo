# mac_array sky130 P&R demo (librelane-devshell toolchain, repo-driven flow)
#
# Real GDS for the default mac_array (P=32, W=8) — the most-used datapath
# leaf in the MobileLLM decoder — built with the sky130A PDK installed on
# this machine. Orchestrated by run.sh (checked in); binaries come from
# the librelane 3.0.17 devshell (yosys 0.62 / openroad 2026-02-17 /
# magic 8.3 / klayout 0.30.7). Full librelane-orchestrated Classic is the
# follow-up; it needs ciel/volare PDK resolution (offline here), while
# this flow points at the PDK files directly.
#
#   bash run.sh            # synth -> P&R -> GDS -> PNG screenshot
#
# Outputs (regenerable, git-ignored except the demo artifacts):
#   nl/        synthesized gate netlist + yosys stats
#   pnr/       floorplanned/placed/routed DEF + final netlist + reports
#   mac_array.gds                      <- committed demo artifact
#   mac_array_top.png                  <- committed demo artifact
#
# Demo scope, stated plainly: single ideal clock, no CTS, no power grid
# (tapcells + abutted rows only). This is a real placed+routed block GDS
# for demo, not a signoff tapeout. Full-chip GDS waits on the stitching
# (top is still structural) and SRAM macros for the weight banks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
PDK="${PDK:-$HOME/.local/share/pdk/sky130A}"
LIB="$PDK/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_100C_1v80.lib"
NIX=/tmp/librelane-shell/squashfs-root/nix/store
YOSYS=$(echo $NIX/*-yosys-0.62/bin/yosys)
OPENROAD=$(echo $NIX/*-openroad-2026-02-17/bin/openroad)
MAGIC=$(echo $NIX/*-magic-vlsi-*/bin/magic)
KLAYOUT=$(echo $NIX/*-klayout-0.30.7/bin/klayout)

export REPO PDK LIB
mkdir -p "$HERE/nl" "$HERE/pnr"
echo "[1/4] synth (yosys)";       sed -e "s|@REPO@|$REPO|g" -e "s|@LIB@|$LIB|g" "$HERE/synth.ys.in" > "$HERE/synth.gen.ys" && "$YOSYS" -q -s "$HERE/synth.gen.ys" | tee "$HERE/run.log"
echo "[2/4] place";                "$OPENROAD" -no_splash -exit "$HERE/pnr.tcl" 2>&1 | tee -a "$HERE/run.log" | tail -3
echo "[2b/4] route";               "$OPENROAD" -no_splash -exit "$HERE/pnr_route.tcl" 2>&1 | tee -a "$HERE/run.log" | tail -5
echo "[3/4] GDS merge (magic)";   (cd "$HERE" && "$MAGIC" -dnull -noconsole -rcfile "$PDK/libs.tech/magic/sky130A.magicrc" merge.tcl 2>&1 | tail -3)
echo "[4/4] screenshot (klayout)"; "$KLAYOUT" -b -r "$HERE/shot.py" 2>&1 | tail -3
echo "done: $HERE/mac_array.gds $HERE/mac_array_top.png"
