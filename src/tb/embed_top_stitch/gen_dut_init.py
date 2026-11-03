#!/usr/bin/env python3
"""Sparse packed ROM image for the embed_top stitch tb (stdlib only).

Oracle: weights/bake/tv_embed_ids.hex (8x u15) + tv_embed_golden.hex
(8x576 s8 bytes, one unsigned byte per line, row-major in id order).

Output (this dir): dut_init.hex — 32000 packed $readmemh lines for
embed_lut (H=576, V=32000): the 8 tv rows hold baked bytes MSB-first so
vec[8k+7:8k] == row byte k; all other rows are zero.

Sparse-vs-full note: only the 8 tv rows have an oracle, so only they are
backed. Out-of-range ids (>= V) read zero by LUT construction regardless
of init; unprogrammed in-range rows read zero under THIS image (a full
32000-row packed image is a mechanical extension of this script).
Deterministic: no randomness.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BAKE = os.path.join(HERE, "..", "..", "..", "weights", "bake")
TV_IDS = os.path.join(BAKE, "tv_embed_ids.hex")
TV_GOLD = os.path.join(BAKE, "tv_embed_golden.hex")
OUT = os.path.join(HERE, "dut_init.hex")

H = 576
V = 32000


def main():
    with open(TV_IDS) as f:
        ids = [int(ln.strip(), 16) for ln in f if ln.strip()]
    assert len(ids) == 8, ids
    assert ids[0] == 0 and ids[3] == 31999, ids
    with open(TV_GOLD) as f:
        gbytes = [int(ln.strip(), 16) for ln in f if ln.strip()]
    assert len(gbytes) == 8 * H, len(gbytes)
    rows = {}
    for i, tok in enumerate(ids):
        row = gbytes[i * H:(i + 1) * H]
        rows[tok] = "".join("%02x" % b for b in reversed(row))
    zero = "0" * (H * 2)
    with open(OUT, "w") as f:
        for r in range(V):
            f.write(rows.get(r, zero) + "\n")
    print("dut_init.hex: %d rows backed (ids=%s)" % (len(rows), ids))
    print("row0[0:3]=%s row31999[0:3]=%s" % (
        " ".join("%02x" % b for b in gbytes[0:3]),
        " ".join("%02x" % b for b in gbytes[3 * H:3 * H + 3])))


if __name__ == "__main__":
    main()
