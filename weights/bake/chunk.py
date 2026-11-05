#!/usr/bin/env python3
"""Split baked per-layer hex tables along output rows for chunked P&R.

Each baked table is row-major (one int8 byte per line, row r = lines
[r*cols,(r+1)*cols); see bake.py bake_2d). Chunk k of C owns rows
[k*R/C,(k+1)*R/C) of every dense table, so every chunk has the same
shape and the stitch concatenates thirds across chunks to rebuild the
monolithic frame. 1-D norm vectors replicate into every chunk.

Chunk count rule (single source of truth — build.sh calls --resolve):
all dense row counts (576, 192, 1536) are multiples of 192, so the
effective count is the largest divisor of 192 at or below the request;
0/1 means monolithic (C=1). Layout: weights/bake/chunks/c{C}/.

Usage:
  python3 weights/bake/chunk.py --resolve 56   # print effective C
  python3 weights/bake/chunk.py --chunks 48 [--layers 0,1,2] [--wide]

Outputs (gitignored exhaust, like the bake):
  weights/bake/chunks/c{C}/layer{N}_{q,k,v,o,gate,up,down}_proj_c{K}.hex
  weights/bake/chunks/c{C}/layer{N}_{input,post_attention}_layernorm.hex
  --wide adds q/k/v/o per-slice w32 images for the wide SRAM banks.
"""

import os
import sys

from pack import pack as pack_wide

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT_ROOT = os.path.join(HERE, "chunks")

# (hex basename stem, rows, cols or None for 1-D). Row counts mirror
# bake.py layer_spec; cols matter only to cut line ranges.
TABLES = [
    ("q_proj", 576, 576),
    ("k_proj", 192, 576),
    ("v_proj", 192, 576),
    ("o_proj", 576, 576),
    ("gate_proj", 1536, 576),
    ("up_proj", 1536, 576),
    ("down_proj", 576, 1536),
]

NORMS = ["input_layernorm", "post_attention_layernorm"]

# gcd(576, 192, 1536) = 192: every C dividing 192 splits every dense
# table evenly (Q/O/DOWN 576/C, K/V 192/C, GATE/UP 1536/C rows).
GCD_ROWS = 192


def resolve(request):
    """Floor a requested chunk count to a uniform legal count.

    Args:
        request: Requested chunk count (<=1 means monolithic).

    Returns:
        Largest divisor of 192 at or below request (1 when request<=1,
        192 when request>192).
    """
    if request <= 1:
        return 1
    for d in sorted(_divisors(GCD_ROWS), reverse=True):
        if d <= request:
            return d
    return 1


def _divisors(n):
    """All positive divisors of n."""
    out = set()
    i = 1
    while i * i <= n:
        if n % i == 0:
            out.add(i)
            out.add(n // i)
        i += 1
    return out


def split_layer(layer, chunks, wide=False):
    """Split one layer's tables into chunk files.

    Args:
        layer: Layer index (0..29).
        chunks: Effective chunk count from resolve().
        wide: Also emit q/k/v/o per-slice w32 images (pack.py lane
            order) for the wide SRAM banks.

    Returns:
        Directory holding the chunk files.

    Raises:
        FileNotFoundError: If a baked source table is missing.
        ValueError: If chunks does not divide every row count.
    """
    for _, rows, _ in TABLES:
        if rows % chunks != 0:
            raise ValueError("C=%d does not divide %d rows" % (chunks, rows))
    dest = os.path.join(OUT_ROOT, "c%d" % chunks)
    os.makedirs(dest, exist_ok=True)
    for stem, rows, cols in TABLES:
        # Calibrated path: split the per-tensor _pt tables (shared QKV
        # scale, s_R-matched embed). Legacy per-row tables are NOT split
        # (they would bake stale weights + unity scales into chunk GDS).
        src = os.path.join(HERE, "layer%d_%s_pt.hex" % (layer, stem))
        if not os.path.isfile(src):
            raise FileNotFoundError("missing baked table: %s" % src)
        with open(src) as f:
            lines = f.readlines()
        want = rows * cols
        if len(lines) != want:
            raise ValueError("%s: %d lines, want %d" % (src, len(lines), want))
        per = rows // chunks
        for k in range(chunks):
            lo = k * per * cols
            chunk_path = os.path.join(
                dest, "layer%d_%s_c%d.hex" % (layer, stem, k))
            with open(chunk_path, "w") as f:
                f.writelines(lines[lo:(k + 1) * per * cols])
            if wide and stem in ("q_proj", "k_proj", "v_proj", "o_proj"):
                pack_wide(chunk_path, per, cols, 32, os.path.join(
                    dest, "layer%d_%s_c%d_w32.hex" % (layer, stem, k)))
    for stem in NORMS:
        src = os.path.join(HERE, "layer%d_%s.hex" % (layer, stem))
        if not os.path.isfile(src):
            raise FileNotFoundError("missing baked table: %s" % src)
        with open(src) as f:
            body = f.read()
        for k in range(chunks):
            with open(os.path.join(
                    dest, "layer%d_%s_c%d.hex" % (layer, stem, k)),
                    "w") as f:
                f.write(body)
    return dest


def parse_layers(spec, n=30):
    """Parse a layer selector like '0,1,2' or '0-29' into indices."""
    idx = []
    for part in spec.split(","):
        part = part.strip()
        if "-" in part:
            a, b = part.split("-", 1)
            idx.extend(range(int(a), int(b) + 1))
        elif part != "":
            idx.append(int(part))
    return [i for i in idx if 0 <= i < n]


def main(argv):
    """CLI entry point (see module docstring for usage)."""
    if "--resolve" in argv:
        print(resolve(int(argv[argv.index("--resolve") + 1])))
        return 0
    chunks = 1
    layers = list(range(30))
    wide = "--wide" in argv
    if "--chunks" in argv:
        chunks = resolve(int(argv[argv.index("--chunks") + 1]))
    if "--layers" in argv:
        layers = parse_layers(argv[argv.index("--layers") + 1])
    if chunks == 1:
        print("monolithic (C=1): nothing to split")
        return 0
    dest = None
    for layer in layers:
        dest = split_layer(layer, chunks, wide)
    print("split %d layers x %d chunks -> %s" % (len(layers), chunks, dest))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
