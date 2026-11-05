#!/usr/bin/env python3
"""Translate one rocketeda/netlist/v1 module into an xschem .sym symbol.

Compatibility shim (JOB 1): the albert envelope CANNOT feed the UIUX
.sym parser directly — parseSymAsset (UIUX/src/sym/parser.ts:228)
reads xschem text records (v/G/K/V/S/E/L/B/A/P/T), while the envelope
carries JSON modules with ports {direction, bits} + cells + netnames,
widths as bit arrays, hierarchy as cells whose type names another
module, and no geometry at all. There is no JSON-modules reader in
UIUX (sole call site SchematicSurface.tsx:591-597, fed only by
sky130 fixtures), and neither photonic_matmul specs nor waveform
nl/json_h netlists share this parser either.

So instead of touching any producer or the foreign reader, this shim
emits a minimal valid .sym the EXISTING parser already accepts with
zero changes: header (v/G/K/V/S/E) + L outline + one B-5 pin box per
port (input->in, output->out, width kept whole as a w=<n> attr, never
bit-blasted) + T labels. Foreign wiring (NOT made here): load the
emitted bytes as a SymAssetInput at SchematicSurface.tsx:591-597 with
its SHA-256 digest.

Usage:
  netlist_to_sym.py tile.json --module tile_top -o tile_top.sym [--verbose]
  netlist_to_sym.py --selftest
"""
import argparse
import datetime
import json
import sys

DIRMAP = {"input": "in", "output": "out", "inout": "inout"}


def log(msg, verbose):
    if verbose:
        ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
        print(f"{ts} {msg}", file=sys.stderr)


def to_sym(env, module, verbose=False):
    mods = env["modules"]
    assert module in mods, f"module {module} missing from netlist modules"
    ports = mods[module].get("ports", {})
    assert ports, f"module {module} has no ports"
    ins = [p for p, q in ports.items() if q["direction"] == "input"]
    outs = [p for p, q in ports.items() if q["direction"] != "input"]
    for p, q in ports.items():
        assert q["direction"] in DIRMAP, f"port {p} bad direction {q['direction']}"
    n = max(len(ins), len(outs), 1)
    w, pitch = 300, 60
    h = pitch * (n + 1)
    log(f"module: {module} pins={len(ports)} in={len(ins)} out={len(outs)}", verbose)
    L = [f"v {{xschem version=3.4.0 file_version=1.2}}", "G {}",
         "K {type=subcircuit", 'format="@name @pinlist @symname"',
         'template="name=X1"}', "V {}", "S {}", "E {}",
         f"L 4 0 0 0 {h} {{}}", f"L 4 0 {h} {w} {h} {{}}",
         f"L 4 {w} {h} {w} 0 {{}}", f"L 4 {w} 0 0 0 {{}}"]

    def pin(name, side, k):
        q = ports[name]
        width = len(q["bits"])
        y = pitch * (k + 1)
        x1, x2 = (-5, 5) if side == "left" else (w - 5, w + 5)
        return (f"B 5 {x1} {y - 5} {x2} {y + 5} "
                f"{{name={name} dir={DIRMAP[q['direction']]} w={width}}}")

    for k, p in enumerate(ins):
        L.append(pin(p, "left", k))
    for k, p in enumerate(outs):
        L.append(pin(p, "right", k))
    L.append(f"T {{@symname}} {w // 2} -25 0 0 0.3 0.3 {{}}")
    L.append(f"T {{@name}} {w // 2} 15 0 0 0.2 0.2 {{}}")
    return "\n".join(L) + "\n"


def selftest():
    env = {"schema": "rocketeda/netlist/v1", "project": "t", "top": "tile",
           "revision": "x", "pdk": "sky130A", "created": "now",
           "modules": {"tile": {"ports": {
               "clk": {"direction": "input", "bits": [0]},
               "d_in": {"direction": "input", "bits": [1, 2]},
               "d_out": {"direction": "output", "bits": [3, 4]}},
               "cells": {}, "netnames": {}}}}
    sym = to_sym(env, "tile")
    assert sym.startswith("v {xschem"), "missing v header"
    assert "K {type=subcircuit" in sym, "missing K record"
    pins = [ln for ln in sym.splitlines() if ln.startswith("B 5 ")]
    assert len(pins) == 3, f"want 3 pins, got {len(pins)}"
    assert "{name=d_in dir=in w=2}" in sym, "bus width attr lost"
    assert "{name=d_out dir=out w=2}" in sym, "out pin wrong"
    assert "{name=clk dir=in w=1}" in sym, "shared pin wrong"
    print("SELFTEST-OK netlist_to_sym: 3 pins, dirs mapped, widths kept")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        ap = argparse.ArgumentParser()
        ap.add_argument("netlist", help="rocketeda/netlist/v1 JSON in")
        ap.add_argument("--module", default=None, help="module to render (default: top)")
        ap.add_argument("-o", "--output", required=True)
        ap.add_argument("--verbose", action="store_true",
                        help="echo timestamped stage markers to stderr (default off)")
        a = ap.parse_args()
        with open(a.netlist) as f:
            env = json.load(f)
        log(f"read: {a.netlist} top={env['top']}", a.verbose)
        sym = to_sym(env, a.module or env["top"], a.verbose)
        with open(a.output, "w") as f:
            f.write(sym)
        log(f"write: {a.output}", a.verbose)
        print(f"OK {a.output}")
