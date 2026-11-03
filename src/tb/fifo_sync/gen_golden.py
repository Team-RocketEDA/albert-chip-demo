#!/usr/bin/env python3
"""Independent pure-stdlib golden oracle for fifo_sync (plan step 4).

Never touches the RTL: a plain python list models the queue. Cycle
discipline matches the testbench exactly:

  - negedge: TB drives (wr, rd, wdata)
  - posedge: DUT updates, TB samples (full, empty, rdata) after #1

So each vector row carries the POST-update expected outputs for the op on
that row, computed here from the reference queue BEFORE applying the op:

    wr_en = wr and len(q) < D        (write ignored when full: no overflow)
    rd_en = rd and len(q) > 0        (read ignored when empty: no underflow)
    pop head first, then push wdata   (simultaneous wr+rd order)
    FWFT: rdata = head, or 0x00 when empty

Outputs: vectors_fifo.txt  (row 1 = vector count N, then N rows of
`wr rd wdata_hex exp_full exp_empty exp_rdata_hex`).
Deterministic: random.Random(SEED). No numpy/torch.
"""
import random

SEED = 20261104
W = 8
D = 8
MASK = (1 << W) - 1
NVEC_RANDOM = 600

rng = random.Random(SEED)
q = []          # reference queue, head at index 0
rows = []


def step(wr, rd, wdata):
    wr_en = bool(wr) and len(q) < D
    rd_en = bool(rd) and len(q) > 0
    if rd_en:
        q.pop(0)
    if wr_en:
        q.append(wdata & MASK)
    rows.append((wr, rd, wdata & MASK, int(len(q) == D),
                 int(len(q) == 0), (q[0] if q else 0)))


# Phase A — directed corners.
for i in range(D):                       # fill: 0xA0..0xA7, ends full
    step(1, 0, 0xA0 + i)
step(1, 0, 0xFF)                         # write into full: ignored
step(1, 1, 0xEE)                         # simul wr+rd at full: pop only
for _ in range(D - 1):                   # drain 0xA1..0xA7, ends empty
    step(0, 1, 0x00)
step(0, 1, 0x00)                         # read from empty: ignored
step(1, 1, 0x42)                         # simul wr+rd on empty: write wins
step(0, 1, 0x00)                         # back to empty

# Phase B — randomized traffic (fixed seed).
for _ in range(NVEC_RANDOM):
    step(1 if rng.random() < 0.55 else 0,
         1 if rng.random() < 0.55 else 0,
         rng.randrange(256))

# Phase C — wraparound bursts (laps the pointers several times).
base = 0xC0
for _ in range(4):
    for i in range(5):
        step(1, 0, (base + i) & MASK)
    for _ in range(5):
        step(0, 1, 0x00)
    base = (base + 5) & MASK
for _ in range(20):                      # sustained simultaneous wr+rd
    step(1, 1, rng.randrange(256))
for _ in range(D + 2):                   # final drain + over-read
    step(0, 1, 0x00)

with open("vectors_fifo.txt", "w") as f:
    f.write("%d\n" % len(rows))
    for r in rows:
        f.write("%d %d %02x %d %d %02x\n" % r)

digest = 0
for r in rows:
    digest ^= (r[2] * 131 + r[5] * 17 + r[0] * 5 + r[1] * 3 + r[3] + r[4] * 7)
print("vectors=%d digest=%08x final_depth=%d" % (len(rows), digest & 0xFFFFFFFF, len(q)))
