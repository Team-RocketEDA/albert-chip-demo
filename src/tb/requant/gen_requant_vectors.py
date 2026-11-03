#!/usr/bin/env python3
"""gen_requant_vectors.py — stdlib-only golden generator for tb_requant.

Oracle: baked checkpoint bytes only (weights/bake/*.hex + scales_baked.json),
recomputed here with independent integer math. The RTL under test is never
consulted. Deterministic: directed corners are fixed lists; baked rows are
fixed (q/down out-channels 0..7, matching tv granularity). No RNG.

Fixed-point model (mirrors src/components/requant.v, W=8, SHIFT=8):
    prod   = acc * scale            (exact, Python ints)
    shr    = floor(prod / 256)      (== Verilog arithmetic >>> 8)
    y      = shr + zero
    golden = clip(y, -128, 127)

Vector groups:
  D  directed corners: acc x scale x zero cross product (boundaries,
     saturation corners, negative-floor shifts, zero/negative scales).
  B1 baked q_proj rows 0..7: acc = tv_q_golden (exact s32 dots, recomputed
     here from tv_q_act.hex x layer0_q_proj.hex and asserted equal), scale
     from scales_baked.json via Q8.8 test calibration
       scale_q = round_half_away(s_w * 256 / S_OUT_Q), S_OUT_Q = 0.25
     zeros cycle [0, 2, -3, 5, 0, -2, 3, -1].
  B2 baked down_proj rows 0..7: same with S_OUT_D = 0.5.

Float cross-check (report only, like quant_report): float_ref = acc*s_w/S_OUT
(+ zero); max abs deviation over in-range baked goldens is recorded in
manifest.txt. Q8.8 scale quantization is coarse at these small gains, so the
float model is NOT bit-exact by design; the bit-exact oracle is the integer
formula above.

Outputs (this dir): stim_acc.hex (08x s32), stim_scale.hex (04x s16),
stim_zero.hex (04x s16), golden.hex (02x s8), vec_count.hex, manifest.txt.
Hex conventions match testbench/gen_embed_vectors.py ($readmemh-ready).
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
BAKE = os.path.join(REPO, "weights", "bake")

SHIFT = 8
W = 8
LO, HI = -(1 << (W - 1)), (1 << (W - 1)) - 1

S_OUT_Q = 0.25
S_OUT_D = 0.5
ZERO_CYCLE = [0, 2, -3, 5, 0, -2, 3, -1]


def to_u(v, bits):
    return v & ((1 << bits) - 1)


def s_of(hexline, bits):
    v = int(hexline.strip(), 16)
    return v - (1 << bits) if v >= (1 << (bits - 1)) else v


def clip(y):
    return LO if y < LO else (HI if y > HI else y)


def requant_ref(acc, scale, zero, shift=SHIFT):
    prod = acc * scale
    shr = prod // (1 << shift)  # floor == arithmetic >>> for 2's complement
    return clip(shr + zero)


def round_half_away(x):
    import math
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def load_hex(name, bits):
    with open(os.path.join(BAKE, name)) as f:
        return [s_of(ln, bits) for ln in f if ln.strip()]


# ---- group D: directed corners ----
ACCS = [0, 1, -1, 2, -2, 63, -64, 126, 127, 128, 129, -127, -128, -129,
        -130, 255, 256, 257, -255, -256, -257, 1000, -1000, 32767, -32768,
        32769, -32769, 8388607, -8388608, 2**31 - 1, -2**31]
SCALES = [0, 1, -1, 2, 127, 128, 255, 256, 257, 512, 1000, -256, -1000,
          32767, -32768]
ZEROS = [0, 1, -1, 5, -5, 100, -100, 127, -128, 32767, -32768]

vecs = []  # (acc, scale, zero, tag)
for a in ACCS:
    for s in SCALES:
        for z in ZEROS:
            vecs.append((a, s, z, "D"))

# ---- groups B1/B2: baked rows ----
tensors = json.load(open(os.path.join(BAKE, "scales_baked.json")))["tensors"]
q_scales = tensors["model.layers.0.self_attn.q_proj.weight"]["scales"][:8]
d_scales = tensors["model.layers.0.mlp.down_proj.weight"]["scales"][:8]
q_act = load_hex("tv_q_act.hex", 8)
d_act = load_hex("tv_down_act.hex", 8)
q_w = load_hex("layer0_q_proj.hex", 8)
d_w = load_hex("layer0_down_proj.hex", 8)
q_gold_tv = load_hex("tv_q_golden.hex", 32)
d_gold_tv = load_hex("tv_down_golden.hex", 32)


def recompute(act, wrows, nrows, ncols):
    dots = []
    for r in range(nrows):
        row = wrows[r * ncols:(r + 1) * ncols]
        dots.append(sum(a * b for a, b in zip(act, row)))
    return dots


q_dots = recompute(q_act, q_w, 8, 576)
d_dots = recompute(d_act, d_w, 8, 1536)
assert q_dots == q_gold_tv, "q dot recompute mismatch vs tv_q_golden.hex"
assert d_dots == d_gold_tv, "down dot recompute mismatch vs tv_down_golden.hex"

float_devs = []
clip_hi = clip_lo = inrange = 0


def add_baked(dots, scales, s_out, tag):
    global clip_hi, clip_lo, inrange
    for r, (acc, sw) in enumerate(zip(dots, scales)):
        scale_q = round_half_away(sw * 256.0 / s_out)
        assert -(1 << 15) <= scale_q < (1 << 15), (tag, r, scale_q)
        assert scale_q != 0, (tag, r, sw, s_out)
        zero = ZERO_CYCLE[r]
        vecs.append((acc, scale_q, zero, tag))
        g = requant_ref(acc, scale_q, zero)
        fref = acc * sw / s_out + zero
        if g == HI:
            clip_hi += 1
        elif g == LO:
            clip_lo += 1
        else:
            inrange += 1
            if abs(fref) < 126.5:
                float_devs.append(abs(g - round(fref)))


add_baked(q_dots, q_scales, S_OUT_Q, "B1")
add_baked(d_dots, d_scales, S_OUT_D, "B2")

# ---- coverage assertions (fail loudly, never silently weak) ----
goldens = [requant_ref(a, s, z) for (a, s, z, _) in vecs]
tags = [t for (_, _, _, t) in vecs]
prods = [a * s for (a, s, _, _) in vecs]
assert any(g == HI for g in goldens), "no hi-clip vector"
assert any(g == LO for g in goldens), "no lo-clip vector"
assert any(g == 127 for g in goldens), "no exact-127 passthrough"
assert any(g == -128 for g in goldens), "no exact -128 passthrough"
assert any(p < 0 and p % 256 != 0 for p in prods), "no negative-floor shift"
assert any(s == 0 for (_, s, _, _) in vecs), "no zero-scale vector"
assert any(s < 0 for (_, s, _, _) in vecs), "no negative-scale vector"
assert any(z != 0 for (_, _, z, _) in vecs), "no nonzero-zero vector"
assert any(t == "B1" for t in tags) and any(t == "B2" for t in tags)

with open(os.path.join(HERE, "stim_acc.hex"), "w") as f:
    f.write("".join("%08x\n" % to_u(a, 32) for (a, _, _, _) in vecs))
with open(os.path.join(HERE, "stim_scale.hex"), "w") as f:
    f.write("".join("%04x\n" % to_u(s, 16) for (_, s, _, _) in vecs))
with open(os.path.join(HERE, "stim_zero.hex"), "w") as f:
    f.write("".join("%04x\n" % to_u(z, 16) for (_, _, z, _) in vecs))
with open(os.path.join(HERE, "golden.hex"), "w") as f:
    f.write("".join("%02x\n" % to_u(g, 8) for g in goldens))
with open(os.path.join(HERE, "vec_count.hex"), "w") as f:
    f.write("%08x\n" % len(vecs))

n_baked = sum(1 for t in tags if t != "D")
maxdev = max(float_devs) if float_devs else 0.0
with open(os.path.join(HERE, "manifest.txt"), "w") as f:
    f.write("requant vectors: %d total (%d directed, %d baked: 8 q + 8 down)\n"
            % (len(vecs), len(vecs) - n_baked, n_baked))
    f.write("model: W=8 SHIFT=8; golden=clip(floor(acc*scale/256)+zero)\n")
    f.write("baked calibration: S_OUT_Q=0.25 S_OUT_D=0.5, "
            "scale_q=round_half_away(s_w*256/S_OUT), zeros cycle %s\n"
            % (ZERO_CYCLE,))
    f.write("dots recomputed from tv_*_act.hex x layer0_*.hex: "
            "match tv_*_golden.hex exactly\n")
    f.write("baked golden spread: in-range=%d hi-clip=%d lo-clip=%d\n"
            % (inrange, clip_hi, clip_lo))
    f.write("float cross-check (in-range baked only): n=%d max|golden-round"
            "(float)|=%s\n" % (len(float_devs), maxdev))

print("wrote %d vectors (%d baked); in-range=%d hi=%d lo=%d floatmaxdev=%s"
      % (len(vecs), n_baked, inrange, clip_hi, clip_lo, maxdev))
