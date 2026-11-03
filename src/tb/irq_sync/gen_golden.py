#!/usr/bin/env python3
"""Independent pure-stdlib golden oracle for irq_sync (plan step 4).

Never touches the RTL: models the 2-flop synchronizer bit-exactly. Cycle
discipline matches the testbench exactly (10 ns clock):

  - each cycle k: TB waits for negedge, delays by the row's offset_ns,
    drives irq_async, then samples irq #1 after the next posedge.

So irq sampled #1 after posedge P_k (which latched async sampled at
P_{k-1} through the second flop) equals the async value driven during
cycle k-1: exp[k] = val[k-1], val[-1] = 0. (Drive happens at negedge+off,
half a cycle before the sampling posedge, so the row-visible lag is 1;
the flop-to-flop delay is still exactly 2 clocks. async starts 0 and the
bench idles 2 clocks, so row 0 expects 0.)

Async changes land mid-cycle (offset 1..9 ns after negedge), so the
stimulus is genuinely asynchronous to clk, including 1-cycle pulses.

Outputs: vectors_irq.txt (row 1 = vector count N, then N rows of
`async_val offset_ns exp_irq`). Deterministic: random.Random(SEED).
"""
import random

SEED = 20261104
N = 240

rng = random.Random(SEED)
vals = []
cur = 0
for k in range(N):
    if rng.random() < 0.30:
        cur = 1 - cur if rng.random() < 0.8 else rng.randrange(2)
    vals.append(cur)
# force a few 1-cycle pulses (worst case for a synchronizer to catch)
for k in (50, 120, 200):
    vals[k] = 1
    vals[k + 1] = 0

# Never exactly 5 ns: negedge+5 ns IS the next posedge, a zero-delay race
# with no correct answer (real async edges have measure-zero hit chance;
# silicon resolves it as metastability, not a logic value).
SAFE_OFFS = [1, 2, 3, 4, 6, 7, 8, 9]
offsets = [rng.choice(SAFE_OFFS) for _ in range(N)]
exps = [(vals[k - 1] if k >= 1 else 0) for k in range(N)]

with open("vectors_irq.txt", "w") as f:
    f.write("%d\n" % N)
    for k in range(N):
        f.write("%d %d %d\n" % (vals[k], offsets[k], exps[k]))

print("vectors=%d pulses=%d ones=%d" % (N, 3, sum(exps)))
