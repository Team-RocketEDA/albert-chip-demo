#!/usr/bin/env python3
"""Per-tensor weight bake (static-quant fabric companion to bake.py).

bake.py quantizes per output ROW (one scale per row). The etched tiles
carry a SINGLE requant scale per matmul site, so a per-row weight scale
cannot fold into the fabric. This script re-bakes every 2-D matrix with
ONE absmax scale per tensor:

  scale = max_abs / 127  (scale = 1.0 when max_abs == 0)
  q = clip(round_half_away(w / scale), -127, 127)

Same stdlib-only stack and hex convention as bake.py (one value per
line, two lowercase hex digits, two's complement). Outputs land in
weights/bake/ (gitignored):

  layer{N}_{q,k,v,o,gate,up,down}_proj_pt.hex   (7 x 30 tables)
  embed_full_pt.hex                              (32000x576 tied table)
  scales_pt.json                                 (tensor -> scale)

The _pt tables are what the calibrated etched layers bind (emit_layers
points W*_FILE at them); the legacy per-row tables stay for the slice
stitch TBs. Norms are NOT rebaked here (emit_norms.py owns the Q8.8
gamma images, which are already single-scale).
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bake import HERE, ROOT, SRC, OUT, load_header, read_row  # noqa: E402

MATRICES = ["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj",
            "up_proj", "down_proj"]
TNAMES = {
    "q_proj": "self_attn.q_proj.weight",
    "k_proj": "self_attn.k_proj.weight",
    "v_proj": "self_attn.v_proj.weight",
    "o_proj": "self_attn.o_proj.weight",
    "gate_proj": "mlp.gate_proj.weight",
    "up_proj": "mlp.up_proj.weight",
    "down_proj": "mlp.down_proj.weight",
}


def quant_all(vals):
    """Single-scale quant of a whole-matrix value list -> (q, scale)."""
    amax = 0.0
    for w in vals:
        a = abs(w)
        if a > amax:
            amax = a
    scale = amax / 127.0 if amax > 0.0 else 1.0
    inv = 1.0 / scale
    q = []
    for w in vals:
        x = w * inv
        qi = int(math.floor(x + 0.5)) if x >= 0.0 else -int(math.floor(-x + 0.5))
        if qi > 127:
            qi = 127
        elif qi < -127:
            qi = -127
        q.append(qi)
    return q, scale


def bake_matrix(f, data_start, off, rows, cols, hex_path):
    """Stream rows, one global scale. Returns (scale, max_abs_err)."""
    vals = []
    for r in range(rows):
        vals += read_row(f, data_start + off + 4 * r * cols, cols)
    q, scale = quant_all(vals)
    maxerr = 0.0
    with open(hex_path, "w") as out:
        for r in range(rows):
            row = q[r * cols:(r + 1) * cols]
            out.write("".join("%02x\n" % (qi & 0xFF) for qi in row))
            for w, qi in zip(vals[r * cols:(r + 1) * cols], row):
                e = abs(w - qi * scale)
                if e > maxerr:
                    maxerr = e
    return scale, maxerr


def matrix_amax(f, data_start, off, rows, cols):
    """Single-pass absmax over a matrix (for shared-scale groups)."""
    amax = 0.0
    for r in range(rows):
        for w in read_row(f, data_start + off + 4 * r * cols, cols):
            a = abs(w)
            if a > amax:
                amax = a
    return amax


def bake_matrix_scaled(f, data_start, off, rows, cols, hex_path, scale):
    """Bake with a caller-supplied scale. Returns max_abs_err."""
    maxerr = 0.0
    inv = 1.0 / scale
    with open(hex_path, "w") as out:
        for r in range(rows):
            vals = read_row(f, data_start + off + 4 * r * cols, cols)
            rowq = []
            for w in vals:
                x = w * inv
                qi = (int(math.floor(x + 0.5)) if x >= 0.0
                      else -int(math.floor(-x + 0.5)))
                if qi > 127:
                    qi = 127
                elif qi < -127:
                    qi = -127
                rowq.append(qi)
                e = abs(w - qi * scale)
                if e > maxerr:
                    maxerr = e
            out.write("".join("%02x\n" % (qi & 0xFF) for qi in rowq))
    return maxerr


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--embed-scale", type=float, default=0.0,
                    help="forced embed table scale (0 = natural absmax/127; "
                         "calibration sets this to s_R(0) so the resid-1 "
                         "add sees matched scales)")
    args = ap.parse_args()
    hdr, data_start = load_header(SRC)
    scales = {}
    report = {}
    f = open(SRC, "rb")
    for L in range(30):
        p = "model.layers.%d." % L
        # Q/K/V share one scale per layer: inproj has a single requant.
        qkv_amax = 0.0
        for short in ("q_proj", "k_proj", "v_proj"):
            e = hdr[p + TNAMES[short]]
            rows, cols = e["shape"]
            a = matrix_amax(f, data_start, e["data_offsets"][0], rows, cols)
            if a > qkv_amax:
                qkv_amax = a
        qkv_scale = qkv_amax / 127.0 if qkv_amax > 0.0 else 1.0
        for short in MATRICES:
            tname = p + TNAMES[short]
            e = hdr[tname]
            rows, cols = e["shape"]
            hexname = "layer%d_%s_pt.hex" % (L, short)
            off = e["data_offsets"][0]
            assert e["data_offsets"][1] - off == 4 * rows * cols
            if short in ("q_proj", "k_proj", "v_proj"):
                print("baking %s -> %s (shared qkv scale %.6g)"
                      % (tname, hexname, qkv_scale), flush=True)
                maxerr = bake_matrix_scaled(f, data_start, off, rows, cols,
                                            os.path.join(OUT, hexname),
                                            qkv_scale)
                scale = qkv_scale
            else:
                print("baking %s -> %s" % (tname, hexname), flush=True)
                scale, maxerr = bake_matrix(f, data_start, off, rows, cols,
                                            os.path.join(OUT, hexname))
            scales[tname] = scale
            report[tname] = {"shape": [rows, cols], "scale": scale,
                             "max_abs_err": maxerr}
    print("baking model.embed_tokens.weight -> embed_full_pt.hex", flush=True)
    e = hdr["model.embed_tokens.weight"]
    off = e["data_offsets"][0]
    if args.embed_scale > 0.0:
        maxerr = bake_matrix_scaled(f, data_start, off, 32000, 576,
                                    os.path.join(OUT, "embed_full_pt.hex"),
                                    args.embed_scale)
        scale = args.embed_scale
    else:
        scale, maxerr = bake_matrix(f, data_start, off, 32000, 576,
                                    os.path.join(OUT, "embed_full_pt.hex"))
    scales["model.embed_tokens.weight"] = scale
    report["model.embed_tokens.weight"] = {"shape": [32000, 576],
                                           "scale": scale,
                                           "max_abs_err": maxerr}
    f.close()
    with open(os.path.join(OUT, "scales_pt.json"), "w") as out:
        json.dump({"scales": scales, "report": report}, out, indent=1)
    worst = max(v["max_abs_err"] for v in report.values())
    print("per-tensor bake done: %d tables, worst max_abs_err=%.6f"
          % (len(report), worst))


if __name__ == "__main__":
    main()
