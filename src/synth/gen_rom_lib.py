#!/usr/bin/env python3
"""gen_rom_lib.py — emit a minimal liberty stub for an etched/macro ROM.

LibreLane `blackbox_models` only truly blackboxes `.lib` entries
(`read_liberty -lib -setattr blackbox`); `.v` entries get hierarchy only and
their bodies still get mapped. So every ROM/macro that stays a box through
synth needs one of these stubs: cell identity + pins + area for the
unmapped-cells checker and STA. No timing arcs — the box breaks timing by
design; logic-side timing closes without it.

Usage:
  python3 src/synth/gen_rom_lib.py --name lm_wrom --addr-w 4 \
      --dout-w 4608 --area 50000 -o src/synth/lm_head/lm_wrom.lib

Pin widths MUST match the synthesized parameters (e.g. addr width 4 =
$clog2(16) for VROWS=16). The area is a placeholder until the via-ROM macro
is sized — it only feeds the area report, never P&R.
"""
import argparse


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--addr-w", type=int, required=True)
    ap.add_argument("--dout-w", type=int, required=True)
    ap.add_argument("--area", default="50000",
                    help="placeholder cell area in um^2 (via-ROM sizes it)")
    ap.add_argument("-o", "--output", required=True)
    a = ap.parse_args()

    pins = []
    for i in range(a.addr_w):
        pins.append(
            f'    pin("addr[{i}]") {{\n'
            f'      direction : input;\n'
            f'      capacitance : 0.01;\n'
            f'    }}'
        )
    for i in range(a.dout_w):
        pins.append(
            f'    pin("dout[{i}]") {{\n'
            f'      direction : output;\n'
            f'      capacitance : 0.01;\n'
            f'      max_capacitance : 0.5;\n'
            f'    }}'
        )
    text = (
        f'library({a.name}_lib) {{\n'
        f'  delay_model : table_lookup;\n'
        f'  time_unit : "1ns";\n'
        f'  voltage_unit : "1V";\n'
        f'  current_unit : "1mA";\n'
        f'  pulling_resistance_unit : "1kohm";\n'
        f'  capacitive_load_unit(1,1fF);\n'
        f'  leakage_power_unit(1,1nW);\n'
        f'  cell({a.name}) {{\n'
        f'    area : {a.area};\n'
        + "\n".join(pins)
        + '\n  }\n}\n'
    )
    with open(a.output, "w") as f:
        f.write(text)
    print(f"wrote {a.output} ({a.addr_w} addr + {a.dout_w} dout pins)")


if __name__ == "__main__":
    main()
