#!/usr/bin/env bash
# build.sh — the ONE driver for this repo. No flag-fighting.
#
#   ./build.sh prereqs          check + list every prerequisite
#   ./build.sh test [name|all]  elab + contract tests + iverilog stitch TBs
#                               + Verilator benches, one by one (default: all)
#   ./build.sh gds [--tag=TAG] [--chunk=N] [block|all]
#                               per-block LibreLane runs via run_tile.py,
#                               ONE AT A TIME (default: all, small blocks
#                               first — OOM-safe). TAG defaults to v1_2d;
#                               outputs land in src/synth/<block>/out/<TAG>/.
#                               Resumable: tiles with a .gds under out/<TAG>/
#                               are skipped. `clean [block|all]` wipes
#                               out/<TAG>/ for the selection first (clean slate).
#     --chunk=N shards each layer's inproj along output rows into C slices
#       (C = largest divisor of 192 at/below N; --chunk=0/1 = monolithic).
#       e.g. --chunk=56 -> C=48 slices/layer, run one at a time, stitch
#       thirds across slices to rebuild the frame. Small blocks stay mono.
#   ./build.sh stitch           KLayout abut tiles/*.gds -> tiles/mobilellm-125m.gds
#                               (v1: audit + place + merge; wiring follows)
#   ./build.sh flow preflight [block|all]  rocket-engine digital_flow preflight
#                               (cheap: version+inputs, no run)
#   ./build.sh flow run <block> rocket-engine Classic flow per block (HEAVY;
#                               never the flat top; GDS -> tiles/)
#   ./build.sh clean            remove sim/build outputs (never weights, never tiles/)
#
# Test bench names: embed rmsnorm inproj top prompt chunk-equiv codec  (Verilator)
#   + l0probe (layer-0 fidelity dump for golden_l0bit.py)
#   + stitch TBs: embed_top attention outproj rmsnorm ffn ffn_full layer lm_head
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
  elif [ "$sel" = embed_top ] || [ "$sel" = attention ] || [ "$sel" = outproj ] || [ "$sel" = rmsnorm ] || [ "$sel" = ffn ] || [ "$sel" = ffn_full ] || [ "$sel" = layer ] || [ "$sel" = lm_head ]; then bash src/scripts/run_stitch.sh "$sel" || return 1; fi
  echo "== [4/4] Verilator benches ($sel) =="
  case "$sel" in
    all)          make -C src/sim_verilator embed && make -C src/sim_verilator rmsnorm && make -C src/sim_verilator inproj && make -C src/sim_verilator top && make -C src/sim_verilator chunk-equiv && make -C src/sim_verilator codec ;;
    embed|rmsnorm|inproj|top|chunk-equiv|codec) make -C src/sim_verilator "$sel" ;;
    prompt)      make -C src/sim_verilator prompt ;;
    l0probe)     make -C src/sim_verilator l0probe ID=1 ;;
    embed_top|attention|outproj|ffn|ffn_full|layer|lm_head) echo "(stitched above; no separate Verilator bench)" ;;
    *) echo "unknown test name: $sel"; return 1 ;;
  esac || return 1
  echo "TEST: ALL SELECTED PASS"
}

tile_gds() { # $1=block $2=tag -> print finished .gds path (if any) under out/<tag>/
  find "src/synth/$1/out/$2" -name '*.gds' -print -quit 2>/dev/null
}

run_one_tile() { # $1=block $2=tag — skip when already done (resume); else run
  local gds
  gds="$(tile_gds "$1" "$2")"
  if [ -n "$gds" ]; then echo "=== GDS $1 [$2] DONE — skip ($gds) ==="; return 0; fi
  echo "=== GDS $1 [$2] (log src/synth/$1/out/$2/) ==="
  "$RE_PY" src/synth/run_tile.py "$1" "$2" || { echo "GDS FAILED at $1 — fix before continuing"; return 1; }
}

