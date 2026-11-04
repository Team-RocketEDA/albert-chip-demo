#!/usr/bin/env python3
"""Replicate one tile netlist module into an N-deep stack (render composition).

Reads a rocketeda/netlist/v1 envelope for a single tile top and adds a
new module <top>_x<N> chaining N instances: out[k] -> in[k+1]. Every
other tile port (clk, rst, ...) becomes a shared stack-level port wired
to all copies. Widths are preserved, so buses stay compressed.

Why this is exact for the render: weights live in blackboxed banks, so
every layer copy is topologically identical; only the etched values
differ, and those are inside opaque macros. No yosys needed.

Usage:
  replicate_tile.py tile.json --copies 30 --in x_in --out x_out [--as stack]
  replicate_tile.py --selftest
"""
import json
import sys


def replicate(env, copies, pin_in, pin_out, name=None):
    top = env["top"]
    mods = env["modules"]
    tile = mods[top]
    tports = tile["ports"]
    assert pin_in in tports and pin_out in tports, "chain pins missing on tile top"
    assert tports[pin_in]["direction"] == "input", "chain-in must be input"
    assert tports[pin_out]["direction"] == "output", "chain-out must be output"
    stack_name = name or f"{top}_x{copies}"
    bit_next = [0]
    fresh = lambda w: (lambda s: (bit_next.__setitem__(0, s + w), list(range(s, s + w)))[1])(bit_next[0])

    ports, netnames, cells = {}, {}, {}
    shared = {}  # tile port -> stack netname bits (non-chain ports)

    def chain_net(k):
        nm = f"chain_{k}"
        w = len(tports[pin_out if k else pin_in]["bits"])
        netnames[nm] = {"bits": fresh(w)}
        return nm

    # Chain nets: chain_0 feeds inst_0.in ... inst_{N-1}.out drives chain_N.
    chains = [chain_net(k) for k in range(copies + 1)]
    ports["chain_in"] = {"direction": "input",
                         "bits": netnames[chains[0]]["bits"][:]}
    ports["chain_out"] = {"direction": "output",
                         "bits": netnames[chains[copies]]["bits"][:]}
    for pname, p in tports.items():
        if pname in (pin_in, pin_out):
            continue
        w = len(p["bits"])
        nm = f"shared_{pname}"
        netnames[nm] = {"bits": fresh(w)}
        ports[pname] = {"direction": p["direction"], "bits": netnames[nm]["bits"][:]}
        shared[pname] = netnames[nm]["bits"]
    for k in range(copies):
        conn = {pin_in: netnames[chains[k]]["bits"][:],
                pin_out: netnames[chains[k + 1]]["bits"][:]}
        for pname in shared:
            conn[pname] = shared[pname][:]
        cells[f"inst_{k}"] = {"type": top, "connections": conn}
    mods[stack_name] = {"ports": ports, "cells": cells, "netnames": netnames}
    return stack_name


def selftest():
    env = {"schema": "rocketeda/netlist/v1", "project": "t", "top": "tile",
           "revision": "x", "pdk": "sky130A", "created": "now",
           "modules": {"tile": {"ports": {
               "clk": {"direction": "input", "bits": [0]},
               "d_in": {"direction": "input", "bits": [1, 2]},
               "d_out": {"direction": "output", "bits": [3, 4]}},
               "cells": {}, "netnames": {}}}}
    stack = replicate(env, 3, "d_in", "d_out")
    m = env["modules"][stack]
    assert len(m["cells"]) == 3, "want 3 copies"
    outs = [m["cells"][f"inst_{k}"]["connections"]["d_out"] for k in range(3)]
    ins = [m["cells"][f"inst_{k}"]["connections"]["d_in"] for k in range(3)]
    for k in range(2):
        assert outs[k] == ins[k + 1], f"chain break at {k}"
    assert m["ports"]["chain_in"]["bits"] == ins[0], "stack input must be inst_0 in"
    assert m["ports"]["chain_out"]["bits"] == outs[2], "stack output must be inst_2 out"
    clk_bits = m["netnames"]["shared_clk"]["bits"]
    assert all(m["cells"][f"inst_{k}"]["connections"]["clk"] == clk_bits for k in range(3)), \
        "shared ports must fan out to every copy"
    assert m["ports"]["clk"]["bits"] == clk_bits, "shared port must be exposed on stack"
    print(f"SELFTEST-OK {stack}: 3 cells chained, widths preserved, clk shared")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        import argparse
        ap = argparse.ArgumentParser()
        ap.add_argument("tile", help="tile netlist JSON in")
        ap.add_argument("--copies", type=int, required=True)
        ap.add_argument("--in", dest="pin_in", required=True)
        ap.add_argument("--out", dest="pin_out", required=True)
        ap.add_argument("--as", dest="name", default=None)
        ap.add_argument("-o", "--output", required=True)
        a = ap.parse_args()
        with open(a.tile) as f:
            env = json.load(f)
        tile_top = env["top"]
        stack = replicate(env, a.copies, a.pin_in, a.pin_out, a.name)
        env["top"] = stack
        with open(a.output, "w") as f:
            json.dump(env, f)
        print(f"OK {a.output}: {stack} = {a.copies} x {tile_top}")
