# attention_core stitch test

Stitch test for `src/components/attention_core.v`
(contract: `architecture/blocks/03-attention-core.md` item 4).

## Files

- `gen_golden.py` — pure-stdlib oracle (no torch/numpy, RTL never
  consulted). Bakes `golden_a/b/c.hex` from `weights/bake/tv_q/k/v/o_act.hex`
  + `rope_cos/sin.hex`. Fixed-point chain mirrors the DUT bit-exactly
  (RoPE floor + clip8, exact QK dots, `L//8` floor, s16 saturate); only the
  softmax exp/divide and final rounding use float (`round_half_away`).
- `golden_a/b/c.hex` — S=4 x 576 s8 bytes, one `02x` value per line.
  Frame A full (`s_cfg=4`); B partial (`s_cfg=3`, row 3 reads 0);
  C full with V row 3 swapped (`tv_o_act` low third).
- `tb_attention_core_stitch.v` — self-checking tb (S=4). Checks: reset
  (`y_valid=0`, no floats), frame A vs golden (TOL=6) + exact row 0
  (`A[0]=[1,0..]` so `Y[0]` fans out `V[0]` byte-exact through GQA),
  frame B rows 0..2 + exact zero row 3, frame C rows 0..2 bit-identical
  to A (causal invariance) + exact row 0 (proves the frame-start
  `row_q` reset after partial B — the known integration trap).
- `formal:dropped(depth=12, engine=smtbmc/boolector)` — a BMC control-safety
  attempt (accept->busy, accept->softmax-reset, y_valid->ready) did not
  converge: yosys `prep` alone exceeds the ~120s budget (this yosys
  stores `read -formal` modules as `$abstract\…`, so the `blackbox`
  leaf selection silently misses and `prep` bit-blasts the 64Kb staging
  SRAMs + full S=4 RoPE/QK datapath). Sim covers the wiring; the
  frame-start reset is instead proven by the frame-B->C exact row-0 test.

## Run (from repo root)

RED (skeleton): tb FAILs (undriven `y_out`/`y_valid`/`qkv_ready`).
GREEN: `ATTN_STITCH PASS (frames A/B/C, S=4, tol=6)`.

```sh
python3 src/tb/attention_core_stitch/gen_golden.py
iverilog -o /tmp/tb_attn_stitch src/components/attention_core.v \
  src/components/sram_1r1w.v src/components/mac_array.v \
  src/components/softmax_d.v src/components/div_unit.v \
  src/components/exp_lut.v src/components/fifo_sync.v \
  src/tb/attention_core_stitch/tb_attention_core_stitch.v \
  && vvp /tmp/tb_attn_stitch
iverilog -tnull -o /dev/null src/components/*.v   # elab gate
```
