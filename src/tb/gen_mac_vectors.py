#!/usr/bin/env python3
"""Independent pure-stdlib golden oracle for the MAC family (plan step 1).

Never touches the RTL: unbounded python ints model the exact integer dot
product, wrapped to signed-32 for the accumulator verdicts. Vectors cover
randomized int8 plus saturation corners (-128/-127/127 extremes, accum
wrap seeds are exercised as directed cases inside the testbenches).

Outputs (hex for $readmemh):
  mac_a.hex / mac_b.hex / mac_golden.hex       N_MAC running accumulations
  array_a.hex / array_b.hex / array_golden.hex M_ARR rows of P lanes + accum
  dotK_a.hex / dotK_b.hex / dotK_golden.hex    M_DOT full K-dots
Deterministic: random.Random(SEED).
"""
import random

SEED = 20261102
N_MAC = 256
P_ARR = 8
M_ARR = 128
K_DOT = 16
M_DOT = 64
ACC_SEED = 1000  # nonzero chain seed, so acc_in path is covered

rng = random.Random(SEED)


def s8(v):
    v &= 0xFF
    return v - 256 if v >= 128 else v


def wrap32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v >= 0x80000000 else v


def h8(v):
    return "%02x" % (v & 0xFF)


def h32(v):
    return "%08x" % (v & 0xFFFFFFFF)


def corners8():
    return [-128, -127, -1, 0, 1, 126, 127]


def rand8():
    return rng.randrange(-128, 128)


# ---- mac_unit: chained running sum ----
pairs = [(-128, -128), (127, 127), (-128, 127), (127, -128),
         (-128, 1), (1, -128), (127, -1), (-1, 127),
         (-128, 0), (0, -128), (0, 0), (-128, -127),
         (127, -128), (126, 126), (-128, 127), (127, 127)]
while len(pairs) < N_MAC:
    pairs.append((rand8(), rand8()))
acc = ACC_SEED
gold_mac = []
for (a, b) in pairs:
    acc = wrap32(acc + a * b)
    gold_mac.append(acc)

# ---- mac_array: P-lane rows, chained ----
rows = []
rows.append(([-128] * P_ARR, [-128] * P_ARR))   # max +psum corner
rows.append(([127] * P_ARR, [127] * P_ARR))
rows.append(([-128] * P_ARR, [127] * P_ARR))   # max -psum corner
rows.append(([127] * P_ARR, [-128] * P_ARR))
rows.append(([0] * P_ARR, [-128] * P_ARR))
alt_a = [127 if j % 2 else -128 for j in range(P_ARR)]
alt_b = [-128 if j % 2 else 127 for j in range(P_ARR)]
rows.append((alt_a, alt_b))
while len(rows) < M_ARR:
    rows.append(([rand8() for _ in range(P_ARR)],
                 [rand8() for _ in range(P_ARR)]))
acc = ACC_SEED
gold_arr = []
for (ra, rb) in rows:
    acc = wrap32(acc + sum(x * y for x, y in zip(ra, rb)))
    gold_arr.append(acc)

# ---- dotK: full K-dots, zero-based ----
dots = []
dots.append(([-128] * K_DOT, [-128] * K_DOT))
dots.append(([127] * K_DOT, [127] * K_DOT))
dots.append(([-128] * K_DOT, [127] * K_DOT))
dots.append(([0] * K_DOT, [rand8() for _ in range(K_DOT)]))
while len(dots) < M_DOT:
    dots.append(([rand8() for _ in range(K_DOT)],
                 [rand8() for _ in range(K_DOT)]))
gold_dot = [wrap32(sum(x * y for x, y in zip(ra, rb))) for (ra, rb) in dots]


def packed(row):
    # lane j occupies bits [8j+7:8j]; first hex chars = MSB = top lane
    return "".join(h8(v) for v in reversed(row))


with open("mac_a.hex", "w") as f:
    f.write("\n".join(h8(a) for (a, b) in pairs) + "\n")
with open("mac_b.hex", "w") as f:
    f.write("\n".join(h8(b) for (a, b) in pairs) + "\n")
with open("mac_golden.hex", "w") as f:
    f.write("\n".join(h32(g) for g in gold_mac) + "\n")
with open("array_a.hex", "w") as f:
    f.write("\n".join(packed(r) for (r, _) in rows) + "\n")
with open("array_b.hex", "w") as f:
    f.write("\n".join(packed(r) for (_, r) in rows) + "\n")
with open("array_golden.hex", "w") as f:
    f.write("\n".join(h32(g) for g in gold_arr) + "\n")
with open("dotK_a.hex", "w") as f:
    f.write("\n".join(packed(r) for (r, _) in dots) + "\n")
with open("dotK_b.hex", "w") as f:
    f.write("\n".join(packed(r) for (_, r) in dots) + "\n")
with open("dotK_golden.hex", "w") as f:
    f.write("\n".join(h32(g) for g in gold_dot) + "\n")

print("seed=%d nmac=%d narr=%d(px%d) ndot=%d(kx%d) acc_seed=%d" %
      (SEED, N_MAC, M_ARR, P_ARR, M_DOT, K_DOT, ACC_SEED))
print("mac[0..3] gold:", [gold_mac[i] for i in range(4)])
print("arr[0..3] gold:", [gold_arr[i] for i in range(4)])
print("dot[0..3] gold:", [gold_dot[i] for i in range(4)])
