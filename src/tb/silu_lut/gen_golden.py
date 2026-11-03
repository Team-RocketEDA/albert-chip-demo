#!/usr/bin/env python3
"""gen_golden.py — independent pure-stdlib oracle for silu_lut (step 8).

Reads the baked checkpoint vectors (weights/bake/tv_silu_*.txt, the float
SiLU reference from bake.py seed 0xB0CA) plus hand-picked edge cases, and
emits Q4.12 stim/golden hex for tb_silu_lut.v.

Q4.12: signed16, value = code/4096, range [-8.0, +7.99976].
Golden = round-half-away(x*4096) saturated to s16 of the float reference.
Run from the repo root: python3 src/tb/silu_lut/gen_golden.py
"""
import math
import os

Q = 4096
OUT = os.path.join("src", "tb", "silu_lut")
BAKE = os.path.join("weights", "bake")


def q(x):
    v = int(math.floor(x * Q + 0.5)) if x >= 0 else -int(math.floor(-x * Q + 0.5))
    return max(-32768, min(32767, v))


def silu(x):
    return x / (1.0 + math.exp(-x))


def hx(v):
    return "%04x" % (v & 0xFFFF)


def main():
    with open(os.path.join(BAKE, "tv_silu_stim.txt")) as f:
        stim = [float(line) for line in f if line.strip()]
    with open(os.path.join(BAKE, "tv_silu_golden.txt")) as f:
        gold = [float(line) for line in f if line.strip()]
    assert len(stim) == 16 and len(gold) == 16
    pairs = [(q(s), q(g)) for s, g in zip(stim, gold)]
    edges = [-8.0, 8.0 - 1.0 / Q, 0.0, 1.0 / Q, -1.0 / Q,
             -1.278, 2.0, -2.0, 4.0, -4.0]
    for e in edges:
        pairs.append((q(e), q(silu(e))))
    with open(os.path.join(OUT, "stim.hex"), "w") as f:
        f.write("".join(hx(x) + "\n" for x, _ in pairs))
    with open(os.path.join(OUT, "golden.hex"), "w") as f:
        f.write("".join(hx(g) + "\n" for _, g in pairs))
    print("silu goldens: %d vectors (16 baked + 10 edges)" % len(pairs))


if __name__ == "__main__":
    main()
