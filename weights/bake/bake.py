#!/usr/bin/env python3
"""Step-0 weight bake (plans/block-logic-plan.md step 0).

Pure-stdlib (struct/json/random/math only): parses
weights/mobilellm-125m/finetuned/model.safetensors (fp32), applies
per-channel absmax symmetric int8 quant to EVERY tensor, and writes
$readmemh hex tables + scales + quant report + deterministic per-block
test vectors. All outputs land in weights/bake/ (gitignored).

Quant rule (per output channel = per row of [out,in], single scale for
1-D norm vectors):  scale = max_abs / 127  (scale = 1.0 when max_abs == 0)
  q = clip(round_half_away(w / scale), -127, 127);  dequant = q * scale.
Hex convention matches testbench/gen_embed_vectors.py: one value per line,
two lowercase hex digits, unsigned byte (two's complement for s8 int8).
int32 golden lines: 8 lowercase hex digits, two's complement.
Q8.8 golden lines: 4 lowercase hex digits, two's complement.
"""
import struct
import json
import math
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = os.path.join(ROOT, "weights", "mobilellm-125m", "finetuned",
                   "model.safetensors")
OUT = HERE

# Expected checkpoint contract (block-logic-plan step 0 + PARAMS section 1/9).
EXPECTED = {
    "model.embed_tokens.weight": [32000, 576],
    "model.norm.weight": [576],
}
for L in range(30):
    p = "model.layers.%d." % L
    EXPECTED[p + "input_layernorm.weight"] = [576]
    EXPECTED[p + "post_attention_layernorm.weight"] = [576]
    EXPECTED[p + "self_attn.q_proj.weight"] = [576, 576]
    EXPECTED[p + "self_attn.k_proj.weight"] = [192, 576]
    EXPECTED[p + "self_attn.v_proj.weight"] = [192, 576]
    EXPECTED[p + "self_attn.o_proj.weight"] = [576, 576]
    EXPECTED[p + "mlp.gate_proj.weight"] = [1536, 576]
    EXPECTED[p + "mlp.up_proj.weight"] = [1536, 576]
    EXPECTED[p + "mlp.down_proj.weight"] = [576, 1536]

# Layer-0 bake set: (tensor name, hex file, rows, cols or None for 1-D).
# Kept verbatim: the demo-slice goldens and test vectors key off these exact
# entries; LAYERS below must reproduce this slice (asserted on import).
LAYER0 = [
    ("model.layers.0.self_attn.q_proj.weight", "layer0_q_proj.hex", 576, 576),
    ("model.layers.0.self_attn.k_proj.weight", "layer0_k_proj.hex", 192, 576),
    ("model.layers.0.self_attn.v_proj.weight", "layer0_v_proj.hex", 192, 576),
    ("model.layers.0.self_attn.o_proj.weight", "layer0_o_proj.hex", 576, 576),
    ("model.layers.0.mlp.gate_proj.weight", "layer0_gate_proj.hex", 1536, 576),
    ("model.layers.0.mlp.up_proj.weight", "layer0_up_proj.hex", 1536, 576),
    ("model.layers.0.mlp.down_proj.weight", "layer0_down_proj.hex", 576, 1536),
    ("model.layers.0.input_layernorm.weight", "layer0_input_layernorm.hex", 576, None),
    ("model.layers.0.post_attention_layernorm.weight",
     "layer0_post_attention_layernorm.hex", 576, None),
]


def layer_spec(L):
    """Per-layer bake entries for layer L (same shapes as LAYER0)."""
    p = "model.layers.%d." % L
    t = "layer%d_" % L
    return [
        (p + "self_attn.q_proj.weight", t + "q_proj.hex", 576, 576),
        (p + "self_attn.k_proj.weight", t + "k_proj.hex", 192, 576),
        (p + "self_attn.v_proj.weight", t + "v_proj.hex", 192, 576),
        (p + "self_attn.o_proj.weight", t + "o_proj.hex", 576, 576),
        (p + "mlp.gate_proj.weight", t + "gate_proj.hex", 1536, 576),
        (p + "mlp.up_proj.weight", t + "up_proj.hex", 1536, 576),
        (p + "mlp.down_proj.weight", t + "down_proj.hex", 576, 1536),
        (p + "input_layernorm.weight", t + "input_layernorm.hex",
         576, None),
        (p + "post_attention_layernorm.weight",
         t + "post_attention_layernorm.hex", 576, None),
    ]


LAYERS = []
for _L in range(30):
    LAYERS += layer_spec(_L)
