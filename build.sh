#!/usr/bin/env bash
# build.sh — the ONE driver for this repo. No flag-fighting.
#
#   ./build.sh prereqs          check + list every prerequisite
#   ./build.sh test [name|all]  elab + contract tests + iverilog stitch TBs
#                               + Verilator benches, one by one (default: all)
#   ./build.sh gds [block|all]  per-block LibreLane runs, ONE AT A TIME
#                               (default: all, small blocks first — OOM-safe)
#   ./build.sh stitch           KLayout abut tiles/*.gds -> tiles/mobilellm-125m.gds
#                               (v1: audit + place + merge; wiring follows)
#   ./build.sh flow preflight [block|all]  rocket-engine digital_flow preflight
#                               (cheap: version+inputs, no run)
#   ./build.sh flow run <block> rocket-engine Classic flow per block (HEAVY;
#                               never the flat top; GDS -> tiles/)
#   ./build.sh clean            remove sim/build outputs (never weights, never tiles/)
#
# Test bench names: embed rmsnorm inproj top prompt  (Verilator)
# Stitch TB names:  embed_top attention outproj rmsnorm ffn lm_head (iverilog)
# GDS block names:  mac_array lm_head embed_top outproj_tile rmsnorm_stage
#                   attention_core ffn_tile layer0 .. layer29
# ASSUMPTION (see README): rocket-engine is cloned as a SISTER folder of
# this repo and fully provisioned (its scripts/provision_toolchain.sh
# --install) before running anything here. Every tool below resolves from
# it; override per variable, never by editing paths into files.
#   RE_ROOT  rocket-engine root (default: <this-repo>/../rocket-engine)
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
RE_ROOT="${RE_ROOT:-$ROOT/../rocket-engine}"
RE_PY="$RE_ROOT/.venv/bin/python"
RE_OSS="$RE_ROOT/.tools/oss-cad-suite/bin"
RE_KL="$RE_ROOT/.tools/klayout-0.30.12/bin"
export RE_ROOT RE_PY PATH="$RE_OSS:$RE_KL:$PATH"

# PDK lookup: $PDK wins; then well-known locations (volare, Thompson, system).
# Override per-machine with PDK=/path/to/sky130A — never edit this file for paths.
if [ -z "${PDK:-}" ]; then
  for c in "$HOME/.volare/sky130A" "$HOME/.local/share/pdk/sky130A" "${PDK_ROOT:-}/sky130A" /usr/share/pdk/sky130A; do
    if [ -d "$c" ]; then PDK="$c"; break; fi
  done
fi
PDK="${PDK:-}"
# User's source-built magic is canonical; nix copy is ignored.
MAGIC_BIN="$(command -v magic 2>/dev/null || echo /usr/local/bin/magic)"

need()  { command -v "$1" >/dev/null 2>&1 && echo "  OK       $1" || { echo "  MISSING  $1 $2"; return 1; }; }
opt()   { command -v "$1" >/dev/null 2>&1 && echo "  OK       $1 (optional)" || echo "  -        $1 (optional, skipped)"; }

cmd_prereqs() {
  echo "== rocket-engine ($RE_ROOT) =="
  local fail=0
  [ -x "$RE_PY" ] && echo "  OK       venv python ($RE_PY)" || { echo "  MISSING  $RE_PY — provision rocket-engine first"; fail=1; }
  if [ -x "$RE_PY" ]; then
    "$RE_PY" -c "import cocotb, gdsfactory, pytest" 2>/dev/null && echo "  OK       venv modules (cocotb+gdsfactory+pytest)" || { echo "  MISSING  venv modules (cocotb/gdsfactory/pytest)"; fail=1; }
  fi
  echo "== required =="
  need iverilog "($RE_OSS)" || fail=1
  need verilator "($RE_OSS)" || fail=1
  [ -x "$MAGIC_BIN" ] && echo "  OK       magic ($MAGIC_BIN)" || { echo "  MISSING  magic (source build, /usr/local/bin/magic)"; fail=1; }
  command -v klayout >/dev/null && echo "  OK       klayout" || { echo "  MISSING  klayout"; fail=1; }
  [ -n "$PDK" ] && [ -d "$PDK" ] && echo "  OK       PDK ($PDK)" || { echo "  MISSING  PDK dir — set PDK=/path/to/sky130A"; fail=1; }
  ls weights/bake/layer0_q_proj.hex >/dev/null 2>&1 && echo "  OK       weights/bake (baked hex present)" || echo "  -        weights/bake hex absent: set HF_TOKEN and run weights/fetch_weights.sh, then bake"
  echo "== optional =="
  opt surfer; opt sby; opt yosys
  [ "$fail" -ne 0 ] && { echo "prereqs: REQUIRED BITS MISSING"; return 1; }
  echo "prereqs: READY"
}

