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
# sram_1r1w/regfile_dp/embed_lut are read `-lib`: interface-only cells
# keep type+pins+widths, interiors are never elaborated — so embed_lut's
# 32000x4608 zero-init ROM (~147 Mbit) costs nothing instead of stalling
# write_json for tens of minutes.
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
# VERBOSE=1 echoes timestamped stage markers to stderr; default 0 keeps logs clean.
VERBOSE="${VERBOSE:-0}"
log() { if [ "$VERBOSE" = "1" ]; then printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; fi; }
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
# Macros stay interfaces only: they are read with `-lib` (ports parsed,
# interiors never elaborated — never unrolled, never $readmemh-loaded,
# never mem2reg'd), so `blackbox` after hierarchy is unnecessary.
# Block-diagram only: `proc` converts always-blocks to cells first (the
# JSON backend cannot serialize raw processes, and opt_clean skips
# process-containing modules — that was the "ignoring module" warning,
# not a dropped block), then `setattr keep` pins every hierarchical
# instance (without it, `delete` orphans the boxes' outputs and
# `opt_clean` garbage-collects the orphaned boxes — that was the
# vanishing-instances bug), then `delete t:$*` strips every gate-level
# primitive ($and/$dff/$mem/...) and `opt_clean` sweeps the dangling
# wires. Each module keeps ports + child-block instances + the nets
# between them:
# black boxes in black boxes, never implementation. This also bounds
# the JSON (no exploded buffers, no init payloads). Note it does NOT
# bound elaboration itself — giant cones (attention/full-top) still
# unroll before the strip, so generate per tile and compose with
# replicate_tile.py.
#
# Dead files are EXCLUDED, not just unreached: yosys `write_json`
# dumps every module it parsed (including unreached ones with their
# $mem init payloads), so loop_mem_seq (5.9 Mbit dead banks) and
# dram_ctrl (legacy, TB-only refs) stay out of the read list.
# shellcheck disable=SC2206
SRCS=(src/components/*.v)
_EXCLUDE=("src/components/loop_mem_seq.v" "src/components/dram_ctrl.v")
SRCS=($(printf '%s\n' "${SRCS[@]}" | grep -vxF -f <(printf '%s\n' "${_EXCLUDE[@]}") || true))
LIBSRCS=(src/components/sram_1r1w.v src/components/regfile_dp.v src/components/embed_lut.v)
# Macros never join the normal read: -lib parses ports only, interiors are
# never elaborated, so the 147 Mbit ROM and $mem banks cost exactly zero.
SRCS=($(printf '%s\n' "${SRCS[@]}" | grep -vxF -f <(printf '%s\n' "${LIBSRCS[@]}") || true))
log "read: ${#SRCS[@]} files (+${#LIBSRCS[@]} lib macros) top=$TOP"
# NETLIST_CLEAN drops the 4 unconditional ROM preloads (cos/sin,
# head weights, norm gamma) so the render shows clean blocks with
# no init-data bloat. Sim/synth never define it: default paths
# below are byte-identical.
YOSYS_LOG="$TMPDIR_WORK/yosys.log"
YOSYS_PROG="read_verilog -defer -DNETLIST_CLEAN ${SRCS[*]}; read_verilog -lib -DNETLIST_CLEAN ${LIBSRCS[*]}; hierarchy -check -top $TOP; proc; setattr -set keep 1 t:*; setattr -unset keep 1 t:\$*; setattr -set keep 1 t:\$paramod*; delete t:\$*; opt_clean; write_json $RAW"
if [ "$VERBOSE" = "1" ]; then
  log "yosys: streaming live below (also saved to $YOSYS_LOG)"
  "$YOSYS" -p "$YOSYS_PROG" 2>&1 | tee "$YOSYS_LOG" || true
else
  "$YOSYS" -q -p "$YOSYS_PROG" >"$YOSYS_LOG" 2>&1 || true
  grep -i -E "error|warning.*top|no.*module" "$YOSYS_LOG" | head -5 || true
fi
# Always keep the full log beside the output while the render pipeline is
# young (trim to failure-only later): last run's stage counts are the
# first thing checked when a top misbehaves.
cp "$YOSYS_LOG" "${OUT%.json}.yosys.log"
if [ ! -s "$RAW" ]; then
  echo "FATAL: yosys produced no JSON; full log saved to ${OUT%.json}.yosys.log"
  exit 1
fi

log "write: $OUT"
REPO="$REPO" TOP="$TOP" OUT="$OUT" RAW="$RAW" VERBOSE="$VERBOSE" python3 - <<'EOF'
import json, os, subprocess, sys, datetime
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
if os.environ.get("VERBOSE") == "1":
    ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    print(f"{ts} done: {nmod} modules, {nwires} wires, {ncells} cells, "
          f"top={top} ports={len(ports)} out={out}", file=sys.stderr)
EOF
