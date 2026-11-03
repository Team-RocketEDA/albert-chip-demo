#!/usr/bin/env python3
"""gen_golden.py — independent pure-stdlib oracle for attention_core stitch.

Oracle sources: baked checkpoint bytes ONLY (weights/bake/tv_{q,k,v,o}_act.hex,
seed 0xB0C1/0xB0C2/0xB0C3/0xB0C4 rows) + baked RoPE tables
(weights/bake/rope_cos.hex, rope_sin.hex, rope_theta 10000.0). The RTL under
test is never consulted. No torch/numpy.

Fixed-point chain mirrored from src/components/attention_core.v (the DUT):
  RoPE  : r0 = clip8(floor((q0*c-q1*s)/4096)), r1 = clip8(floor((q0*s+q1*c)/4096))
  dots  : L[i][j] = exact int sum over 9 Q-heads x mapped KV-head (h//3), 64 dims
  scale : Sc = floor(L/8), saturated to s16 (softmax_d Q4.12 input domain)
  A     : float prefix-softmax over lanes 0..i (causal), code/4096 domain
  Y     : y = clip8(round_half_away(sum_j A[i][j]*V[j][d]))
The DUT's A comes from softmax_d fixed-point (exp_lut + restoring divider,
acceptance 16 LSB Q4.12 per its own tb); the oracle uses float exp/divide, so
the tb compares Y with TOL accounting for that documented budget, plus EXACT
checks (row0 == V row0, causal invariance, frame-reset row) that need no oracle.

Frames (S=4, H=576, KV=192):
  Q rows : tv_q/k/v/o_act (whole 576 B rows)
  K rows : k_act[0:192], k_act[192:384], k_act[384:576], v_act[0:192]
  V rows : v_act[0:192], v_act[192:384], v_act[384:576], k_act[0:192] (A/C)
  frame C: V row3 = o_act[0:192] (causal-invariance probe: rows 0..2 identical)
  frame B: s_cfg=3 (rows 0..2 live, row 3 reads exactly 0)
Outputs (this dir): golden_a.hex, golden_b.hex, golden_c.hex — S*576 s8 bytes,
one 02x value per line, row-major. Run from the repo root:
  python3 src/tb/attention_core_stitch/gen_golden.py
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BAKE = os.path.join(HERE, "..", "..", "..", "weights", "bake")
S, H, KV = 4, 576, 192


def rd_bytes(name):
    out = []
    with open(os.path.join(BAKE, name)) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16))
    return [v - 256 if v >= 128 else v for v in out]


def rd_s16(name):
    out = []
    with open(os.path.join(BAKE, name)) as f:
        for line in f:
            line = line.strip()
            if line:
                v = int(line, 16)
                out.append(v - 65536 if v >= 32768 else v)
    return out


def clip8(x):
    return -128 if x < -128 else (127 if x > 127 else x)


def clip16(x):
    return -32768 if x < -32768 else (32767 if x > 32767 else x)


def rha(x):
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def rope_row(vec, pos, heads, cos, sin):
    out = list(vec)
    for h in range(heads):
        for t in range(32):
            c, s = cos[pos * 32 + t], sin[pos * 32 + t]
            q0 = vec[h * 64 + 2 * t]
            q1 = vec[h * 64 + 2 * t + 1]
            out[h * 64 + 2 * t] = clip8(((q0 * c - q1 * s) // 4096))
            out[h * 64 + 2 * t + 1] = clip8(((q0 * s + q1 * c) // 4096))
    return out


def frame_y(Q, K, V, nrows):
    cos = rd_s16("rope_cos.hex")
    sin = rd_s16("rope_sin.hex")
    assert len(cos) == 2048 and len(sin) == 2048
    Qr = [rope_row(Q[i], i, 9, cos, sin) for i in range(S)]
    Kr = [rope_row(K[i], i, 3, cos, sin) for i in range(S)]
    L = [[0] * S for _ in range(S)]
    for i in range(S):
        for j in range(S):
            t = 0
            for h in range(9):
                kh = h // 3
                for d in range(64):
                    t += Qr[i][h * 64 + d] * Kr[j][kh * 64 + d]
            L[i][j] = t
            assert abs(t) < 2 ** 30, t
    Sc = [[clip16(L[i][j] // 8) for j in range(S)] for i in range(S)]
    Y = [[0] * H for _ in range(S)]
    for i in range(nrows):
        vals = [Sc[i][j] / 4096.0 for j in range(i + 1)]
        m = max(vals)
        es = [math.exp(v - m) for v in vals]
        tot = sum(es)
        for h in range(9):
            kh = h // 3
            for d in range(64):
                yf = sum(es[j] / tot * V[j][kh * 64 + d] for j in range(i + 1))
                Y[i][h * 64 + d] = clip8(rha(yf))
    return Y


def wr(name, Y):
    with open(os.path.join(HERE, name), "w") as f:
        for i in range(S):
            for d in range(H):
                f.write("%02x\n" % (Y[i][d] & 0xFF))


def main():
    qa, ka, va, oa = (rd_bytes("tv_%s_act.hex" % b) for b in "qkvo")
    assert all(len(a) == 576 for a in (qa, ka, va, oa)), "baked acts must be 576 B"
    Q = [qa, ka, va, oa]
    K = [ka[0:192], ka[192:384], ka[384:576], va[0:192]]
    VA = [va[0:192], va[192:384], va[384:576], ka[0:192]]
    VC = [va[0:192], va[192:384], va[384:576], oa[0:192]]
    wr("golden_a.hex", frame_y(Q, K, VA, 4))
    wr("golden_b.hex", frame_y(Q, K, VA, 3))
    wr("golden_c.hex", frame_y(Q, K, VC, 4))
    print("ATTN_GOLDEN wrote golden_a/b/c.hex (%d rows x %d)" % (S, H))


if __name__ == "__main__":
    main()
