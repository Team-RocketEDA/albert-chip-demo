#!/usr/bin/env python3
"""Pack byte-per-line bake hex into wide-bank SRAM images.

Wide SRAM banks (W-bit rows, e.g. outproj 256-bit rows = 32 K-bytes per
row) need one W-bit word per $readmemh line. This packs row-major byte
tables into wide lines: wide row (r, c) covers bytes [r*C + c*W,
r*C + (c+1)*W), zero-padded per row when C % W != 0, so every source
row starts at a line boundary and bank address math stays exact.

Usage:
  python3 weights/bake/pack.py --in layer0_o_proj.hex --rows 576 \\
      --cols 576 --wide 32 --out layer0_o_proj_w32.hex
  python3 weights/bake/pack.py --all [--layers 0-29] [--pt]
      # packs q/k/v/o (the wide-bank tables) for the layer set; --pt
      # reads the per-tensor layerN_*_pt.hex sources (calibrated path)
      # into the same _w32.hex bank images (generated exhaust).

Outputs: weights/bake/<stem>_w32.hex (gitignored exhaust, like the bake).
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# (stem, rows, cols): the wide-bank tables (byte banks keep byte hex).
WIDE_TABLES = [
    ("q_proj", 576, 576),
    ("k_proj", 192, 576),
    ("v_proj", 192, 576),
    ("o_proj", 576, 576),
]

WIDE = 32


def pack(src, rows, cols, wide, dest):
    """Pack one byte table into wide lines.

    Args:
        src: Source byte-hex path (rows*cols lines).
        rows: Table rows.
        cols: Table columns (bytes per row).
        wide: Bytes per output line.
        dest: Output wide-hex path.

    Raises:
        ValueError: If the source line count mismatches rows*cols.
    """
    with open(src) as f:
        lines = [l.strip() for l in f]
    if len(lines) != rows * cols:
        raise ValueError("%s: %d lines, want %d" % (src, len(lines),
                                                    rows * cols))
    per = (cols + wide - 1) // wide
    out = []
    for r in range(rows):
        row = lines[r * cols:(r + 1) * cols]
        row += ["00"] * (per * wide - cols)
        for c in range(per):
            # Reversed within the line: lane li reads wrow[li*8+:8]
            # (LSB-first), so table byte 0 lands on the line's LAST
            # hex pair ($readmemh takes the line MSB-first).
            out.append("".join(reversed(row[c * wide:(c + 1) * wide])) + "\n")
    with open(dest, "w") as f:
        f.writelines(out)
    return dest


def main(argv):
    """CLI entry point (see module docstring for usage)."""
    if "--all" in argv:
        # Local import: chunk.py imports pack (cycle-safe this way).
        sys.path.insert(0, HERE)
        from chunk import parse_layers
        layers = list(range(30))
        if "--layers" in argv:
            layers = parse_layers(argv[argv.index("--layers") + 1])
        use_pt = "--pt" in argv
        n = 0
        for layer in layers:
            for stem, rows, cols in WIDE_TABLES:
                src = "layer%d_%s%s.hex" % (layer, stem,
                                            "_pt" if use_pt else "")
                pack(os.path.join(HERE, src),
                     rows, cols, WIDE,
                     os.path.join(HERE, "layer%d_%s_w%d.hex" % (layer, stem,
                                                                WIDE)))
                n += 1
        print("packed %d tables -> %s" % (n, HERE))
        return 0
    src = argv[argv.index("--in") + 1]
    rows = int(argv[argv.index("--rows") + 1])
    cols = int(argv[argv.index("--cols") + 1])
    wide = int(argv[argv.index("--wide") + 1])
    dest = argv[argv.index("--out") + 1]
    pack(src, rows, cols, wide, dest)
    print("packed %s -> %s" % (src, dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
