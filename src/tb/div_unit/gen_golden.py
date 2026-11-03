#!/usr/bin/env python3
"""gen_golden.py — independent pure-stdlib oracle for div_unit (step 11).

Contract (matches src/components/div_unit.v):
  unsigned floor division, single-shot protocol
    quot = 0xFFFF... (saturate) when denom == 0
    quot = numer // denom          otherwise
  Bit-exact (0 ulp); the "1-ulp-ish bound per PARAMS" is met with zero error.

Vector groups (deterministic; seed recorded below):
  D  directed corners: numer/denom corner cross product (0, 1, small,
     16-bit rails, 32-bit rails, numer<denom -> 0, numer==denom -> 1,
     denom == 0 -> saturate).
  R  randomized pairs from random.Random(0xD1V), denom classes mixed
     (zero / small / full-range) to stress large quotients.
  B1 baked softmax reciprocal (weights/bake/tv_softmax_stim.txt, seed
     0xB0CB): denom S = sum of Q4.12 round-half-away exp(score - max)
     (the exp_lut output image, 8 lanes); numer = 2^31, i.e. the
     softmax_d u_recip wiring (numer = 1.0 = 2^(W-1)) evaluated at W=32.
  B2 baked norm mean (weights/bake/tv_rmsnorm_in.hex, 576 codes, seed
     0xB0C9): numer = sum of squared raw codes, denom = 576 = D, i.e.
     the MEAN_SUM_DIV reduction shape from 05 (mean of squares).
  B3 W=16 recip-lane vectors (softmax_d operating point W=16):
     numer = 0x8000 = 2^15, denoms = {S_baked, 1, 2, 0xFFFF, 0}.

Outputs (this dir, $readmemh-ready): stim_numer.hex, stim_denom.hex,
golden.hex (08x u32, N vectors), stim16_numer.hex, stim16_denom.hex,
golden16.hex (04x u16, M vectors), manifest.txt.
Run from the repo root: python3 src/tb/div_unit/gen_golden.py
"""
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
BAKE = os.path.join(HERE, "..", "..", "..", "weights", "bake")

SEED_R = 0xD17
Q412 = 4096


def qref(numer, denom, w):
    """Independent oracle: saturate on divide-by-zero, else floor."""
    if denom == 0:
        return (1 << w) - 1
    return numer // denom


