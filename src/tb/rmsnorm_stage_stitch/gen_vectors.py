#!/usr/bin/env python3
"""gen_vectors.py — rmsnorm_stage stitch vectors (pure stdlib, no torch/numpy).

Oracle is ALWAYS the baked checkpoint bytes (weights/bake/tv_rmsnorm_*);
this script never replaces them. It emits, into this tb dir:

1. gamma_q88.hex  — 576 x Q8.8 gamma lanes for the stage's weight-stationary
   regfile, from baked int8 layer0_input_layernorm + its baked absmax scale
   (same derivation as src/tb/rmsnorm_d/gen_golden.py: gamma = round(g*256)).
2. sat_row_golden.hex — 576 x Q8.8 golden for the tb saturation corner:
   row0 lane0 x=resid=0x7F (s8 max) so t = sat16(0x7F00+0x7F00) = 0x7FFF,
   all other lanes x=resid=0, real weight-stationary gamma (same
   gamma_q88.hex the DUT loads). Golden is float RMSNorm over the
   saturated t lanes (round-half-away to Q8.8). A missing/wrong sat16 in
   either the stage resid path or rmsnorm_d flips lane0 wildly.

Run from the repo root: python3 src/tb/rmsnorm_stage_stitch/gen_vectors.py
"""
import json
import math
import os

BAKE = os.path.join("weights", "bake")
OUT = os.path.join("src", "tb", "rmsnorm_stage_stitch")


def s8(v):
    return v - 256 if v > 127 else v


def q88_round(x):
    return int(math.floor(x * 256.0 + 0.5)) if x >= 0 else \
        -int(math.floor(-x * 256.0 + 0.5))


def hx16(v):
    return "%04x" % (v & 0xFFFF)


def main():
    rin = [s8(int(l.strip(), 16))
           for l in open(os.path.join(BAKE, "tv_rmsnorm_in.hex"))]
    gq = [s8(int(l.strip(), 16))
          for l in open(os.path.join(BAKE, "layer0_input_layernorm.hex"))]
    gold = [int(l.strip(), 16)
            for l in open(os.path.join(BAKE, "tv_rmsnorm_golden.hex"))]
    gold = [v - 65536 if v > 32767 else v for v in gold]
    assert len(rin) == 576 and len(gq) == 576 and len(gold) == 576
    scale = json.load(open(os.path.join(BAKE, "scales_baked.json")))[
        "tensors"]["model.layers.0.input_layernorm.weight"]["scales"][0]

    # Cross-check the understood gamma format against the baked golden.
    g = [q * scale for q in gq]
    ms = sum(float(x) ** 2 for x in rin) / 576.0
    rlen = math.sqrt(ms + 1e-5)
    re = [q88_round((float(x) / rlen) * gv) for x, gv in zip(rin, g)]
    bad = [(i, a, b) for i, (a, b) in enumerate(zip(re, gold)) if a != b]
    assert not bad, "oracle cross-check failed at %s" % bad[:4]
    print("oracle cross-check: 576/576 golden lanes match baked bytes")

    g16 = [min(32767, max(-32768, q88_round(gv))) for gv in g]
    with open(os.path.join(OUT, "gamma_q88.hex"), "w") as f:
        f.write("".join(hx16(v) + "\n" for v in g16))
    print("gamma_q88.hex: %d Q8.8 lanes" % len(g16))

    # Saturation corner: t lanes post-sat16 (lane0 clamped to 0x7FFF).
    # Golden models the QUANTIZED hardware path (g16/256, the same
    # gamma_q88.hex bytes the DUT loads) — never float g, never 1.0 —
    # so the corner checks the stage exactly, like phase A checks gold.
    gq16 = [v / 256.0 for v in g16]
    dt = [min(0x7F00 + 0x7F00, 0x7FFF)] + [0] * 575
    assert dt[0] == 0x7FFF
    msd = sum((float(t) / 256.0) ** 2 for t in dt) / 576.0
    rd = math.sqrt(msd + 1e-5)
    sat = [q88_round((float(t) / 256.0) / rd * gv)
           for t, gv in zip(dt, gq16)]
    with open(os.path.join(OUT, "sat_row_golden.hex"), "w") as f:
        f.write("".join(hx16(v & 0xFFFF) + "\n" for v in sat))
    print("sat_row_golden.hex: lane0 t=0x7fff golden emitted (real gamma)")


if __name__ == "__main__":
    main()
