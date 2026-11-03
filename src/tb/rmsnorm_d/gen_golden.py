#!/usr/bin/env python3
"""gen_golden.py — stimulus emitter + oracle cross-check for rmsnorm_d.

Oracle is ALWAYS the baked checkpoint bytes (weights/bake/tv_rmsnorm_*,
seed 0xB0C9, resid=0, eps=1e-5, gamma=baked dequant); this script never
replaces them. It (1) independently re-derives the golden from the baked
int8 input + baked int8 gamma + baked scale to cross-check the
understood format (Q8.8 out, round-half-away), and (2) emits the Q8.8
stimulus the DUT port format needs (x = s8<<8 exact per PARAMS boundary
rule, gamma = round(g*256)).

Run from the repo root: python3 src/tb/rmsnorm_d/gen_golden.py
"""
import json
import math
import os

BAKE = os.path.join("weights", "bake")
OUT = os.path.join("src", "tb", "rmsnorm_d")


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

    # Independent re-derivation of the baked golden (float RMSNorm).
    g = [q * scale for q in gq]
    ms = sum(float(x) ** 2 for x in rin) / 576.0
    rlen = math.sqrt(ms + 1e-5)
    re = [q88_round((float(x) / rlen) * gv) for x, gv in zip(rin, g)]
    bad = [(i, a, b) for i, (a, b) in enumerate(zip(re, gold)) if a != b]
    assert not bad, "oracle cross-check failed at %s" % bad[:4]
    print("oracle cross-check: 576/576 golden lanes match baked bytes")

    # DUT stimulus in port format (Q8.8): x exact, gamma rounded.
    g16 = [min(32767, max(-32768, q88_round(gv))) for gv in g]
    assert all(-32768 <= v <= 32767 for v in g16)
    with open(os.path.join(OUT, "stim_x.hex"), "w") as f:
        f.write("".join(hx16((x * 256) & 0xFFFF) + "\n" for x in rin))
    with open(os.path.join(OUT, "stim_g.hex"), "w") as f:
        f.write("".join(hx16(v) + "\n" for v in g16))
    print("stimulus: %d x lanes + %d gamma lanes (Q8.8)" % (len(rin), len(g16)))

    # Phase-D saturation corner: lane0 x=resid=0x7000 (sum saturates to
    # 0x7fff per the t = sat16(x+resid) contract), rest zero, gamma=1.0.
    # Golden is plain float RMSNorm over the saturated lane values.
    dx = [0x7000] + [0] * 575
    dr = [0x7000] + [0] * 575
    dt = [min(a + b, 0x7FFF) for a, b in zip(dx, dr)]
    msd = sum((float(t) / 256.0) ** 2 for t in dt) / 576.0
    rd = math.sqrt(msd + 1e-5)
    with open(os.path.join(OUT, "stim_d_x.hex"), "w") as f:
        f.write("".join(hx16(v) + "\n" for v in dx))
    with open(os.path.join(OUT, "stim_d_r.hex"), "w") as f:
        f.write("".join(hx16(v) + "\n" for v in dr))
    with open(os.path.join(OUT, "stim_d_g.hex"), "w") as f:
        f.write("".join(hx16(0x0100) + "\n" for _ in range(576)))
    with open(os.path.join(OUT, "gold_d.hex"), "w") as f:
        f.write("".join(hx16(q88_round((float(t) / 256.0) / rd) & 0xFFFF)
                        + "\n" for t in dt))
    print("phase-D saturation vectors: lane0 t=0x7fff, golden emitted")


if __name__ == "__main__":
    main()