def hx(v, w):
    return "%0*x" % (w // 4, v & ((1 << w) - 1))


def rha(x):
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def main():
    pairs32 = []  # (numer, denom, tag)

    # ---- group D: directed corners ----
    num_c = [0, 1, 2, 3, 255, 256, 65535, 65536,
             2 ** 31 - 1, 2 ** 31, 2 ** 32 - 2, 2 ** 32 - 1]
    den_c = [0, 1, 2, 3, 4, 255, 256, 257, 65535, 65536,
             2 ** 31 - 1, 2 ** 31, 2 ** 32 - 1]
    for n in num_c:
        for d in [0, 1, 2, 255, 65536, 2 ** 32 - 1]:
            pairs32.append((n, d, "D"))
    for d in den_c:
        for n in [0, 1, 255, 2 ** 31, 2 ** 32 - 1]:
            pairs32.append((n, d, "D"))
    # numer<denom -> 0 and numer==denom -> 1 (directed, not covered above)
    pairs32 += [(5, 17, "D"), (100, 101, "D"), (2 ** 31, 2 ** 32 - 1, "D"),
                (7, 7, "D"), (2 ** 32 - 1, 2 ** 32 - 1, "D"), (0, 0, "D")]

    # ---- group R: seeded random ----
    rng = random.Random(SEED_R)
    for i in range(32):
        n = rng.getrandbits(32)
        cls = i % 4
        if cls == 0:
            d = rng.getrandbits(32)
        elif cls == 1:
            d = rng.getrandbits(8)  # small denom, large quotient
        elif cls == 2:
            d = rng.getrandbits(16) | 1  # nonzero 16-bit
        else:
            d = 0 if i % 8 == 7 else rng.getrandbits(32)
        pairs32.append((n, d, "R"))

    # ---- group B1: baked softmax reciprocal ----
    with open(os.path.join(BAKE, "tv_softmax_stim.txt")) as f:
        row = [float(ln) for ln in f if ln.strip()]
    assert len(row) == 8, "expected 8-lane baked softmax row"
    mx = max(row)
    exps = [min(Q412, max(1, rha(math.exp(s - mx) * Q412))) for s in row]
    s_baked = sum(exps)
    assert s_baked > 0
    pairs32.append((2 ** 31, s_baked, "B1"))

    # ---- group B2: baked norm mean (MEAN_SUM_DIV shape) ----
    with open(os.path.join(BAKE, "tv_rmsnorm_in.hex")) as f:
        codes = [int(ln.strip(), 16) for ln in f if ln.strip()]
    assert len(codes) == 576, "expected D=576 baked rmsnorm codes"
    sq_sum = sum(c * c for c in codes)
    assert sq_sum < 2 ** 32
    pairs32.append((sq_sum, 576, "B2"))

    # dedup preserving order
    seen, uniq32 = set(), []
    for p in pairs32:
        if (p[0], p[1]) not in seen:
            seen.add((p[0], p[1]))
            uniq32.append(p)

    # ---- group B3: W=16 recip lane (softmax_d operating point) ----
    pairs16 = [(0x8000, s_baked & 0xFFFF, "B3"),
               (0x8000, 1, "B3"), (0x8000, 2, "B3"),
               (0x8000, 0xFFFF, "B3"), (0x8000, 0, "B3"),
               (0x1234, 0x5678, "B3"), (0xFFFF, 0xFFFF, "B3"),
               (0x0001, 0xFFFF, "B3")]

    gold32 = [qref(n, d, 32) for n, d, _ in uniq32]
    gold16 = [qref(n, d, 16) for n, d, _ in pairs16]

    # exactness audit: oracle IS floor-division, so max abs err is 0 by
    # construction; assert it rather than reporting a float tolerance.
    for (n, d, t), g in zip(uniq32, gold32):
        assert g == ((1 << 32) - 1 if d == 0 else n // d), t
    for (n, d, t), g in zip(pairs16, gold16):
        assert g == ((1 << 16) - 1 if d == 0 else n // d), t

    with open(os.path.join(HERE, "stim_numer.hex"), "w") as f:
        f.write("".join(hx(n, 32) + "\n" for n, _, _ in uniq32))
    with open(os.path.join(HERE, "stim_denom.hex"), "w") as f:
        f.write("".join(hx(d, 32) + "\n" for _, d, _ in uniq32))
    with open(os.path.join(HERE, "golden.hex"), "w") as f:
        f.write("".join(hx(g, 32) + "\n" for g in gold32))
    with open(os.path.join(HERE, "stim16_numer.hex"), "w") as f:
        f.write("".join(hx(n, 16) + "\n" for n, _, _ in pairs16))
    with open(os.path.join(HERE, "stim16_denom.hex"), "w") as f:
        f.write("".join(hx(d, 16) + "\n" for _, d, _ in pairs16))
    with open(os.path.join(HERE, "golden16.hex"), "w") as f:
        f.write("".join(hx(g, 16) + "\n" for g in gold16))
    with open(os.path.join(HERE, "vec_count.hex"), "w") as f:
        f.write(hx(len(uniq32), 32) + "\n")
    with open(os.path.join(HERE, "vec16_count.hex"), "w") as f:
        f.write(hx(len(pairs16), 32) + "\n")
    with open(os.path.join(HERE, "manifest.txt"), "w") as f:
        f.write("seed_random=0x%X n32=%d m16=%d\n" % (SEED_R, len(uniq32),
                                                      len(pairs16)))
        f.write("baked_softmax_S=%d baked_softmax_rowmax=%r\n"
                % (s_baked, mx))
        f.write("baked_rmsnorm_sqsum=%d baked_rmsnorm_n=%d\n"
                % (sq_sum, len(codes)))
        f.write("max_abs_err_vs_floor_div=0 (bit-exact, 0 ulp)\n")
    print("div goldens: %d x W=32 + %d x W=16 vectors (S_baked=%d sq_sum=%d)"
          % (len(uniq32), len(pairs16), s_baked, sq_sum))


if __name__ == "__main__":
    main()
