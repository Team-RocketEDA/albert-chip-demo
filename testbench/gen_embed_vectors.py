#!/usr/bin/env python3
"""gen_embed_vectors.py — stdlib-only stimulus/golden generator for tb_embed.

Tiny deterministic config (V=16, E=8, H=8, S=4, REQ_SHIFT=4); full-size
values (V=30000, E=128, H=768) are the same RTL with parameters changed.
Writes one hex value per line ($readmemh-friendly, unsigned bytes for s8).
"""
import random

V, E, H, S, SHIFT = 16, 8, 8, 4, 4
rng = random.Random(0xA1BE27)


def s8(x):
    x &= 0xFF
    return x - 256 if x >= 128 else x


def u8(x):
    return x & 0xFF


wemb = [[s8(rng.randrange(256)) for _ in range(E)] for _ in range(V)]
wproj = [[s8(rng.randrange(256)) for _ in range(E)] for _ in range(H)]
bias = [s8(rng.randrange(256)) for _ in range(H)]
ids = [rng.randrange(V) for _ in range(S)]


def requant(acc):
    y = acc >> SHIFT  # arithmetic (acc may be negative)
    return max(-128, min(127, y))


golden = []
for i in ids:
    e = wemb[i]
    row = []
    for j in range(H):
        acc = bias[j] + sum(e[k] * wproj[j][k] for k in range(E))
        row.append(requant(acc))
    golden.append(row)

with open("ids.hex", "w") as f:
    f.write("\n".join(f"{i:02x}" for i in ids) + "\n")
with open("wemb.hex", "w") as f:
    f.write("\n".join(f"{u8(x):02x}" for r in wemb for x in r) + "\n")
with open("wproj.hex", "w") as f:
    f.write("\n".join(f"{u8(x):02x}" for r in wproj for x in r) + "\n")
with open("bias.hex", "w") as f:
    f.write("\n".join(f"{u8(x):02x}" for x in bias) + "\n")
with open("golden.hex", "w") as f:
    for row in golden:
        packed = 0
        for x in reversed(row):  # row[0] lands in low byte
            packed = (packed << 8) | u8(x)
        f.write(f"{packed:0{H * 2}x}\n")
print(f"wrote ids/wemb/wproj/bias/golden for V={V} E={E} H={H} S={S}")
