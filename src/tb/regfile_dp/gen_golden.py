#!/usr/bin/env python3
"""Golden generator for regfile_dp tb (stdlib only).

Oracle: baked checkpoint bytes (weights/bake/layer0_q_proj.hex).
Packs the first 256 baked bytes little-endian into 64 x 32-bit words.
- init.hex: 64 words, 08x lowercase (DUT INIT_FILE image).
- expected.hex: full image after the 16 scripted writes.
- writes.txt: human-readable op list (addr dec, data 08x).
Deterministic: random.Random(0x861F); first 4 writes force 32-bit corners.
"""
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAKE = HERE / "../../../weights/bake/layer0_q_proj.hex"
N = 64
NWrites = 16
SEED = 0x861F
CORNERS = [0x00000000, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF]

def main():
    raw = BAKE.read_text().split()
    blob = bytes(int(x, 16) for x in raw[:4 * N])
    assert len(blob) == 4 * N
    init = [int.from_bytes(blob[i * 4:(i + 1) * 4], "little") for i in range(N)]
    rng = random.Random(SEED)
    addrs = rng.sample(range(N), NWrites)
    datas = CORNERS + [rng.getrandbits(32) for _ in range(NWrites - len(CORNERS))]
    mem = list(init)
    ops = []
    for a, d in zip(addrs, datas):
        mem[a] = d & 0xFFFFFFFF
        ops.append((a, d & 0xFFFFFFFF))
    (HERE / "init.hex").write_text("".join(f"{w:08x}\n" for w in init))
    (HERE / "expected.hex").write_text("".join(f"{w:08x}\n" for w in mem))
    (HERE / "writes.txt").write_text(
        "".join(f"{a} {d:08x}\n" for a, d in ops))
    print(f"regfile_dp golden: N={N} writes={NWrites} "
          f"init[0]={init[0]:08x} init[63]={init[63]:08x} "
          f"expected[0]={mem[0]:08x} expected[63]={mem[63]:08x}")

if __name__ == "__main__":
    sys.exit(main())