cmd_test() {
  local sel="${1:-all}"
  echo "== [1/4] elab =="
  bash src/scripts/elab.sh || return 1
  echo "== [2/4] contract tests ($RE_PY) =="
  "$RE_PY" -m unittest discover -s architecture/tests || return 1
  echo "== [3/4] iverilog stitch TBs ($sel) =="
  if [ "$sel" = all ]; then bash src/scripts/run_stitch.sh || return 1;
  elif [ "$sel" = embed_top ] || [ "$sel" = attention ] || [ "$sel" = outproj ] || [ "$sel" = rmsnorm ] || [ "$sel" = ffn ] || [ "$sel" = lm_head ]; then bash src/scripts/run_stitch.sh "$sel" || return 1; fi
  echo "== [4/4] Verilator benches ($sel) =="
  case "$sel" in
    all)          make -C src/sim_verilator embed && make -C src/sim_verilator rmsnorm && make -C src/sim_verilator inproj && make -C src/sim_verilator top ;;
    embed|rmsnorm|inproj|top) make -C src/sim_verilator "$sel" ;;
    prompt)      make -C src/sim_verilator prompt ;;
    embed_top|attention|outproj|ffn|lm_head) echo "(stitched above; no separate Verilator bench)" ;;
    *) echo "unknown test name: $sel"; return 1 ;;
  esac || return 1
  echo "TEST: ALL SELECTED PASS"
}

cmd_gds() {
  local sel="${1:-all}"
  local seq="mac_array lm_head embed_top outproj_tile rmsnorm_stage attention_core ffn_tile"
  if [ "$sel" != all ]; then seq="$sel"; fi
  for b in $seq; do
    echo "=== GDS $b (log src/synth/$b/run.log) ==="
    bash "src/synth/$b/run.sh" || { echo "GDS FAILED at $b — fix before continuing"; return 1; }
  done
  if [ "$sel" = all ]; then
    for i in $(seq 0 29); do
      echo "=== GDS layer${i}_etched ==="
      bash "src/synth/layer${i}_etched/run.sh" || { echo "GDS FAILED at layer${i} — fix before continuing"; return 1; }
    done
  fi
  echo "GDS: ALL SELECTED DONE — outputs in src/synth/<block>/ + tiles/ assembly next"
}

cmd_stitch() {
  export REPO="$ROOT" TILES="${TILES:-$ROOT/tiles}"
  "$RE_KL/klayout" -b -r "$ROOT/tiles/stitch.py" || return 1
}

case "${1:-help}" in
  prereqs) cmd_prereqs ;;
  test)    cmd_test "${2:-all}" ;;
  gds)     cmd_gds "${2:-all}" ;;
  stitch)  cmd_stitch ;;
  flow)    shift; "$RE_PY" src/synth/run_librelane.py "$@" || exit 1 ;;
  clean)   make -C src/sim_verilator clean 2>/dev/null; rm -f /tmp/stitch_*.log /tmp/stitch_*.vvp; echo "CLEAN DONE (weights/ and tiles/ untouched)" ;;
  *) sed -n '2,14p' "$0" ;;
esac
