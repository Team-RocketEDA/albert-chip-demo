#!/usr/bin/env python3
"""tile_col.py — first tile-column transient check (blocks/02, 09 §4-6).

One analog column slice: 8 duration-encoded rows (PWL 0->V_read, width
|x|*T_LSB) driving B-source PCM cells (I = V(row)*G, G pinned = programmed
weight), column current integrated on C. ngspice transient, then compare the
final V(col) against the analytic golden. Zero-dependency stdlib + ngspice.
Usage: python3 tile_col.py [--rows N]  (prints table, exits nonzero on FAIL)
"""
import subprocess
import sys
import tempfile
import os

V_READ = 0.2          # V
T_LSB = 10e-9         # s per LSB
C_INT = 10e-12        # F
T_END = 1.5e-6        # s (covers max |x|=127 -> 1.27us + margin)
TOL = 0.02            # 2% pass band

# test vector: 8 rows, mixed magnitudes + one zero (proves no contribution)
X = [100, 64, 0, 32, 127, 16, 80, 48]
W = [90, 20, 50, 70, 10, 100, 40, 60]          # int weights
G = [w * 0.05e-6 for w in W]                   # S (programmed conductance)


def build_cir(path, x=X, g=G):
    L = []
    L.append("* tile column slice: duration-encoded MAC transient")
    for i, v in enumerate(x):
        w = abs(v) * T_LSB
        s = 1.0 if v >= 0 else -1.0
        vr = s * V_READ
        L.append(f"Vrow{i} nrow{i} 0 PWL(0 0 1n 0 1.001n {vr} "
                 f"{w * 1e9:.3f}n {vr} {w * 1e9 + 0.001:.3f}n 0)")
    for i, gi in enumerate(g):
        L.append(f"Bcell{i} 0 ncol I=V(nrow{i})*{gi:.6e}")
    L.append(f"Cint ncol 0 {C_INT:.3e} ic=0")
    L.append(".tran 0.1n 1.5u uic")
    L.append(".control")
    L.append("run")
    L.append("wrdata %s v(ncol)" % path.replace(".cir", ".dat"))
    L.append(".endc")
    L.append(".end")
    with open(path, "w") as f:
        f.write("\n".join(L) + "\n")


def golden(x=X, g=G):
    q = sum(V_READ * gi * (abs(xi) * T_LSB) for xi, gi in zip(x, g))
    return q / C_INT


def run_ngspice(cir):
    r = subprocess.run(["ngspice", "-b", cir], capture_output=True, text=True,
                       timeout=120)
    if r.returncode != 0:
        print(r.stdout[-2000:], file=sys.stderr)
        print(r.stderr[-2000:], file=sys.stderr)
        raise RuntimeError("ngspice failed")
    return r


def read_final(dat):
    vals = []
    with open(dat) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith(("#", "v(", "Index", "Values", "No.")):
                continue
            parts = line.split()
            try:
                vals.append(float(parts[-1]))
            except ValueError:
                continue
    if not vals:
        raise RuntimeError(f"no data parsed from {dat}")
    return vals[-1]


def main():
    with tempfile.TemporaryDirectory() as td:
        cir = os.path.join(td, "tile_col.cir")
        dat = os.path.join(td, "tile_col.dat")
        build_cir(cir)
        run_ngspice(cir)
        v_sim = read_final(dat)
    v_gold = golden()
    err = abs(v_sim - v_gold) / v_gold
    print(f"rows X  = {X}")
    print(f"G (uS)  = {[gi * 1e6 for gi in G]}")
    print(f"V_gold  = {v_gold:.6f} V   (Q/C analytic)")
    print(f"V_sim   = {v_sim:.6f} V   (ngspice transient, T_end={T_END}s)")
    print(f"rel.err = {err * 100:.3f}%   (tol {TOL * 100:.1f}%)")
    print("PASS" if err <= TOL else "FAIL")
    return 0 if err <= TOL else 1


if __name__ == "__main__":
    sys.exit(main())
