#!/usr/bin/env python3
"""Static-quant calibration for the etched MobileLLM stack (numpy).

Regime: SINGLE-TOKEN function (each hardware run maps one token id to
one pred with fresh state; there is no KV cache, so attention sees one
row and softmax is exactly 1.0). The float golden below runs the same
regime; agreement with it is the fidelity bar.

Method: teacher-force a text corpus token-by-token through the float
model, recording TRUE per-layer activation tensors. Then solve the
compile-time (MUL,SH) scale points of every requant site:

  site convention:  code = floor((acc * MUL) / 2^SH), MUL in s16
  gain g wanted    -> SH = first with M = round(g*2^SH) in [4096, 32767]

Scale discipline (norms erase upstream scale; only resid adds constrain):
  s_x      = 1/16       (norm yq with YQ_SHIFT=4; fixed by RTL)
  s_R      = GLOBAL     (resid domains r1/r2 share one scale across all
                         30 layers: s_out(L) = s_out(L-1) = s_E;
                         s_R = max |r1|,|r2| over corpus / OCC)
  s_qkv(L) = max |q|,|k|,|v| dots / OCC
  s_h(L)   = max |silu(g)*u| / OCC
  s_AOUT   = s_qkv        (single-token: attn out codes ~= v codes)
  SC_QKV   = s_wqkv * s_x / s_qkv
  SC_O     = s_wo * s_qkv / s_R
  G_MUL    = s_wg * s_x * 4096     (gate dots -> SiLU Q4.12)
  U_MUL    = s_wu * s_x * 4096
  P_MUL    = 2^-24 / s_h           (Q4.12 x Q4.12 -> h codes)
  RQ       = s_wd * s_h / s_R      (down dots -> resid codes)

Weight scales s_w* come from weights/bake/scales_pt.json (per-tensor
bake; Q/K/V share one scale per layer). Embed is re-baked afterwards
with --embed-scale s_R so resid-1 adds see matched scales.

Diagnostics recorded per layer: gate absmax (Q4.12 clips at |8|),
resid occupancy, MUL range warnings. Output: weights/bake/scales_cal.json
consumed by emit_layers.py.

Run with the rocket-engine venv python (numpy).
"""
import json
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "weights"))
from tokenize import load_pieces, encode  # noqa: E402

CKPT = os.path.join(ROOT, "weights", "mobilellm-125m", "finetuned",
                    "model.safetensors")
PT_SCALES = os.path.join(HERE, "scales_pt.json")
OUT = os.path.join(HERE, "scales_cal.json")

HID, NL, NQ, NKV, HD, EPS = 576, 30, 9, 3, 64, 1e-5
OCC = 100.0  # target code occupancy (|code| <= OCC typical)

CORPUS = [
    "hello world",
    "the quick brown fox jumps over the lazy dog",
    "artificial intelligence hardware acceleration",
    "once upon a time in a land far away",
    "silicon chips compute matrix products very fast",
    "to be or not to be that is the question",
    "in the beginning the universe was created",
    "a journey of a thousand miles begins with a single step",
]


def load_tensors(path):
    import numpy as np
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        hdr = json.loads(f.read(n))
        base = 8 + n
        out = {}
        with open(path, "rb") as f2:
            for name, m in hdr.items():
                if name == "__metadata__":
                    continue
                off0, off1 = m["data_offsets"]
                f2.seek(base + off0)
                raw = f2.read(off1 - off0)
                out[name] = np.frombuffer(raw, dtype=np.float32).reshape(
                    m["shape"]).copy().astype(np.float64)
        return out


def rmsnorm(x, w):
    import numpy as np
    return x / np.sqrt((x * x).mean() + EPS) * w


def choose_ms(gain):
    """Gain -> (MUL, SH): y = (acc*MUL) >>> SH with MUL in [4096, 32767]
    when the gain allows (else widest available, caller warns)."""
    if gain <= 0.0:
        return 1, 0
    sh = int(__import__("math").ceil(__import__("math").log2(4096.0 / gain)))
    if sh < 0:
        sh = 0
    if sh > 31:
        sh = 31  # all (MUL,SH) params carry 5-bit shifts
    m = int(round(gain * (1 << sh)))
    if m < 1:
        m = 1
    if m > 32767:
        m = 32767
    return m, sh


