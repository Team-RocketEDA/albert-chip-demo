#!/usr/bin/env python3
"""Tiny full-chain FFN golden generator (ffn_tile regression collateral).

Dims S=1,H=64,FF=16 (seed 0xF71E): random int8 X/Wg/Wu/Wd plus the exact
bit-model of the ffn_tile fixed-point chain, so tb_ffn_wbind.v can check
every y byte without a full-dim run:

  gate[j] = sum_k X[k]*Wg[j][k]            (exact, python ints)
  gq = sat_s16(floor(gate/4))              (>>>2 then saturate)
  sg = silu_lut(gq)                        (table+interp parsed from
                                            src/components/silu_lut.v)
  uq = sat_s16(floor(up/4))
  prod = sg*uq (signed 16x16); h = sat_s8(floor(prod/2^20))
  Yacc[i] = sum_j h[j]*Wd[i][j]
  y[i] = sat_s8(floor(Yacc/64))            (requant scale=1 SHIFT=6)

Layouts mirror the bake (row-major, one %02x byte per line).

Usage: python3 src/tb/ffn_tile_stitch/gen_tiny.py   (run from repo root)
Output: src/tb/ffn_tile_stitch/tiny_{x,wg,wu,wd,y}.hex (committed).
"""

import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
SILU = os.path.join(ROOT, "src", "components", "silu_lut.v")

S, H, FF = 1, 64, 16
SEED = 0xF71E


def sat(v, lo, hi):
    """Saturate v into [lo,hi]."""
    return lo if v < lo else hi if v > hi else v


def load_silu_rom(path):
    """Parse rom[N]=16'hXXXX entries from silu_lut.v into s16 ints."""
    rom = {}
    pat = re.compile(r"rom\[(\d+)\]=16'h([0-9a-fA-F]{4})")
    with open(path) as f:
        for line in f:
            for m in pat.finditer(line):
                v = int(m.group(2), 16)
                rom[int(m.group(1))] = v - 65536 if v >= 32768 else v
    assert len(rom) == 1024, "want 1024 rom entries, got %d" % len(rom)
    return [rom[i] for i in range(1024)]


ROM = load_silu_rom(SILU)
TOP = 0x7FF5


def silu(x):
    """Bit-model of silu_lut.v (offset-binary idx, half-up interp)."""
    xb = (x + 32768) & 0xFFFF
    idx, frac = xb >> 6, xb & 63
    y0 = ROM[idx]
    y1 = ROM[idx + 1] if idx != 1023 else TOP
    qterm = (y1 - y0) * frac
    qterm = (qterm + 32) // 64  # >>>6 floors; +32 rounds half-up
    return sat(y0 + qterm, -32768, 32767)


def b(v):
    """Byte hex line for signed int8 v."""
    return "%02x\n" % (v & 0xFF)


def main():
    """CLI entry point (see module docstring for usage)."""
    rng = random.Random(SEED)
    X = [rng.randint(-127, 127) for _ in range(H)]
    X[0], X[1] = 127, -128
    Wg = [[rng.randint(-127, 127) for _ in range(H)] for _ in range(FF)]
    Wu = [[rng.randint(-127, 127) for _ in range(H)] for _ in range(FF)]
    Wd = [[rng.randint(-127, 127) for _ in range(FF)] for _ in range(H)]
    Wg[0][0], Wu[0][1], Wd[0][0] = 127, -128, 127

    gate = [sum(X[k] * Wg[j][k] for k in range(H)) for j in range(FF)]
    up = [sum(X[k] * Wu[j][k] for k in range(H)) for j in range(FF)]
    h = []
    for j in range(FF):
        gq = sat(gate[j] // 4, -32768, 32767)
        uq = sat(up[j] // 4, -32768, 32767)
        prod = silu(gq) * uq
        h.append(sat(prod // (1 << 20), -128, 127))
    Yacc = [sum(h[j] * Wd[i][j] for j in range(FF)) for i in range(H)]
    y = [sat(a // 64, -128, 127) for a in Yacc]

    outs = {
        "tiny_x.hex": [b(v) for v in X],
        "tiny_wg.hex": [b(v) for row in Wg for v in row],
        "tiny_wu.hex": [b(v) for row in Wu for v in row],
        "tiny_wd.hex": [b(v) for row in Wd for v in row],
        "tiny_y_golden.hex": [b(v) for v in y],
    }
    for name, lines in outs.items():
        with open(os.path.join(HERE, name), "w") as f:
            f.writelines(lines)
    print("tiny ffn goldens (S=%d,H=%d,FF=%d,seed=0x%X) -> %s"
          % (S, H, FF, SEED, HERE))
    return 0


if __name__ == "__main__":
    sys.exit(main())
