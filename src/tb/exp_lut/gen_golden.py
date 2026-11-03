#!/usr/bin/env python3
"""gen_golden.py — independent pure-stdlib oracle for exp_lut (step 8).

Softmax max-sub form: d = score - row_max (<= 0 nominally), y = exp(d).
Derives 8 exp points from the baked softmax row (weights/bake/
tv_softmax_stim.txt, seed 0xB0CB) plus hand-picked edge cases, and emits
Q4.12 stim/golden hex for tb_exp_lut.v.

Q4.12: signed16, value = code/4096. Table domain is [-8.0, 0]; positive
inputs cannot occur after max-sub and are a documented clamp to 0x1000
(exp(0) = 1.0), so golden for x > 0 is 0x1000 by contract, not float ideal.
Run from the repo root: python3 src/tb/exp_lut/gen_golden.py
"""
import math
import os

Q = 4096
OUT = os.path.join("src", "tb", "exp_lut")
BAKE = os.path.join("weights", "bake")


def q(x):
    v = int(math.floor(x * Q + 0.5)) if x >= 0 else -int(math.floor(-x * Q + 0.5))
    return max(-32768, min(32767, v))


def hx(v):
    return "%04x" % (v & 0xFFFF)


def main():
    with open(os.path.join(BAKE, "tv_softmax_stim.txt")) as f:
        row = [float(line) for line in f if line.strip()]
    assert len(row) == 8
    mx = max(row)
    pairs = [(q(s - mx), q(math.exp(s - mx))) for s in row]
    edges = [0.0, 1.0 / Q, 0.5, 4.0, -1.0 / 32.0, -1.0,
             -4.0, -7.0, -7.96875, -8.0]
    for e in edges:
        if e > 0.0:
            pairs.append((q(e), 0x1000))  # positive clamp by contract
        else:
            pairs.append((q(e), q(math.exp(e))))
    with open(os.path.join(OUT, "stim.hex"), "w") as f:
        f.write("".join(hx(x) + "\n" for x, _ in pairs))
    with open(os.path.join(OUT, "golden.hex"), "w") as f:
        f.write("".join(hx(g) + "\n" for _, g in pairs))
    print("exp goldens: %d vectors (8 baked + 10 edges)" % len(pairs))


if __name__ == "__main__":
    main()
