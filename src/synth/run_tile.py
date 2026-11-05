#!/usr/bin/env python3
"""Run one albert-chip-demo tile through rocket-engine's LibreLane adapter.

No handrolled chaining: the engine's LibrelaneFlowAdapter stages the
RTL, makes ONE `librelane <config> --run-tag <tag> --pdk sky130A
--overwrite` call, and judges the D11-D27 gates from machine files.

Usage: run_tile.py TILE [TAG]
  TILE      synth dir name under src/synth (e.g. lm_head, mac_array)
  TAG       run variant (default v1_2d); outputs land in out/<TAG>/

Env: RE_ROOT overrides the rocket-engine checkout (default: repo/../rocket-engine).
     PDK_ROOT overrides the ciel PDK root (default: ~/.local/share/pdk).
"""

import glob
import json
import os
import re
import sys
from pathlib import Path

TILE = sys.argv[1]
TAG = sys.argv[2] if len(sys.argv) > 2 else "v1_2d"

ALBERT = Path(__file__).resolve().parents[2]
ENGINE = Path(os.environ.get("RE_ROOT", str(ALBERT.parent / "rocket-engine")))
try:
    # PyPI / installed package first (see pyproject.toml).
    from rocket_engine.adapters.digital_flow import LibrelaneFlowAdapter
except ImportError:  # sister checkout without install
    sys.path.insert(0, str(ENGINE / "src"))
    from adapters.digital_flow import LibrelaneFlowAdapter

tile_dir = ALBERT / "src" / "synth" / TILE
cfg = json.loads((tile_dir / "config.json").read_text())
sources = [str(ALBERT / f) for f in cfg["VERILOG_FILES"]]

bins = sorted(
    glob.glob(
        str(
            ENGINE
            / ".tools/librelane-3.0.17/squashfs-root/nix/store/*-python3.13-librelane-3.0.17/bin"
        )
    )
)
if not bins:
    sys.exit("librelane devshell not provisioned under rocket-engine/.tools")

workdir = tile_dir / "out" / TAG
workdir.mkdir(parents=True, exist_ok=True)

# Forward only the proven waveform-generator set. In particular STA_CORNERS
# (9 corners) and SYNTH_STRATEGY are NOT forwarded: multi-corner STA and
# area-first synthesis multiply runtime versus the default flow.
_FORWARDED_KEYS = (
    "LIB",
    "STD_CELL_LIBRARY",
    "SYNTH_CORNER",
    "DEFAULT_CORNER",
    "DIE_AREA",
    "FP_SIZING",
)
extra = {k: cfg[k] for k in _FORWARDED_KEYS if k in cfg}
# CWD-independent weight paths: every `define MAC "src/...|weights/..."
# in the staged sources gets an absolute-path -D, because LibreLane
# steps run with CWD=step dir (not the repo root). RTL defaults stay
# repo-root-relative for sim/hand flows.
defines = []
seen_macros = set()
for src_file in sources:
    text = Path(src_file).read_text()
    for macro, rel in re.findall(r"`define\s+(\w+)\s+\"((?:src|weights)/[^\"]+)\"", text):
        if macro not in seen_macros:
            seen_macros.add(macro)
            target = ALBERT / rel
            if target.is_file():
                defines.append(f'{macro}="{target}"')
if defines:
    extra["VERILOG_DEFINES"] = defines
# Blackbox interfaces, not elaborated macros: LibreLane's json-header step
# turns these files into -lib blackboxes before hierarchy (the same step
# that hung 70min walking the SRAM). Absolute paths, mirroring sources.
extra["blackbox_models"] = [str(ALBERT / f) for f in cfg.get("blackbox_models", [])]
job = {
    "operation": "run_digital_flow",
    "sources": sources,
    "top": TILE,
    "clock_port": cfg.get("CLOCK_PORT", "clk"),
    "clock_period": cfg.get("CLOCK_PERIOD", 25),
    "pdk": cfg.get("PDK", "sky130A"),
    "pdk_root": os.environ.get("PDK_ROOT", os.path.expanduser("~/.local/share/pdk")),
    # Proven waveform-generator recipe: manual PDK root (no ciel
    # download, read-only PDK safe) + explicit SCL.
    "manual_pdk": True,
    "scl": "sky130_fd_sc_hd",
    "tag": TAG,
    "config": extra,
    "tool_dir": bins[0],
    "workdir": str(workdir),
}

adapter = LibrelaneFlowAdapter()
native = adapter.execute(job)
parsed = adapter.parse(native)
print(f"exit={native['exit_code']} timed_out={native['timed_out']}")
print(f"run_dir={native['run_dir']}")
print(f"gates total={parsed['total']}")
for v in parsed["violations"]:
    print("VIOL:", v.get("stage"), v.get("code"), str(v.get("message"))[:200])
meas = parsed.get("measurements", {})
for k in ("gds", "netlist", "drc_total", "lvs_match", "librelane_version"):
    if k in meas:
        print(f"{k}={meas[k]}")
