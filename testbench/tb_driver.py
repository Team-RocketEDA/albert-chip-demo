#!/usr/bin/env python3
"""tb_driver.py — text in, token-id stimulus out.

Tries HuggingFace `transformers` (AlbertTokenizer) when importable; otherwise
falls back to a deterministic demo vocabulary (clearly labeled DO-NOT-SHIP
for accuracy work — bring-up only). Emits stimulus.mem: one row per token,
`seq_idx tok_id`.
Usage: python3 tb_driver.py "sentence one" "sentence two" > stimulus.mem
"""
import sys

DEMO_VOCAB_SIZE = 5000


def tokenize_hf(texts):
    from transformers import AlbertTokenizer
    tok = AlbertTokenizer.from_pretrained("albert-base-v2")
    return [tok.encode(t, add_special_tokens=True) for t in texts]


def tokenize_demo(texts):
    import hashlib
    out = []
    for t in texts:
        ids = [2]  # [CLS]-ish
        for word in t.lower().split():
            h = int(hashlib.sha256(word.encode()).hexdigest(), 16)
            ids.append(3 + (h % (DEMO_VOCAB_SIZE - 3)))
        ids.append(3)  # [SEP]-ish
        out.append(ids)
    return out, True


def main(texts):
    try:
        seqs = tokenize_hf(texts)
        demo = False
    except Exception as e:
        print(f"# WARN: HF unavailable ({e}); using DEMO vocab, bring-up only",
              file=sys.stderr)
        seqs, demo = tokenize_demo(texts)
    for s, ids in enumerate(seqs):
        for t, i in enumerate(ids):
            print(f"{s} {t} {i}")
    print(f"# vocab={'demo-5000' if demo else 'albert-base-v2'}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: tb_driver.py \"sentence...\"")
    main(sys.argv[1:])
