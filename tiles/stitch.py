# stitch.py — KLayout batch abutment of per-block GDS into mobilellm-125m.gds.
#
# v1 SCOPE (honest): places the top-level macros in one row
# (embed_top | layer0..29_etched | lm_head) and merges to a single GDS.
# Top-level inter-macro WIRING is NOT routed in v1 — that pass follows,
# driven by architecture/pins.json, once real block GDS prove the abutment.
#
# Run:  ./build.sh stitch   (driver sets REPO/TILES; needs klayout on PATH)
# Env:  REPO (repo root; default cwd), TILES (default: <REPO>/tiles),
#       STITCH_TEST_BLOCKS (comma list overriding the 32 defaults; test only)
# Dies (dbu-agnostic abstract units): embed_top 800, layerN 2000, lm_head 600.
# Row width = 800 + 30*2000 + 600 = 61400u (~61mm on 130nm unrolled —
# the physics of etching 124M params, not a bug).
import os
import sys

import pya

REPO = os.environ.get("REPO", os.getcwd())
TILES = os.environ.get("TILES", os.path.join(REPO, "tiles"))
TEST = os.environ.get("STITCH_TEST_BLOCKS")

if TEST:
    BLOCKS = [b.strip() for b in TEST.split(",") if b.strip()]
else:
    BLOCKS = (["embed_top"] + ["layer%d_etched" % i for i in range(30)]
              + ["lm_head"])

WIDTHS = {"embed_top": 800, "lm_head": 600}


def width_of(name):
    return WIDTHS.get(name, 2000)


def main():
    missing = [b for b in BLOCKS
               if not os.path.exists(os.path.join(TILES, b + ".gds"))]
    if missing:
        print("STITCH AUDIT FAIL — missing %d/%d block GDS:"
              % (len(missing), len(BLOCKS)))
        for b in missing:
            print("  MISSING %s  (run: ./build.sh gds %s)"
                  % (os.path.join(TILES, b + ".gds"), b))
        return 1

    ly = pya.Layout()
    for b in BLOCKS:
        ly.read(os.path.join(TILES, b + ".gds"))

    top = ly.create_cell("mobilellm_125m")
    x = 0
    for b in BLOCKS:
        cell = ly.cell(b)
        if cell is None:
            print("STITCH FAIL — file %s.gds has no top cell named %s; "
                  "cells present: %s"
                  % (b, b, sorted(c.name for c in ly.each_cell())))
            return 1
        top.insert(pya.CellInstArray(cell.cell_index(),
                                     pya.Trans(x, 0)))
        x += width_of(b)

    out = os.path.join(TILES, "mobilellm-125m.gds")
    ly.write(out)
    print("STITCH V1 DONE: %s (%d instances, row %du; top wiring follows)"
          % (out, len(BLOCKS), x))
    return 0


sys.exit(main())
