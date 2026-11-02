#!/usr/bin/env python3
"""token_feeder.py — ids -> int8 stream rows -> ngspice PWL stimulus.

Reads stimulus.mem (seq tok id), maps each id to a deterministic int8
embedding row (demo: hashed pseudo-embedding; replaced by EMBED_TOP RTL/SW
golden in later bring-up), and writes a ngspice .inc file with one PWL
voltage source per mesh row: 0 -> V_read for T_on=|x|*T_LSB, else 0.
Usage: python3 token_feeder.py stimulus.mem rows.inc [n_rows]"""
import hashlib
import sys

V_READ = 0.2
T_LSB_NS = 10.0
D_COLS = 8  # demo slice width (proxy for 512)


def embed_row(tok_id, width=D_COLS):
    row = []
    for k in range(width):
        h = int(hashlib.sha256(f"{tok_id}:{k}".encode()).hexdigest(), 16)
        row.append((h % 201) - 100)  # int8-ish in [-100, 100]
    return row


def pwl_source(idx, val):
    w = abs(val) * T_LSB_NS
    sign = 1.0 if val >= 0 else -1.0
    v = sign * V_READ
    return (f"Vrow{idx} nrow{idx} 0 PWL(0 0 1n 0 1.001n {v} "
            f"{w:.3f}n {v} {w + 0.001:.3f}n 0)")


def main():
    mem, out = sys.argv[1], sys.argv[2]
    width = int(sys.argv[3]) if len(sys.argv) > 3 else D_COLS
    toks = []
    with open(mem) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            _, _, i = line.split()
            toks.append(int(i))
    tok = toks[0] if toks else 1
    row = embed_row(tok, width)[:width]
    with open(out, "w") as f:
        f.write(f"* token {tok} -> {len(row)}-wide int8 row\n")
        for i, v in enumerate(row):
            f.write(pwl_source(i, v) + "\n")
    print(f"token={tok} row={row}")


if __name__ == "__main__":
    main()
