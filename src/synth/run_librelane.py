#!/usr/bin/env python3
"""run_librelane.py — drive rocket-engine's digital_flow adapter directly.

Bypasses the (incomplete) engine APIs; imports LibrelaneFlowAdapter as a
library and runs run_digital_flow per block. Tiled flow preserved: one
engine run per macro, never the flat top.

Usage (RE venv python — see build.sh):
  run_librelane.py preflight [block|all]   cheap: version assert + inputs, no run
  run_librelane.py run <block>             HEAVY: full Classic flow (hours for layers)

Job contract honored: sources/top/clock/pdk/scl/tag/timeout/tool_dir/workdir.
Each block runs in src/synth/<block>/engine/ (adapter overwrites design/,
config, logs there — the hand-rolled run.sh files are never touched).
On success the block GDS is copied to tiles/<block>.gds for the stitch.

Env: RE_ROOT (default: repo/../rocket-engine), PDK, TOOL_LIBRELANE_BIN.
tool_dir defaults to the librelane nix env holding the pinned 3.0.17 CLI.
"""
import json
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
RE_ROOT = os.environ.get("RE_ROOT",
                         os.path.join(os.path.dirname(REPO), "rocket-engine"))

sys.path.insert(0, os.path.join(RE_ROOT, ".venv", "lib", "python3.12",
                                "site-packages"))

from rocket_engine.adapters.digital_flow import (  # noqa: E402
    LibrelaneFlowAdapter,
    OPERATION,
)

NIX = "/tmp/librelane-shell/squashfs-root/nix/store"
TOOL_ENV = os.path.join(
    NIX, "1pkfh3p98m8i3jp642n3bznpjfq65i6m-python3-3.13.9-env", "bin")
TOOL_BIN = os.environ.get("TOOL_LIBRELANE_BIN",
                          os.path.join(TOOL_ENV, "librelane"))

CANDIDATE_PDK = [os.environ.get("PDK", ""),
                 os.path.expanduser("~/.volare/sky130A"),
                 os.path.expanduser("~/.local/share/pdk/sky130A"),
                 (os.environ.get("PDK_ROOT") or "") + "/sky130A",
                 "/usr/share/pdk/sky130A"]


def find_pdk():
    """Return the first existing PDK root, or None."""
    for c in CANDIDATE_PDK:
        if c and os.path.isdir(c):
            return c
    return None


def block_sources(block):
    """Return absolute RTL paths from the block's config.json."""
    cfg = os.path.join(REPO, "src", "synth", block, "config.json")
    with open(cfg) as f:
        files = json.load(f)["VERILOG_FILES"]
    return [os.path.join(REPO, p) for p in files]


def all_blocks():
    """Return area blocks plus layer0..29 in run order."""
    areas = ["mac_array", "lm_head", "embed_top", "outproj_tile",
             "rmsnorm_stage", "attention_core", "ffn_tile"]
    return areas + ["layer%d_etched" % i for i in range(30)]


def make_job(block, pdk_root):
    """Build the adapter job dict for one block."""
    timeout = 7200 if block.startswith("layer") else 2400
    return {
        "operation": OPERATION,
        "deck": {"tool": "librelane"},
        "sources": block_sources(block),
        "top": block,
        "clock_port": "clk",
        "clock_period": 25.0,
        "pdk": "sky130A",
        "pdk_root": pdk_root,
        "scl": "sky130_fd_sc_hd",
        "flow": "Classic",
        "tag": "engine_%s" % block,
        "timeout_s": timeout,
        "tool_dir": os.path.dirname(TOOL_BIN),
        "workdir": os.path.join(REPO, "src", "synth", block, "engine"),
    }


def main(argv):
    if len(argv) < 2 or argv[0] not in ("preflight", "run"):
        print(__doc__)
        return 2
    mode = argv[0]
    sel = argv[1] if len(argv) > 1 else "all"
    blocks = all_blocks() if sel == "all" else [sel]
    pdk_root = find_pdk()
    if pdk_root is None:
        print("MISSING PDK root — set PDK=/path/to/sky130A")
        return 1
    adapter = LibrelaneFlowAdapter()
    rc = 0
    for b in blocks:
        job = make_job(b, pdk_root)
        try:
            checked = adapter.preflight(job)
            print("PREFLIGHT-OK %s librelane=%s" % (b, checked["librelane"]))
        except Exception as exc:  # noqa: BLE001 — adapter reports verbosely
            print("PREFLIGHT-FAIL %s: %s" % (b, exc))
            rc = 1
            continue
        if mode == "run":
            native = adapter.execute(job)
            print("RUN-RESULT %s: %s" % (b, json.dumps(native)[:400]))
            for root, _, files in os.walk(
                    os.path.join(job["workdir"], "design", "runs")):
                for fn in files:
                    if fn.endswith(".gds"):
                        src = os.path.join(root, fn)
                        dst = os.path.join(REPO, "tiles", b + ".gds")
                        shutil.copy(src, dst)
                        print("  -> tiles/%s.gds" % b)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