def main():
    import numpy as np
    ids, surf, byte_id = load_pieces()
    toks = []
    for s in CORPUS:
        toks += encode(s, ids, surf, byte_id)
    toks = toks[:400]
    print("calibration tokens: %d" % len(toks))

    T = load_tensors(CKPT)
    sw = json.load(open(PT_SCALES))["scales"]

    rec = {"r1": [0.0] * NL, "r2": [0.0] * NL, "qkv": [0.0] * NL,
           "h": [0.0] * NL, "gate": [0.0] * NL}
    for tok in toks:
        x = T["model.embed_tokens.weight"][tok]
        for li in range(NL):
            p = "model.layers.%d." % li
            h = rmsnorm(x, T[p + "input_layernorm.weight"])
            q = (T[p + "self_attn.q_proj.weight"] @ h).reshape(NQ, HD)
            k = (T[p + "self_attn.k_proj.weight"] @ h).reshape(NKV, HD)
            v = (T[p + "self_attn.v_proj.weight"] @ h).reshape(NKV, HD)
            attn = (T[p + "self_attn.o_proj.weight"]
                    @ np.concatenate([v[qi // (NQ // NKV)]
                                       for qi in range(NQ)]))
            r1 = x + attn
            h2 = rmsnorm(r1, T[p + "post_attention_layernorm.weight"])
            g = T[p + "mlp.gate_proj.weight"] @ h2
            u = T[p + "mlp.up_proj.weight"] @ h2
            hh = g / (1 + np.exp(-g)) * u
            m = T[p + "mlp.down_proj.weight"] @ hh
            r2 = r1 + m
            rec["r1"][li] = max(rec["r1"][li], float(np.abs(r1).max()))
            rec["r2"][li] = max(rec["r2"][li], float(np.abs(r2).max()))
            rec["qkv"][li] = max(rec["qkv"][li], float(np.abs(q).max()),
                                 float(np.abs(k).max()),
                                 float(np.abs(v).max()))
            rec["h"][li] = max(rec["h"][li], float(np.abs(hh).max()))
            rec["gate"][li] = max(rec["gate"][li], float(np.abs(g).max()))
            x = r2

    # Per-layer resid scales (an entry rescale stage maps s_R(L-1) to
    # s_R(L) at each layer input, so magnitudes may vary freely).
    s_R = [max(rec["r1"][li], rec["r2"][li]) / OCC for li in range(NL)]
    print("resid scales s_R: L0=%.6g L4=%.6g L29=%.6g"
          % (s_R[0], s_R[4], s_R[29]))
    s_x = 1.0 / 16.0
    layers = []
    warns = []
    for li in range(NL):
        p = "model.layers.%d." % li
        s_prev = s_R[li - 1] if li > 0 else None  # set after s_R known
        s_qkv = rec["qkv"][li] / OCC
        s_h = rec["h"][li] / OCC
        g_qkv = sw[p + "self_attn.q_proj.weight"] * s_x / s_qkv
        g_o = sw[p + "self_attn.o_proj.weight"] * s_qkv / s_R[li]
        g_g = sw[p + "mlp.gate_proj.weight"] * s_x * 4096.0
        g_u = sw[p + "mlp.up_proj.weight"] * s_x * 4096.0
        g_p = (2.0 ** -24) / s_h
        g_rq = sw[p + "mlp.down_proj.weight"] * s_h / s_R[li]
        sc_qkv = choose_ms(g_qkv)
        sc_o = choose_ms(g_o)
        gm = choose_ms(g_g)
        um = choose_ms(g_u)
        pm = choose_ms(g_p)
        rqm = choose_ms(g_rq)
        # Entry rescale: s_R(L-1) -> s_R(L); L0 is identity (embed is
        # re-baked at s_R(0), so s_out(-1) = s_R(0)).
        if li == 0:
            rsm = (256, 8)
        else:
            rsm = choose_ms(s_R[li - 1] / s_R[li])
        gains = {"SC_QKV": g_qkv, "SC_O": g_o, "G": g_g, "U": g_u,
                 "P": g_p, "RQ": g_rq, "RS": s_R[li - 1] / s_R[li] if li
                 else 1.0}
        for name, ms in (("SC_QKV", sc_qkv), ("SC_O", sc_o), ("G", gm),
                         ("U", um), ("P", pm), ("RQ", rqm), ("RS", rsm)):
            if ms[0] in (1, 32767):
                warns.append("L%d %s hits MUL bound (gain=%.6g)"
                             % (li, name, gains[name]))
        if rec["gate"][li] > 7.5:
            warns.append("L%d gate absmax %.2f exceeds Q4.12 headroom "
                         "(clips at 8.0)" % (li, rec["gate"][li]))
        layers.append({
            "s_R": s_R[li], "s_qkv": s_qkv, "s_h": s_h,
            "SC_QKVM": sc_qkv[0], "SC_QKVSH": sc_qkv[1],
            "SC_OM": sc_o[0], "SC_OSH": sc_o[1],
            "G_MUL": gm[0], "G_SH": gm[1],
            "U_MUL": um[0], "U_SH": um[1],
            "P_MUL": pm[0], "P_SH": pm[1],
            "RQ_MUL": rqm[0], "RQ_SH": rqm[1],
            "RS_MUL": rsm[0], "RS_SH": rsm[1],
            "YQ_SHIFT": 4,
            "absmax": {k: rec[k][li] for k in rec},
        })
    out = {"s_x": s_x, "OCC": OCC, "ntokens": len(toks),
           "layers": layers, "warnings": warns}
    json.dump(out, open(OUT, "w"), indent=1)
    print("wrote %s (%d layers, %d warnings)" % (OUT, NL, len(warns)))
    for w in warns[:20]:
        print("  WARN:", w)
    print("re-bake: bake_pertensor.py --embed-scale %.6g (s_R(0))" % s_R[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