tile_clean() { # $1=block $2=tag — remove ONLY src/synth/<block>/out/<tag>/
  case "$2" in ""|*/*|.*) echo "refusing to clean bad tag: [$2]"; return 1 ;; esac
  local d="src/synth/$1/out/$2"
  if [ -d "$d" ]; then rm -rf "$d" && echo "cleaned $d"; else echo "nothing to clean ($d absent)"; fi
}

cmd_gds() {
  local chunk_req="" sel="all" tag="v1_2d" clean_mode=0
  for a in "$@"; do
    case "$a" in
      --chunk=*) chunk_req="${a#--chunk=}" ;;
      --chunk) echo "use --chunk=N"; return 1 ;;
      --tag=*) tag="${a#--tag=}" ;;
      --tag) echo "use --tag=TAG"; return 1 ;;
      clean) clean_mode=1 ;;
      *) sel="$a" ;;
    esac
  done
  local C=1
  if [ -n "$chunk_req" ]; then
    C="$("$RE_PY" weights/bake/chunk.py --resolve "$chunk_req")"
    echo "chunk: requested $chunk_req -> C=$C slices/layer"
  fi
  if [ "$clean_mode" = 1 ] && [ "$sel" = all ] && [ "$C" -le 1 ]; then
    for d in src/synth/*/out/"$tag"; do [ -d "$d" ] && rm -rf "$d"; done
    echo "cleaned all src/synth/*/out/$tag/ (clean slate)"
  elif [ "$clean_mode" = 1 ] && [ "$C" -le 1 ]; then
    tile_clean "$sel" "$tag" || return 1
  fi
  if [ "$C" -gt 1 ]; then cmd_gds_chunked "$C" "$sel" "$tag" "$clean_mode"; return $?; fi
  local seq="mac_array lm_head embed_top outproj_tile rmsnorm_stage attention_core ffn_tile"
  if [ "$sel" != all ]; then seq="$sel"; fi
  for b in $seq; do
    run_one_tile "$b" "$tag" || return 1
  done
  if [ "$sel" = all ]; then
    for i in $(seq 0 29); do
      run_one_tile "layer${i}_etched" "$tag" || return 1
    done
  fi
  echo "GDS: ALL SELECTED DONE — outputs in src/synth/<block>/out/$tag/ + tiles/ assembly next"
}

cmd_gds_chunked() {
  # Chunked layer path: split hex -> emit slice wrappers -> gen slice
  # configs -> run each slice P&R one at a time via run_tile.py, like
  # the mono path. Small blocks stay mono.
  # Layer-rest logic (attention/ffn/outproj/norms) reuses today's small
  # configs; slice thirds concat at stitch time (tiles/stitch.py follows).
  local C="$1" sel="$2" tag="$3" clean_mode="${4:-0}" layers_spec="0-29"
  case "$sel" in
    all) ;;
    layer[0-9]*_etched) layers_spec="${sel#layer}"; layers_spec="${layers_spec%_etched}"
      if [ "$clean_mode" = 1 ]; then
        for d in src/synth/layer"${layers_spec}"_inproj_c*/out/"$tag"; do [ -d "$d" ] && rm -rf "$d"; done
        echo "cleaned layer${layers_spec} slices (clean slate)"
      fi ;;
    *) if [ "$clean_mode" = 1 ]; then tile_clean "$sel" "$tag" || return 1; fi
       run_one_tile "$sel" "$tag" || return 1
       return 0 ;;
  esac
  echo "=== chunk prep (C=$C, layers $layers_spec) ==="
  "$RE_PY" weights/bake/chunk.py --chunks "$C" --layers "$layers_spec" --wide || return 1
  "$RE_PY" weights/bake/emit_chunks.py --chunks "$C" --layers "$layers_spec" || return 1
  bash src/synth/gen_chunk_configs.sh --chunks "$C" --layers "$layers_spec" || return 1
  if [ "$sel" = all ]; then
    if [ "$clean_mode" = 1 ]; then
      for d in src/synth/*/out/"$tag"; do [ -d "$d" ] && rm -rf "$d"; done
      echo "cleaned all src/synth/*/out/$tag/ (clean slate)"
    fi
    for b in mac_array lm_head embed_top outproj_tile rmsnorm_stage attention_core ffn_tile; do
      run_one_tile "$b" "$tag" || return 1
    done
  fi
  for n in $("$RE_PY" -c "
import sys; sys.path.insert(0, 'weights/bake')
from chunk import parse_layers
print(' '.join(map(str, parse_layers('$layers_spec'))))"); do
    for k in $(seq 0 $((C - 1))); do
      run_one_tile "layer${n}_inproj_c${k}" "$tag" || return 1
    done
  done
  echo "GDS: CHUNKED DONE (C=$C) — slice GDS in src/synth/layer*_inproj_c*/out/$tag/ + tiles/ stitch next"
}

cmd_stitch() {
  export REPO="$ROOT" TILES="${TILES:-$ROOT/tiles}"
  "$RE_KL/klayout" -b -r "$ROOT/tiles/stitch.py" || return 1
}

case "${1:-help}" in
  prereqs) cmd_prereqs ;;
  test)    cmd_test "${2:-all}" ;;
  gds)     shift; cmd_gds "$@" ;;
  stitch)  cmd_stitch ;;
  flow)    shift; "$RE_PY" src/synth/run_librelane.py "$@" || exit 1 ;;
  clean)   make -C src/sim_verilator clean 2>/dev/null; rm -f /tmp/stitch_*.log /tmp/stitch_*.vvp; echo "CLEAN DONE (weights/ and tiles/ untouched)" ;;
  *) sed -n '2,14p' "$0" ;;
esac
