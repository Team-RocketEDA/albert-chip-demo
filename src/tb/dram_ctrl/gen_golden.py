#!/usr/bin/env python3
"""Golden generator for dram_ctrl tb (stdlib only).

Oracle: baked checkpoint bytes (weights/bake/layer0_q_proj.hex).
Packs the first 256 baked bytes into 8 lines x 32 bytes. Each output line
is one 256-bit hex word (64 lowercase chars); byte k of a line maps to
bits [8k+7:8k] (byte0 = LSB), matching dram_ctrl's documented packing.
- dram_init.hex: 8 x 256-bit lines (DUT INIT_FILE image + tb expectation).
Deterministic packing, no randomness needed.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAKE = HERE / "../../../weights/bake/layer0_q_proj.hex"
NLINES = 8
BYTES_PER_LINE = 32

def main():
    raw = BAKE.read_text().split()
    blob = bytes(int(x, 16) for x in raw[:NLINES * BYTES_PER_LINE])
    assert len(blob) == NLINES * BYTES_PER_LINE
    lines = []
    for i in range(NLINES):
        chunk = blob[i * BYTES_PER_LINE:(i + 1) * BYTES_PER_LINE]
        lines.append(int.from_bytes(chunk, "little"))
    (HERE / "dram_init.hex").write_text("".join(f"{v:064x}\n" for v in lines))
    print(f"dram_ctrl golden: lines={NLINES} "
          f"line0={lines[0]:064x} line7={lines[7]:064x}")

if __name__ == "__main__":
    sys.exit(main())
