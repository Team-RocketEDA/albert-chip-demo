#!/usr/bin/env python3
"""tb_scoreboard.py — logits in, accuracy table out.

Reads lines `seq true_label logit0 logit1 [logit2...]`, argmaxes, accumulates
correct/total overall and per task prefix (seq id format task:index). Prints
a GLUE-style table. Usage: tb_scoreboard.py < preds.txt
"""
import sys
from collections import defaultdict

correct = total = 0
per_task = defaultdict(lambda: [0, 0])
for line in sys.stdin:
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    parts = line.split()
    seq, true = parts[0], int(parts[1])
    logits = [float(x) for x in parts[2:]]
    pred = max(range(len(logits)), key=logits.__getitem__)
    task = seq.split(":")[0] if ":" in seq else "all"
    total += 1
    per_task[task][1] += 1
    if pred == true:
        correct += 1
        per_task[task][0] += 1

print(f"{'task':<12}{'acc':>8}{'n':>8}")
for task in sorted(per_task):
    c, n = per_task[task]
    print(f"{task:<12}{c / n * 100:7.2f}%{n:8d}")
print(f"{'OVERALL':<12}{correct / total * 100 if total else 0:7.2f}%{total:8d}")