assert LAYERS[: len(LAYER0)] == LAYER0, "layer-0 slice drifted from LAYER0"
assert len(LAYERS) == 270, "expected 30 layers x 9 tables"


def load_header(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        hdr = json.loads(f.read(n))
    data_start = 8 + n
    hdr.pop("__metadata__", None)
    return hdr, data_start


def quant_row(vals):
    """Per-channel quant of one row (list of floats) -> (qints, scale, maxerr)."""
    amax = 0.0
    for w in vals:
        a = abs(w)
        if a > amax:
            amax = a
    scale = amax / 127.0 if amax > 0.0 else 1.0
    inv = 1.0 / scale
    q = []
    maxerr = 0.0
    for w in vals:
        x = w * inv
        qi = int(math.floor(x + 0.5)) if x >= 0.0 else -int(math.floor(-x + 0.5))
        if qi > 127:
            qi = 127
        elif qi < -127:
            qi = -127
        q.append(qi)
        e = abs(w - qi * scale)
        if e > maxerr:
            maxerr = e
    return q, scale, maxerr


def read_row(f, off, n):
    """Read n fp32 LE floats at absolute file offset off -> list of floats."""
    f.seek(off)
    buf = f.read(4 * n)
    if len(buf) != 4 * n:
        raise IOError("short read at offset %d (want %d floats)" % (off, n))
    return list(struct.unpack("<%df" % n, buf))


def bake_2d(f, data_start, off, rows, cols, hex_path, keep_rows=0):
    """Quantize [rows,cols] tensor, stream hex lines. Returns
    (scales, maxerr, meanerr, kept_int8_rows)."""
    scales = []
    maxerr = 0.0
    sumerr = 0.0
    count = 0
    kept = []
    with open(hex_path, "w") as out:
        for r in range(rows):
            vals = read_row(f, data_start + off + 4 * r * cols, cols)
            q, scale, merr = quant_row(vals)
            scales.append(scale)
            if merr > maxerr:
                maxerr = merr
            for w, qi in zip(vals, q):
                sumerr += abs(w - qi * scale)
            count += len(vals)
            out.write("".join("%02x\n" % (qi & 0xFF) for qi in q))
            if r < keep_rows:
                kept.append(q)
            if (r + 1) % 512 == 0:
                print("  %s row %d/%d" % (os.path.basename(hex_path), r + 1, rows),
                      flush=True)
    return scales, maxerr, sumerr / count, kept


def bake_1d(f, data_start, off, n, hex_path):
    """Quantize length-n vector with a single scale. Returns (scale, maxerr)."""
    vals = read_row(f, data_start + off, n)
    q, scale, maxerr = quant_row(vals)
    with open(hex_path, "w") as out:
        out.write("".join("%02x\n" % (qi & 0xFF) for qi in q))
    deq = [qi * scale for qi in q]
    return scale, maxerr, vals, q, deq


def s32hex(v):
    return "%08x" % (v & 0xFFFFFFFF)


def s16hex(v):
    return "%04x" % (v & 0xFFFF)


def main():
    hdr, data_start = load_header(SRC)
    names = sorted(hdr.keys())
    print("tensors: %d" % len(names))
    assert len(names) == 272, "expected 272 tensors, got %d" % len(names)
    for tname, shape in EXPECTED.items():
        assert tname in hdr, "missing tensor " + tname
        assert hdr[tname]["dtype"] == "F32", "non-fp32 " + tname
        assert list(hdr[tname]["shape"]) == shape, \
            "shape mismatch %s %s vs %s" % (tname, hdr[tname]["shape"], shape)
    assert not any("lm_head" in k for k in names), "unexpected lm_head tensor"
    assert not any("bias" in k for k in names), "unexpected bias tensor"
    print("contract check: 272 tensors, shapes match plan, no lm_head, no bias")

    report = {}   # tname -> dict(shape, n_scales, max_abs_err, mean_abs_err)
    scales_out = {}  # baked tables only
    f = open(SRC, "rb")

    # ---- per-layer tables (all 30 layers; test-vector goldens stay layer-0) ----
    kept = {}  # hex key -> first-8 int8 rows (for test-vector goldens)
    for tname, hexname, rows, cols in LAYERS:
        print("baking %s" % tname, flush=True)
        e = hdr[tname]
        off = e["data_offsets"][0]
        expect = 4 * rows * cols if cols is not None else 4 * rows
        assert e["data_offsets"][1] - off == expect
        if cols is None:  # 1-D norm: single scale
            scale, maxerr, vals, q, deq = bake_1d(
                f, data_start, off, rows, os.path.join(OUT, hexname))
            report[tname] = {"shape": [rows], "n_scales": 1,
                             "max_abs_err": maxerr,
                             "mean_abs_err": sum(abs(w - d) for w, d in
                                                 zip(vals, deq)) / rows}
            scales_out[tname] = {"shape": [rows], "scales": [scale]}
            if hexname.startswith("layer0_"):
                kept[hexname] = (q, deq)
        else:
            scales, maxerr, meanerr, rows8 = bake_2d(
                f, data_start, off, rows, cols,
                os.path.join(OUT, hexname), keep_rows=8)
            report[tname] = {"shape": [rows, cols], "n_scales": rows,
                             "max_abs_err": maxerr, "mean_abs_err": meanerr}
            scales_out[tname] = {"shape": [rows, cols], "scales": scales}
            if hexname.startswith("layer0_"):
                kept[hexname] = rows8

    # ---- final norm ----
    print("baking model.norm.weight", flush=True)
    e = hdr["model.norm.weight"]
    scale, maxerr, nvals, nq, ndeq = bake_1d(
        f, data_start, e["data_offsets"][0], 576,
        os.path.join(OUT, "final_norm.hex"))
    report["model.norm.weight"] = {"shape": [576], "n_scales": 1,
                                   "max_abs_err": maxerr,
                                   "mean_abs_err": sum(abs(w - d) for w, d in
                                                       zip(nvals, ndeq)) / 576}
    scales_out["model.norm.weight"] = {"shape": [576], "scales": [scale]}

    # ---- embed: full table (lm_head W_lm reuses this copy) + 64-row proxy ----
    print("baking model.embed_tokens.weight (32000x576)", flush=True)
    e = hdr["model.embed_tokens.weight"]
    off = e["data_offsets"][0]
    assert e["data_offsets"][1] - off == 4 * 32000 * 576
    tv_ids_rng = random.Random(0xE1BE9)
    tv_ids = [0, 1, 2, 31999,
              tv_ids_rng.randrange(32000), tv_ids_rng.randrange(32000),
              tv_ids_rng.randrange(32000), tv_ids_rng.randrange(32000)]
    want_rows = set(tv_ids) | set(range(16))
    # proxy64 must equal first 64 full rows; also exactly fills the
    # embed_top u_dbuf frame bank (64*576 = 36864 bytes).
    escales = []
    emaxerr = 0.0
    emabsum = 0.0
    embed_want = {}
    full = open(os.path.join(OUT, "embed_full.hex"), "w")
    proxy = open(os.path.join(OUT, "embed_proxy64.hex"), "w")
    for r in range(32000):
        vals = read_row(f, data_start + off + 4 * r * 576, 576)
        q, scale, merr = quant_row(vals)
        escales.append(scale)
        if merr > emaxerr:
            emaxerr = merr
        for w, qi in zip(vals, q):
            emabsum += abs(w - qi * scale)
        blob = "".join("%02x\n" % (qi & 0xFF) for qi in q)
        full.write(blob)
        if r < 64:
            proxy.write(blob)
        if r in want_rows:
            embed_want[r] = q
        if (r + 1) % 4096 == 0:
            print("  embed_full row %d/32000" % (r + 1), flush=True)
    full.close()
    proxy.close()
    report["model.embed_tokens.weight"] = {
        "shape": [32000, 576], "n_scales": 32000,
        "max_abs_err": emaxerr, "mean_abs_err": emabsum / (32000 * 576)}
    print("embed baked: max_abs_err=%.6g" % emaxerr)

    # ---- quant report over EVERY remaining tensor (streamed, no hex) ----
    print("scanning remaining %d tensors for report"
          % (272 - len(LAYERS) - 2), flush=True)
    done = set([t for t, _, _, _ in LAYERS] + ["model.norm.weight",
                                              "model.embed_tokens.weight"])
    for tname in names:
        if tname in done:
            continue
        e = hdr[tname]
        shape = list(e["shape"])
        off = e["data_offsets"][0]
        if len(shape) == 1:
            n = shape[0]
            vals = read_row(f, data_start + off, n)
            q1, _, maxerr = quant_row(vals)
            am = 0.0
            for w in vals:
                a = abs(w)
                if a > am:
                    am = a
            sc = am / 127.0 if am > 0.0 else 1.0
            meanerr = sum(abs(w - qi * sc) for w, qi in zip(vals, q1)) / n
            report[tname] = {"shape": shape, "n_scales": 1,
                             "max_abs_err": maxerr,
                             "mean_abs_err": meanerr}
        else:
            rows, cols = shape
            amax_rows = []
            # pass 1: per-row absmax (chunked reads, no full-tensor store)
            for r in range(rows):
                vals = read_row(f, data_start + off + 4 * r * cols, cols)
                am = 0.0
                for w in vals:
                    a = abs(w)
                    if a > am:
                        am = a
                amax_rows.append(am)
            # pass 2: err with frozen scales
            maxerr = 0.0
            sumerr = 0.0
            for r in range(rows):
                vals = read_row(f, data_start + off + 4 * r * cols, cols)
                am = amax_rows[r]
                sc = am / 127.0 if am > 0.0 else 1.0
                inv = 1.0 / sc
                for w in vals:
                    x = w * inv
                    qi = (int(math.floor(x + 0.5)) if x >= 0.0
                          else -int(math.floor(-x + 0.5)))
                    if qi > 127:
                        qi = 127
                    elif qi < -127:
                        qi = -127
                    er = abs(w - qi * sc)
                    sumerr += er
                    if er > maxerr:
                        maxerr = er
            report[tname] = {"shape": shape, "n_scales": rows,
                             "max_abs_err": maxerr,
                             "mean_abs_err": sumerr / (rows * cols)}
    f.close()

    with open(os.path.join(OUT, "scales_baked.json"), "w") as sf:
        json.dump({"scheme": "per-channel absmax symmetric int8, "
                   "scale=max_abs/127 (1.0 if 0), range [-127,127], "
                   "round-half-away-from-zero; 1-D norms use one scale",
                   "tensors": scales_out,
                   "embed_scales": escales}, sf)
    print("scales_baked.json written")
    return hdr, report, escales, kept, embed_want, tv_ids


def write_report(report):
    lines = []
    lines.append("# quant_report: per-channel absmax symmetric int8, all 272 tensors")
    lines.append("# columns: tensor | shape | n_scales | max_abs_err | mean_abs_err")
    worst = ("", -1.0)
    for tname in sorted(report.keys()):
        r = report[tname]
        lines.append("%s | %s | %d | %.8g | %.8g"
                     % (tname, str(r["shape"]), r["n_scales"],
                        r["max_abs_err"], r["mean_abs_err"]))
        if r["max_abs_err"] > worst[1]:
            worst = (tname, r["max_abs_err"])
    lines.append("# worst max_abs_err: %s %.8g" % worst)
    with open(os.path.join(OUT, "quant_report.txt"), "w") as rf:
        rf.write("\n".join(lines) + "\n")
    print("quant_report.txt: 272 tensors, worst %s %.8g" % worst)
    return worst


BANKS = [
    ("model.layers.0.self_attn.q_proj.weight", "inproj_tile u_wsram W=8 N=4096",
     576 * 576, 8, 4096, "81 tiles of 4096 B over K-major passes"),
    ("model.layers.0.self_attn.k_proj.weight", "inproj_tile u_wsram W=8 N=4096",
     192 * 576, 8, 4096, "27 tiles of 4096 B, single 192 pass"),
    ("model.layers.0.self_attn.v_proj.weight", "inproj_tile u_wsram W=8 N=4096",
     192 * 576, 8, 4096, "27 tiles of 4096 B, single 192 pass"),
    ("model.layers.0.self_attn.o_proj.weight", "outproj_tile u_wsram W=8 N=4096",
     576 * 576, 8, 4096, "81 tiles of 4096 B, 3 column slices x 27"),
    ("model.layers.0.mlp.gate_proj.weight", "ffn_tile u_gatew W=8 N=8192",
     1536 * 576, 8, 8192, "108 tiles of 8192 B, 6x256 chunks"),
    ("model.layers.0.mlp.up_proj.weight", "ffn_tile u_upw W=8 N=8192",
     1536 * 576, 8, 8192, "108 tiles of 8192 B, 6x256 chunks"),
    ("model.layers.0.mlp.down_proj.weight", "ffn_tile u_downw W=8 N=8192",
     576 * 1536, 8, 8192, "108 tiles of 8192 B, 6x256 chunks"),
    ("model.layers.0.input_layernorm.weight", "rmsnorm_d gamma port W=16 "
     "(regfile-driven; this hex is the $readmemh init image)", 576, 8, 576,
     "1:1 gamma vector, widened s8<<8 per PARAMS section 2 boundary rule"),
    ("model.layers.0.post_attention_layernorm.weight", "rmsnorm_d gamma port "
     "W=16 (regfile-driven; this hex is the $readmemh init image)", 576, 8,
     576, "1:1 gamma vector"),
    ("model.norm.weight", "rmsnorm_d gamma port W=16 (final norm)", 576, 8,
     576, "1:1 gamma vector"),
    ("model.embed_tokens.weight", "lm_head u_wlm W=4608 N=32768 "
     "(W_lm baked as embed copy per PARAMS 1/7/9; 32000 of 32768 rows used)",
     32000 * 576, 4608, 32768, "32000 rows x 576 B = 18432000 B "
     "in 18874368 B bank"),
    ("model.embed_tokens.weight proxy64", "embed_top u_dbuf W=8 N=36864 "
     "(S*H frame bank, S=64/H=576)", 64 * 576, 8, 36864,
     "64 rows x 576 B = 36864 B, exact 1:1 frame fill"),
]


def write_bank_check(report):
    lines = []
    lines.append("# bank_check: baked int8 table bytes vs src/components "
                 "sram_1r1w bank sizes")
    lines.append("# all weight tables are stationary full-matrix images; "
                 "tiles stream chunk passes per PARAMS section 3-4")
    ok = True
    for item in BANKS:
        tname, bank, need_bytes, w, n, note = item
        cap_bytes = (w // 8) * n if w % 8 == 0 else None
        if "proxy64" in tname:
            status = "OK" if need_bytes == 36864 else "MISMATCH"
        elif "embed_tokens" in tname:
            status = "OK" if need_bytes <= cap_bytes else "MISMATCH"
        elif "layernorm" in tname or tname == "model.norm.weight":
            status = "OK" if need_bytes == 576 else "MISMATCH"
        else:
            status = "OK" if need_bytes % (cap_bytes or 1) == 0 else "MISMATCH"
        if status != "OK":
            ok = False
        lines.append("%s | need %d B | bank %s cap %s B | %s | %s"
                     % (tname, need_bytes, bank,
                        str(cap_bytes), status, note))
    lines.append("OVERALL: " + ("ALL BANKS FIT" if ok else "MISMATCH PRESENT"))
    with open(os.path.join(OUT, "bank_check.txt"), "w") as bf:
        bf.write("\n".join(lines) + "\n")
    print("bank_check.txt: " + ("ALL BANKS FIT" if ok else "MISMATCH PRESENT"))
    assert ok, "bank size mismatch"
    return lines


def write_test_vectors(kept, embed_want, tv_ids, scales_out):
    """Deterministic per-block stimulus + golden files with recorded seeds."""
    tv = {}

    def act_vec(seed, n):
        rng = random.Random(seed)
        v = [rng.randrange(-128, 128) for _ in range(n)]
        v[0] = -128  # saturation corners, always present
        if n > 1:
            v[1] = 127
        return v

    # embed lookup: ids -> rows straight from the baked int8 table
    with open(os.path.join(OUT, "tv_embed_ids.hex"), "w") as f:
        f.write("".join("%04x\n" % i for i in tv_ids))
    with open(os.path.join(OUT, "tv_embed_golden.hex"), "w") as f:
        for i in tv_ids:
            f.write("".join("%02x\n" % (b & 0xFF) for b in embed_want[i]))
    tv["embed"] = "seed 0xE1BE9 (ids 0,1,2,31999 + 4 draws); golden = baked " \
        "int8 rows in ids order"

    # matmul blocks: int8 act vector x first-8 baked int8 rows -> int32 psums
    matmuls = [("q", "layer0_q_proj.hex", 576, 0xB0C1),
               ("k", "layer0_k_proj.hex", 576, 0xB0C2),
               ("v", "layer0_v_proj.hex", 576, 0xB0C3),
               ("o", "layer0_o_proj.hex", 576, 0xB0C4),
               ("gate", "layer0_gate_proj.hex", 576, 0xB0C5),
               ("up", "layer0_up_proj.hex", 576, 0xB0C6),
               ("down", "layer0_down_proj.hex", 1536, 0xB0C7)]
    for tag, hexname, indim, seed in matmuls:
        a = act_vec(seed, indim)
        with open(os.path.join(OUT, "tv_%s_act.hex" % tag), "w") as f:
            f.write("".join("%02x\n" % (x & 0xFF) for x in a))
        rows8 = kept[hexname]
        with open(os.path.join(OUT, "tv_%s_golden.hex" % tag), "w") as f:
            for r in rows8:
                f.write(s32hex(sum(x * y for x, y in zip(a, r))) + "\n")
        tv[tag] = "seed 0x%X; act[%d] s8 corners-forced; golden = exact " \
            "int8*int8->s32 dots of first 8 out-channels" % (seed, indim)

    # lm_head: same matmul shape over first 16 vocab rows of the embed copy
    a = act_vec(0xB0C8, 576)
    with open(os.path.join(OUT, "tv_lmhead_act.hex"), "w") as f:
        f.write("".join("%02x\n" % (x & 0xFF) for x in a))
    with open(os.path.join(OUT, "tv_lmhead_golden.hex"), "w") as f:
        for r in range(16):
            f.write(s32hex(sum(x * y for x, y in
                               zip(a, embed_want[r]))) + "\n")
    tv["lmhead"] = "seed 0xB0C8; golden = exact s32 dots vs embed-copy rows " \
        "0..15 (full W_lm is embed_full.hex per PARAMS 7)"

    # rmsnorm_d: int8 in + baked layer-0 input gamma -> Q8.8 golden
    rq, rdeq = kept["layer0_input_layernorm.hex"]
    rin = act_vec(0xB0C9, 576)
    with open(os.path.join(OUT, "tv_rmsnorm_in.hex"), "w") as f:
        f.write("".join("%02x\n" % (x & 0xFF) for x in rin))
    eps = 1e-5
    mean_sq = sum(float(x) * float(x) for x in rin) / 576.0
    rlen = math.sqrt(mean_sq + eps)
    with open(os.path.join(OUT, "tv_rmsnorm_golden.hex"), "w") as f:
        for x, g in zip(rin, rdeq):
            y = (float(x) / rlen) * g
            f.write(s16hex(int(math.floor(y * 256.0 + 0.5)) if y >= 0
                           else -int(math.floor(-y * 256.0 + 0.5))) + "\n")
    tv["rmsnorm"] = "seed 0xB0C9, resid=0, eps=1e-5, gamma=baked dequant; " \
        "golden = round(y*256) Q8.8 two's complement"

    # silu / softmax float references (LUT blocks, steps 8-9 oracle shape)
    s_rng = random.Random(0xB0CA)
    s_in = [s_rng.uniform(-8.0, 8.0) for _ in range(16)]
    with open(os.path.join(OUT, "tv_silu_stim.txt"), "w") as f:
        f.write("".join("%.8g\n" % v for v in s_in))
    with open(os.path.join(OUT, "tv_silu_golden.txt"), "w") as f:
        f.write("".join("%.8g\n" % (v / (1.0 + math.exp(-v))) for v in s_in))
    tv["silu"] = "seed 0xB0CA; golden = x*sigmoid(x) float reference"
    m_rng = random.Random(0xB0CB)
    m_in = [m_rng.uniform(-4.0, 4.0) for _ in range(8)]
    mx = max(m_in)
    ex = [math.exp(v - mx) for v in m_in]
    st = sum(ex)
    with open(os.path.join(OUT, "tv_softmax_stim.txt"), "w") as f:
        f.write("".join("%.8g\n" % v for v in m_in))
    with open(os.path.join(OUT, "tv_softmax_golden.txt"), "w") as f:
        f.write("".join("%.8g\n" % (v / st) for v in ex))
    tv["softmax"] = "seed 0xB0CB; golden = max-sub exp/sum float reference"

    with open(os.path.join(OUT, "tv_manifest.txt"), "w") as f:
        f.write("# test-vector manifest: deterministic, seeds recorded\n")
        f.write("# formats: *.hex act/golden rows are $readmemh-ready "
                "(s8 bytes 02x; s32 psums 08x; Q8.8 04x; tv_embed_ids 04x "
                "u15 token ids); *_stim/golden.txt are decimal floats\n")
        for k in sorted(tv.keys()):
            f.write("%s: %s\n" % (k, tv[k]))
    print("test vectors written (%d blocks)" % len(tv))


if __name__ == "__main__":
    hdr, report, escales, kept, embed_want, tv_ids = main()
    assert len(report) == 272
    worst = write_report(report)
    write_bank_check(report)
    with open(os.path.join(OUT, "scales_baked.json")) as sf:
        scales_out = json.load(sf)["tensors"]
    write_test_vectors(kept, embed_want, tv_ids, scales_out)
    print("BAKE COMPLETE worst=%s %.8g" % worst)


