#!/usr/bin/env python3
"""gen_golden.py — independent pure-stdlib oracle for softmax_d (step 9).

Oracle sources: baked checkpoint floats ONLY (weights/bake/tv_softmax_stim.txt,
seed 0xB0CB) + deterministic LCG rows + directed edges. The RTL under test is
never consulted. No torch/numpy.

Fixed-point contract (mirrors src/components/softmax_d.v):
  scores/probs Q4.12 signed16 (code/4096, range [-8.0, +7.99976]).
  p_j = exp(s_j - max) / sum(exp(s_k - max))   (float reference)
  golden_q = round_half_away(p_j * 4096), saturated to s16.
  Rows are consumed in order; internal row index = accepts-since-reset mod S.
  causal=1 masks lane j > row (masked lanes get exactly 0, max/sum skip them);
  causal=0 masks nothing.
  golden.hex        = plain softmax of each stim row (causal=0 pass).
  golden_causal.hex = softmax over unmasked prefix lanes 0..(i mod S) of each
                      stim row, zeros past the prefix (causal=1 pass).

Run from the repo root: python3 src/tb/softmax_d/gen_golden.py
"""
import math
import os

Q = 4096
S = 8
N = 24
OUT = os.path.join("src", "tb", "softmax_d")
BAKE = os.path.join("weights", "bake")


def q(x):
    v = int(math.floor(x * Q + 0.5)) if x >= 0 else -int(math.floor(-x * Q + 0.5))
    return max(-32768, min(32767, v))


def hx(v):
    return "%04x" % (v & 0xFFFF)


def softmax(row):
    mx = max(row)
    es = [math.exp(s - mx) for s in row]
    t = sum(es)
    return [e / t for e in es]


def main():
    with open(os.path.join(BAKE, "tv_softmax_stim.txt")) as f:
        baked = [float(line) for line in f if line.strip()]
    assert len(baked) == 8, baked

    rows = [list(baked)]
    # Deterministic LCG rows in [-4, +4): uniform-ish coverage, no RNG module.
    x = 0xB0CB
    while len(rows) < N - 5:
        r = []
        for _ in range(S):
            x = (1103515245 * x + 12345) & 0x7FFFFFFF
            r.append((x / 0x80000000) * 8.0 - 4.0)
        rows.append(r)
    # Directed edges.
    rows.append([0.5] * S)                                  # uniform
    rows.append([3.0] + [-8.0] * (S - 1))                   # one-hot-ish
    rows.append([-8.0] * S)                                 # all floor
    rows.append([7.99, -7.99, 0.0, 1.0, -1.0, 4.0, -4.0, 2.0])  # extremes
    rows.append([0.21205892, -1.166105, 3.2342671, -2.8358002,
                 0.41480142, -3.7136109, -1.7614301, -1.2547841])  # shuffle
    assert len(rows) == N

    stim = [[q(s) for s in r] for r in rows]
    gold = [[q(p) for p in softmax(r)] for r in rows]
    causal = []
    for i, r in enumerate(rows):
        a = i % S
        pre = softmax(r[:a + 1])
        causal.append([q(pre[j]) if j <= a else 0 for j in range(S)])
    # Row-sum sanity of the oracle itself (float ideal sums to 1.0).
    worst = max(abs(sum(r) - 1.0) for r in
                ([softmax(r) for r in rows]))
    print("oracle float row-sum worst dev: %.3e" % worst)

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "stim.hex"), "w") as f:
        for r in stim:
            f.write("".join(hx(v) + "\n" for v in r))
    with open(os.path.join(OUT, "golden.hex"), "w") as f:
        for r in gold:
            f.write("".join(hx(v) + "\n" for v in r))
    with open(os.path.join(OUT, "golden_causal.hex"), "w") as f:
        for r in causal:
            f.write("".join(hx(v) + "\n" for v in r))
    with open(os.path.join(OUT, "vec_count.hex"), "w") as f:
        f.write("%08x\n" % N)
    with open(os.path.join(OUT, "manifest.txt"), "w") as f:
        f.write("softmax_d goldens: N=%d rows x S=%d (row0 baked seed 0xB0CB, "
                "LCG rows, 5 directed edges)\n" % (N, S))
        f.write("Q4.12 round-half-away; golden_causal row i = prefix softmax "
                "over lanes 0..%d\n" % (S - 1))
    print("softmax goldens: %d rows x S=%d (stim/golden/golden_causal.hex)" % (N, S))


if __name__ == "__main__":
    main()
