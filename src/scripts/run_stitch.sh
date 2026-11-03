#!/usr/bin/env bash
# run_stitch.sh — run the iverilog-safe stitch testbenches with minimal
# per-DUT compile closures (transitive children only, never the full tree:
# the full MobileLLM-125M tree no longer fits a serial iverilog
# elaboration, so the whole-tree gate lives in Verilator; these closures
# ARE the iverilog gate).
# inproj_tile and loop_top are NOT here: they hang iverilog 14.0-dev
# (0% CPU, order-independent elaborator stall on inproj-inclusive
# closures) and run under Verilator instead (make -C src/sim_verilator
# inproj / top). Run from anywhere; all $readmemh paths resolve from the
# repo root.
# Usage: bash src/scripts/run_stitch.sh [tbname...]   (default: all six)
# Each TB gets 280 s and logs to /tmp/stitch_<name>.log; exit nonzero if any
# selected TB fails to print its PASS verdict.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
C=src/components
T=src/tb
run_one() {
  local name="$1" define="$2" top="$3" pass="$4"
  shift 4
  local log="/tmp/stitch_${name}.log"
  echo "=== ${name} (log ${log})"
  if [ -n "$define" ]; then set -- -g2012 "-D${define}" "$@"; else set -- -g2012 "$@"; fi
  if timeout 280 iverilog "$@" -s "$top" -o "/tmp/stitch_${name}.vvp" >"$log" 2>&1 \
    && timeout 280 vvp "/tmp/stitch_${name}.vvp" >>"$log" 2>&1 \
    && grep -qF "$pass" "$log"; then
    echo "PASS ${name}"
    return 0
  fi
  echo "FAIL ${name} (see ${log})"
  return 1
}
FAIL=0
SEL=("$@")
go() {
  local n="$1"; shift
  if [ ${#SEL[@]} -gt 0 ]; then
    local ok=1
    for w in "${SEL[@]}"; do [ "$w" = "$n" ] && ok=0; done
    [ $ok -eq 0 ] || return 0
  fi
  run_one "$n" "$@" || FAIL=1
}
go embed_top    ""            tb_embed_top_stitch    "EMBED_TOP_STITCH PASS" \
  $C/dff.v $C/fifo_sync.v $C/embed_lut.v $C/sram_1r1w.v $C/seq_fsm.v $C/embed_top.v \
  $T/embed_top_stitch/tb_embed_top_stitch.v
go attention    ""            tb_attention_core_stitch "ATTN_STITCH PASS" \
  $C/attention_core.v $C/div_unit.v $C/exp_lut.v $C/fifo_sync.v $C/mac_array.v $C/softmax_d.v $C/sram_1r1w.v \
  $T/attention_core_stitch/tb_attention_core_stitch.v
go outproj      ""            tb_outproj_tile_stitch "OUTPROJ_STITCH PASS" \
  $C/fifo_sync.v $C/mac_array.v $C/outproj_tile.v $C/regfile_dp.v $C/requant.v $C/seq_fsm.v $C/sram_1r1w.v \
  $T/outproj_tile_stitch/tb_outproj_tile_stitch.v
go rmsnorm      STITCH_YQ     tb_rmsnorm_stage_stitch "RMSNORM_STAGE PASS" \
  $C/requant.v $C/rmsnorm_d.v $C/rmsnorm_stage.v $C/seq_fsm.v $C/sram_1r1w.v \
  $T/rmsnorm_stage_stitch/tb_rmsnorm_stage_stitch.v
go ffn          FFN_IMPL      tb_ffn_tile_stitch      "FFN_TILE_STITCH PASS" \
  $C/ffn_tile.v $C/fifo_sync.v $C/mac_array.v $C/regfile_dp.v $C/requant.v $C/seq_fsm.v $C/silu_lut.v $C/sram_1r1w.v \
  $T/ffn_tile_stitch/tb_ffn_tile_stitch.v
go lm_head      STITCH_LOGITS tb_lm_head_stitch       "LM_HEAD_STITCH PASS" \
  $C/fifo_sync.v $C/lm_head.v $C/mac_array.v $C/seq_fsm.v $C/sram_1r1w.v \
  $T/lm_head_stitch/tb_lm_head_stitch.v
if [ "$FAIL" -ne 0 ]; then echo "STITCH: FAILURES PRESENT"; exit 1; fi
echo "STITCH: ALL SELECTED PASS"
