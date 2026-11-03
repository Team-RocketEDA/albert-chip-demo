#!/usr/bin/env python3
"""Golden generator for embed_lut tb (stdlib only).

Oracle: baked checkpoint bytes in weights/bake/embed_full.hex
(32000x576 int8, one unsigned byte per line, row-major), via direct
byte-offset reads. Never the RTL under test.

Outputs (this dir):
- ids_full.hex      : 8 u15 token ids under test (copy of tv_embed_ids:
                      0,1,2,31999 + 4 seeded draws) as 4-digit hex
- exp_full.hex      : packed expected rows (one 576B row per line,
                      MSB-first: line = byte575..byte0), 8 lines
- dut_init_full.hex : sparse 32000-line packed ROM image for the full
                      DUT (H=576,V=32000): tested rows hold baked bytes,
                      all other rows are zero
- ids_mini.hex / exp_mini.hex / dut_init_mini.hex : same idea for the
                      mini DUT (H=8,V=1024, first 8 bytes of baked rows);
                      ids = 0,1,2,7,100,511,1023 (edges 0 and V-1)

Cross-check: re-extracted rows must equal tv_embed_golden.hex
byte-for-byte (second baked oracle); abort otherwise.
Deterministic: no randomness here (draws were fixed in bake.py).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BAKE = os.path.join(HERE, "..", "..", "..", "weights", "bake")
FULL_HEX = os.path.join(BAKE, "embed_full.hex")
TV_IDS = os.path.join(BAKE, "tv_embed_ids.hex")
TV_GOLD = os.path.join(BAKE, "tv_embed_golden.hex")

H_FULL = 576
V_FULL = 32000
H_MINI = 8
V_MINI = 1024
MINI_IDS = [0, 1, 2, 7, 100, 511, 1023]


def read_row_bytes(f, row, width=H_FULL):
    """Row-major byte lines, 3 chars each ('xx\\n'): seek, no full load."""
    f.seek((row * H_FULL) * 3)
    out = []
    for _ in range(width):
        out.append(int(f.read(2), 16))
        f.read(1)  # newline
    return out


def pack_msb_first(byte_list):
    """Packed $readmemh line so vec[8k+7:8k] == byte k (row[0] low)."""
    return "".join("%02x" % b for b in reversed(byte_list))


def main():
    with open(TV_IDS) as f:
        full_ids = [int(ln.strip(), 16) for ln in f if ln.strip()]
    assert full_ids[0] == 0 and full_ids[3] == 31999, full_ids
    assert len(full_ids) == 8, full_ids

    with open(FULL_HEX, "rb") as f:
        full_rows = [read_row_bytes(f, r) for r in full_ids]

    # Independent cross-check against the second baked oracle.
    with open(TV_GOLD) as f:
        tv_lines = [ln.strip() for ln in f if ln.strip()]
    assert len(tv_lines) == 8 * H_FULL, len(tv_lines)
    for i, row in enumerate(full_rows):
        for k, b in enumerate(row):
            want = int(tv_lines[i * H_FULL + k], 16)
            if b != want:
                print("MISMATCH vs tv_embed_golden: id %d byte %d" % (
                    full_ids[i], k))
                return 1
    print("cross-check: %d rows x %d bytes match tv_embed_golden.hex" % (
        len(full_rows), H_FULL))

    with open(os.path.join(HERE, "ids_full.hex"), "w") as f:
        f.write("".join("%04x\n" % i for i in full_ids))
    with open(os.path.join(HERE, "exp_full.hex"), "w") as f:
        f.write("".join(pack_msb_first(r) + "\n" for r in full_rows))

    full_set = {r: pack_msb_first(row)
                for r, row in zip(full_ids, full_rows)}
    zero_full = "0" * (H_FULL * 2)
    with open(os.path.join(HERE, "dut_init_full.hex"), "w") as f:
        for r in range(V_FULL):
            f.write(full_set.get(r, zero_full) + "\n")

    with open(FULL_HEX, "rb") as f:
        mini_rows = [read_row_bytes(f, r, H_MINI) for r in MINI_IDS]
    with open(os.path.join(HERE, "ids_mini.hex"), "w") as f:
        f.write("".join("%04x\n" % i for i in MINI_IDS))
    with open(os.path.join(HERE, "exp_mini.hex"), "w") as f:
        f.write("".join(pack_msb_first(r) + "\n" for r in mini_rows))
    mini_set = {r: pack_msb_first(row)
                for r, row in zip(MINI_IDS, mini_rows)}
    zero_mini = "0" * (H_MINI * 2)
    with open(os.path.join(HERE, "dut_init_mini.hex"), "w") as f:
        for r in range(V_MINI):
            f.write(mini_set.get(r, zero_mini) + "\n")

    print("full: ids=%s row0[0:3]=%s row31999[0:3]=%s" % (
        full_ids,
        " ".join("%02x" % b for b in full_rows[0][:3]),
        " ".join("%02x" % b for b in full_rows[3][:3])))
    print("mini: ids=%s row1023[0:3]=%s" % (
        MINI_IDS, " ".join("%02x" % b for b in mini_rows[-1][:3])))
    print("wrote ids_full/exp_full/dut_init_full + ids_mini/exp_mini/"
          "dut_init_mini")
    return 0


if __name__ == "__main__":
    sys.exit(main())
