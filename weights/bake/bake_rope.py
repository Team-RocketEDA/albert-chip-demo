#!/usr/bin/env python3
"""Bake RoPE sin/cos ROMs (pure stdlib, no checkpoint needed).

Derived from PARAMS: rope_theta 10000.0, head_dim 64 (32 pairs),
positions 0..S-1 (S=64). NOT learned weights — no checkpoint tensor
ships them (HF computes inv_freq at init); the ROM is the hardware
vehicle for the same math.

Layout: row = pos*32 + pair, one value per line, 4 lowercase hex
digits, two's complement Q4.12 (matches bake.py golden convention).
Outputs (gitignored, like all bake artifacts):
  weights/bake/rope_cos.hex, weights/bake/rope_sin.hex (2048 lines each)
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
THETA = 10000.0   # PARAMS section 1 (matches HF config rope_theta)
HEAD_DIM = 64     # PARAMS section 1
POSITIONS = 64    # S: one frame of positions
PAIRS = HEAD_DIM // 2


def q412(x):
    return max(-32768, min(32767, int(round(x * 4096)))) & 0xFFFF


def main():
    cos_rows, sin_rows = [], []
    worst = 0
    for pos in range(POSITIONS):
        for i in range(PAIRS):
            inv_freq = THETA ** (-2.0 * i / HEAD_DIM)
            a = pos * inv_freq
            c, s = math.cos(a), math.sin(a)
            cos_rows.append("%04x" % q412(c))
            sin_rows.append("%04x" % q412(s))
            worst = max(worst, abs(c * c + s * s - 1.0))
    assert len(cos_rows) == POSITIONS * PAIRS
    # pos 0 must be exact identity: cos=1.0 (0x1000), sin=0 (0x0000)
    assert cos_rows[0] == "1000" and sin_rows[0] == "0000", \
        (cos_rows[0], sin_rows[0])
    with open(os.path.join(HERE, "rope_cos.hex"), "w") as f:
        f.write("\n".join(cos_rows) + "\n")
    with open(os.path.join(HERE, "rope_sin.hex"), "w") as f:
        f.write("\n".join(sin_rows) + "\n")
    print("rope_cos.hex rope_sin.hex: %d rows each, worst |c^2+s^2-1| = %.2e"
          % (len(cos_rows), worst))


if __name__ == "__main__":
    main()
