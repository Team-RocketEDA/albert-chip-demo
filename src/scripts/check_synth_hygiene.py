#!/usr/bin/env python3
"""check_synth_hygiene.py — $readmemh hygiene report for synth sources.

Rule (VIA_ROM_MVP_PLAN.md): $readmemh is testbench-only. Synthesis
gets weights as metaprogrammed literals, never as preloaded memories.

Classification per call site in src/components/*.v:
  GUARDED    — behind a parameter-constant condition false by default
               (e.g. `if (INIT_FILE != "")` with INIT_FILE=""), or an
               ifdef; yosys folds the branch away, no file is opened.
  GRANDFATHERED — unconditional $readmemh that must become a literal
               on the dev branch (SYNTH view). Sim may still use it.
  TESTBENCH  — anything under src/tb/ or tb_* (always allowed).

Report mode always exits 0. --strict exits 1 if any GRANDFATHERED
site remains (activate once the literal emitter lands).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMP = ROOT / "src" / "components"

GUARD_RES = (r"if\s*\(\s*INIT_FILE\s*!=\s*\"\"",
             r"if\s*\(\s*!USE_SRAM_W\s*\)",
             r"ifdef\s+\w+", r"ifndef\s+\w+")


def classify(path, lineno, lines):
    # Same line (one-line if) plus enclosing block above it.
    window = "\n".join(lines[max(0, lineno - 9):lineno])
    if re.search("|".join(GUARD_RES), window):
        return "GUARDED"
    return "GRANDFATHERED"


def main():
    strict = "--strict" in sys.argv
    grandfathered = []
    guarded = 0
    for path in sorted(COMP.glob("*.v")):
        lines = path.read_text().splitlines()
        for i, line in enumerate(lines, 1):
            if re.search(r"\$readmemh?b?\(", line) and "ROMs (" not in line:
                if "$readmemh" not in line and "$readmemb" not in line:
                    continue
                kind = classify(path, i, lines)
                if kind == "GUARDED":
                    guarded += 1
                else:
                    grandfathered.append(f"{path.name}:{i}: {line.strip()[:90]}")
    print(f"GUARDED sites (folded away in synth): {guarded}")
    print(f"GRANDFATHERED sites (need literals): {len(grandfathered)}")
    for g in grandfathered:
        print(f"  {g}")
    print("TESTBENCH $readmemh: allowed (src/tb/, tb_* — not listed).")
    # Section 2: effective reads — non-empty INIT bindings at
    # instantiation sites. These are what the literal emitter must
    # replace (defaults of "" never open a file, even unguarded).
    print("EFFECTIVE non-empty INIT bindings (need literals):")
    bound = 0
    for path in sorted(COMP.glob("*.v")):
        for i, line in enumerate(path.read_text().splitlines(), 1):
            for m in re.finditer(r"\.(INIT_FILE|WQ_FILE|WK_FILE|WV_FILE|WO_FILE|"
                                 r"WQ_WIDE_FILE|WK_WIDE_FILE|WV_WIDE_FILE|"
                                 r"WO_WIDE_FILE|WG_FILE|WU_FILE|WD_FILE|GN_FILE|"
                                 r"GN1_FILE|GN2_FILE|COS_F|SIN_F)\(([^)]+)\)", line):
                if m.group(2).strip() not in ('""',):
                    print(f"  {path.name}:{i}: .{m.group(1)}({m.group(2).strip()[:60]})")
                    bound += 1
    print(f"({bound} effective bindings)")
    if strict and grandfathered:
        print("STRICT: failing on grandfathered sites.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
