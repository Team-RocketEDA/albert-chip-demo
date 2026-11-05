#!/usr/bin/env python3
"""Emit per-layer Q8.8 layernorm tables for rmsnorm_stage gamma binding.

The bake stores norms as int8 bytes plus one scale per vector
(scales_baked.json); rmsnorm_stage.gmem wants Q8.8 s16 lanes, so this
writes round(q*scale*256) as 4-hex-digit $readmemh lines. Deterministic
from committed bake outputs; re-run after any re-bake.

Usage: python3 weights/bake/emit_norms.py [--layers 0-29]
Output: weights/bake/layer{N}_{input,post_attention}_layernorm_q88.hex
        (gitignored exhaust, like the bake).
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from chunk import parse_layers  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SCALES = os.path.join(HERE, "scales_baked.json")

NORMS = ["input_layernorm", "post_attention_layernorm"]


def emit(layer):
    """Write both Q8.8 norm tables for one layer."""
    with open(SCALES) as f:
        tensors = json.load(f)["tensors"]
    for stem in NORMS:
        src = os.path.join(HERE, "layer%d_%s.hex" % (layer, stem))
        key = "model.layers.%d.%s.weight" % (
            layer, "input_layernorm"
            if stem == "input_layernorm" else "post_attention_layernorm")
        scale = tensors[key]["scales"][0]
        with open(src) as f:
            lines = f.readlines()
        assert len(lines) == 576, "%s: %d lines" % (src, len(lines))
        out = []
        for line in lines:
            q = int(line.strip(), 16)
            q -= 256 if q > 127 else 0
            g = int(round(q * scale * 256))
            g = max(-32768, min(32767, g))
            out.append("%04x\n" % (g & 0xFFFF))
        with open(os.path.join(
                HERE, "layer%d_%s_q88.hex" % (layer, stem)), "w") as f:
            f.writelines(out)
    print("layer%d norms q88 emitted" % layer)


def main(argv):
    """CLI entry point (see module docstring for usage)."""
    layers = list(range(30))
    if "--layers" in argv:
        layers = parse_layers(argv[argv.index("--layers") + 1])
    for layer in layers:
        emit(layer)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
