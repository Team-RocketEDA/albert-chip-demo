#!/usr/bin/env python3
"""Golden generator for sram_1r1w tb (stdlib only).

Oracle: baked checkpoint bytes (weights/bake/layer0_q_proj.hex).
- init.hex: first 64 bytes of the baked q_proj table (DUT INIT_FILE image).
- expected.hex: full 64-byte image after applying the 32 scripted writes.
- writes.txt: human-readable op list (addr dec, data hex).
Deterministic: random.Random(0x51A4); first 4 writes force corner bytes.
"""
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAKE = HERE / "../../../weights/bake/layer0_q_proj.hex"
N = 64
NWrites = 32
SEED = 0x51A4
CORNERS = [0x00, 0x7F, 0x80, 0xFF]

def main():
    raw = BAKE.read_text().split()
    init = [int(x, 16) for x in raw[:N]]
    assert len(init) == N, f"baked table too short: {len(init)}"
    rng = random.Random(SEED)
    addrs = rng.sample(range(N), NWrites)
    datas = CORNERS + [rng.getrandbits(8) for _ in range(NWrites - len(CORNERS))]
    mem = list(init)
    ops = []
    for a, d in zip(addrs, datas):
        mem[a] = d
        ops.append((a, d))
    (HERE / "init.hex").write_text("".join(f"{b:02x}\n" for b in init))
    (HERE / "expected.hex").write_text("".join(f"{b:02x}\n" for b in mem))
    (HERE / "writes.txt").write_text(
        "".join(f"{a} {d:02x}\n" for a, d in ops))
    print(f"sram_1r1w golden: N={N} writes={NWrites} "
          f"init[0]={init[0]:02x} init[63]={init[63]:02x} "
          f"expected[0]={mem[0]:02x} expected[63]={mem[63]:02x}")

if __name__ == "__main__":
    sys.exit(main())
