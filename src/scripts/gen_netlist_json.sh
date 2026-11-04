#!/usr/bin/env bash
# gen_netlist_json.sh — yosys hierarchy -> renderable netlist JSON.
#
# Contract (rocketeda/netlist/v1): envelope {schema, project, top,
# revision, pdk, created} + yosys `write_json` modules table.
#   modules.<name>.ports.<pin>  = {direction: input|output, bits:[msb,lsb]}
#   modules.<name>.cells        = instances {type, connections}
#   modules.<name>.netnames     = wires
# The UIUX renderer treats every entry as a component/entity: blocks
# are modules, pins are ports, wires are netnames, drill-down is a
# descent into cells whose type names another module. Same parsing
# model as every other block — no special cases.
#
# No synthesis, no techmap, no ABC: `hierarchy -check` only, so this
# is seconds per top and never elaborates memories into flops.
# sram_1r1w/regfile_dp are `blackbox`ed: cells keep type+pins+widths,
# internals and $mem init payloads never enter the JSON. embed_lut
# joins them: its 32000x4608 zero-init ROM (~147 Mbit) serializes
# for tens of minutes under write_json, so it renders as an opaque
# addressed-ROM block instead.
# $readmemh defaults resolve from the repo root (CWD forced below);
# absolute -D overrides still win via VERILOG_DEFINES if you add them.
#
# Usage (run from anywhere; YOU run this — needs a working yosys):
#   bash src/scripts/gen_netlist_json.sh [top] [out.json]
#   bash src/synth/../scripts/gen_netlist_json.sh mobilellm_top
# Defaults: top=mobilellm_top, out=renders/mobilellm_top.netlist.json
#
# Yosys resolution: $YOSYS wins, else PATH yosys, else the provisioned
# librelane-devshell 0.62 (same binary the tile flows use).
set -euo pipefail
TOP="${1:-mobilellm_top}"
OUT="${2:-renders/mobilellm_top.netlist.json}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

if [ -z "${YOSYS:-}" ]; then
  if command -v yosys >/dev/null 2>&1; then
    YOSYS="$(command -v yosys)"
  else
    RE_ROOT="${RE_ROOT:-$REPO/../rocket-engine}"
    NIX="$RE_ROOT/.tools/librelane-3.0.17/squashfs-root/nix/store"
    YOSYS="$(echo $NIX/*-yosys-0.62/bin/yosys)"
  fi
fi

TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
RAW="$TMPDIR_WORK/raw.json"

# Bus preservation: hierarchy-only, no flatten/techmap/ABC, so multi-bit
# nets stay whole (netnames carry bit arrays; the renderer groups by
# netname = compressed buses with widths, never bit-blasted).
# `-defer`: parse all files but elaborate only the top's reached cone.
# Without it, read_verilog unrolls every initial zero-fill loop
# (embed 32000 rows, ffn/inproj ~1M-iter fills) and loads every
# default $readmemh hex (~50 MB) even for modules the top never
# reaches — that stalls 30+ min. Deferred modules never elaborate,
# so only the rendered cone pays elaboration cost.
# `blackbox` runs AFTER hierarchy: under -defer the macros don't
# exist yet at read time (selections would match nothing), while
# post-hierarchy they elaborate trivially (their $mem interiors and
# any init payloads are then dropped before write_json).
#
# Dead files are EXCLUDED, not just unreached: yosys `write_json`
# dumps every module it parsed (including unreached ones with their
# $mem init payloads), so loop_mem_seq (5.9 Mbit dead banks) and
# dram_ctrl (legacy, TB-only refs) stay out of the read list.
# shellcheck disable=SC2206
SRCS=(src/components/*.v)
_EXCLUDE=("src/components/loop_mem_seq.v" "src/components/dram_ctrl.v")
SRCS=($(printf '%s\n' "${SRCS[@]}" | grep -vxF -f <(printf '%s\n' "${_EXCLUDE[@]}") || true))
# NETLIST_CLEAN drops the 4 unconditional ROM preloads (cos/sin,
# head weights, norm gamma) so the render shows clean blocks with
# no init-data bloat. Sim/synth never define it: default paths
# below are byte-identical.
"$YOSYS" -q -p "
read_verilog -defer -DNETLIST_CLEAN ${SRCS[*]}
hierarchy -check -top $TOP
blackbox sram_1r1w regfile_dp embed_lut
write_json $RAW
" 2>&1 | grep -i -E "error|warning.*top|no.*module" | head -5 || true
[ -s "$RAW" ] || { echo "FATAL: yosys produced no JSON (see log above)"; exit 1; }

REPO="$REPO" TOP="$TOP" OUT="$OUT" RAW="$RAW" python3 - <<'EOF'
import json, os, subprocess, datetime
repo, top, out, raw = (os.environ[k] for k in ("REPO", "TOP", "OUT", "RAW"))
with open(raw) as f:
    payload = json.load(f)
modules = payload.get("modules", {})
assert top in modules, f"top {top} missing from netlist modules"
ports = modules[top].get("ports", {})
assert ports, f"top {top} has no ports"
try:
    rev = subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                         capture_output=True, text=True, cwd=repo).stdout.strip()
except Exception:
    rev = "unknown"
envelope = {
    "schema": "rocketeda/netlist/v1",
    "project": "albert-chip-demo",
    "top": top,
    "revision": rev,
    "pdk": "sky130A",
    "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "modules": modules,
}
os.makedirs(os.path.dirname(os.path.join(repo, out)) or ".", exist_ok=True)
with open(os.path.join(repo, out), "w") as f:
    json.dump(envelope, f)
nmod, nwires, ncells = len(modules), 0, 0
for m in modules.values():
    if isinstance(m, dict):
        nwires += len(m.get("netnames", {}))
        ncells += len(m.get("cells", {}))
print(f"OK {out}: {nmod} modules, {nwires} wires, {ncells} cells, "
      f"top ports={len(ports)} @{rev}")
EOF
