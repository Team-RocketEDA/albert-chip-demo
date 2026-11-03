#!/usr/bin/env python3
"""tokenize.py — text <-> token-id bridge for the sim prompt path.

Pure stdlib (no sentencepiece/hf libs on this box): hand-parses the
SentencePiece ModelProto in weights/mobilellm-125m/finetuned/tokenizer.model
(varints + fixed32 + length-delimited fields only) into an id->piece table.

  python3 weights/tokenize.py "hello world"      # text -> ids (BOS added)
  python3 weights/tokenize.py --decode "1 2 3"   # ids -> text (specials dropped)

Encode follows the SentencePiece BPE merge loop (best-score pair first,
byte-fallback for unknown bytes, NFKC + prefix-space per tokenizer_config).
It is a faithful reimplementation, not the reference C++ — roundtrip
(decode(encode(s)) == s) is the self-check; spot-check odd outputs against
HF before trusting exotic strings. Decode is exact (table lookup).

Wiring: `make -C src/sim_verilator prompt-text PROMPT_TEXT="hi"` tokenizes
then runs the existing embed bench; decode `pred_out` ids back with --decode.
"""
import os
import struct
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "mobilellm-125m", "finetuned", "tokenizer.model")

BOS, EOS, UNK = 1, 2, 0


def read_varint(buf, pos):
    """Return (value, new_pos)."""
    shift = 0
    val = 0
    while True:
        b = buf[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, pos
        shift += 7


def parse_msg(buf):
    """Yield (field_no, wire_type, value) for a protobuf message.

    LEN values come back as bytes; FIXED32 as int bits; VARINT as int.
    """
    pos = 0
    n = len(buf)
    while pos < n:
        key, pos = read_varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = read_varint(buf, pos)
        elif wire == 5:
            val = struct.unpack("<I", bytes(buf[pos:pos + 4]))[0]
            pos += 4
        elif wire == 2:
            ln, pos = read_varint(buf, pos)
            val = bytes(buf[pos:pos + ln])
            pos += ln
        else:
            raise ValueError("unsupported wire type %d" % wire)
        yield field, wire, val


def load_pieces(path=MODEL):
    """Return (id_to_piece, surface_to_id, byte_id) from the .model file."""
    with open(path, "rb") as f:
        data = f.read()
    ids = []
    for field, wire, val in parse_msg(data):
        if field == 1 and wire == 2:
            surface, score, ptype = None, None, 1
            for f2, w2, v2 in parse_msg(val):
                if f2 == 1:
                    surface = v2.decode("utf-8")
                elif f2 == 2:
                    score = struct.unpack("<f", struct.pack("<I", v2))[0]
                elif f2 == 3:
                    ptype = v2
            ids.append((surface, score if score is not None else 0.0,
                        ptype))
    surf = {s: (i, sc) for i, (s, sc, _) in enumerate(ids)}
    byte_id = {}
    for i, (s, _, t) in enumerate(ids):
        if t == 6 and s.startswith("<0x") and s.endswith(">"):
            byte_id[int(s[3:-1], 16)] = i
    return ids, surf, byte_id


def encode(text, ids, surf, byte_id, add_bos=True):
    """Text -> [ids]. BPE merge loop, best merged-score first."""
    text = unicodedata.normalize("NFKC", text).replace(" ", "\u2581")
    if not text.startswith("\u2581"):
        text = "\u2581" + text
    syms = list(text)

    def to_ids(sym):
        if sym in surf:
            return [surf[sym][0]]
        out = []
        for ch in sym.encode("utf-8"):
            out.append(byte_id.get(ch, UNK))
        return out

    while len(syms) > 1:
        best, best_sc, best_i = None, None, -1
        for i in range(len(syms) - 1):
            merged = syms[i] + syms[i + 1]
            hit = surf.get(merged)
            if hit is not None and (best_sc is None or hit[1] > best_sc):
                best, best_sc, best_i = merged, hit[1], i
        if best is None:
            break
        syms[best_i:best_i + 2] = [best]
    out = []
    for s in syms:
        out += to_ids(s)
    return ([BOS] if add_bos else []) + out


def decode(id_list, ids):
    """[ids] -> text. Drops BOS/EOS/UNK specials, unescapes byte pieces."""
    parts = []
    for i in id_list:
        if i in (BOS, EOS, UNK) or i < 0 or i >= len(ids):
            continue
        s, _, t = ids[i]
        if t == 6 and s.startswith("<0x"):
            parts.append(chr(int(s[3:-1], 16)))
        else:
            parts.append(s)
    return "".join(parts).replace("\u2581", " ").lstrip(" ")


def main(argv):
    ids, surf, byte_id = load_pieces()
    if argv and argv[0] == "--decode":
        nums = [int(x, 0) for x in argv[1:]]
        print(decode(nums, ids))
    elif argv and argv[0] == "--vocab-size":
        print(len(ids))
    elif argv:
        print(" ".join("0x%x" % i for i in
                       encode(" ".join(argv), ids, surf, byte_id)))
    else:
        print("usage: tokenize.py \"text\" | --decode IDS... | --vocab-size",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
