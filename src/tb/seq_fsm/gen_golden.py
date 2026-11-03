#!/usr/bin/env python3
"""Golden generator + reference model for seq_fsm (stdlib only).

Oracle chain: baked checkpoint bytes (weights/bake/layer0_q_proj.hex) seed
a deterministic RNG that schedules the IRQ stimulus (row/tile/frame pulses,
nops, prefill/decode mode switches, resets). An INDEPENDENT python model of
the seq_fsm equations (mirrors architecture/blocks/08-loop-mem-seq.md D4 +
docs/adr/0001 + firmware/mcu_fw.c layer_done/phase ISR equations, 30 layers)
computes the expected post-edge outputs for every stimulus step.

Outputs (this dir):
  stim.txt     - one "rst prefill row tile frame" binary tuple per step
  expected.hex - one 40-bit packed word per step:
                 {3'b0, done, fifo_rd, olp[5:0], ilp[5:0], psel[3:0],
                  layer[4:0], chunk[5:0], col[7:0]}
"""
import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAKE = HERE / "../../../weights/bake/layer0_q_proj.hex"

NLAYERS = 30
NPHASE = 4

LANE = {  # phase -> (ilp6, olp6) per 09-interface per-phase routing table
    0: (0b000011, 0b011111),  # p0 INPROJ : ilp0-1 / olp0-4
    1: (0b000011, 0b000111),  # p1 OUTPROJ : ilp0-1 / olp0-2
    2: (0b000011, 0b111111),  # p2 GATE/UP  : ilp0-1 / olp0-5
    3: (0b111111, 0b000011),  # p3 DOWN     : ilp0-5 / olp0-1
}


def reset_state():
    return {"layer": 0, "phase": 0, "chunk": 0, "col": 0, "done": 0}


def step(s, rst, row, tile, frame):
    """Reference transition. Priority: rst > frame > tile > row (documented)."""
    if rst:
        return reset_state()
    if s["done"]:
        return dict(s)  # sticky DONE until reset
    if frame:  # layer-boundary IRQ (fw layer_done_isr equation)
        if s["layer"] == NLAYERS - 1:
            s = dict(s); s["done"] = 1
            return s
        return {"layer": s["layer"] + 1, "phase": 0, "chunk": 0,
                "col": 0, "done": 0}
    if tile:  # phase-boundary IRQ (fw phase_isr equation)
        if s["phase"] == NPHASE - 1:
            if s["layer"] == NLAYERS - 1:
                s = dict(s); s["done"] = 1
                return s
            return {"layer": s["layer"] + 1, "phase": 0, "chunk": 0,
                    "col": 0, "done": 0}
        return {"layer": s["layer"], "phase": s["phase"] + 1, "chunk": 0,
                "col": 0, "done": s["done"]}
    if row:  # row/chunk IRQ: advance col, chunk on col wrap
        col = (s["col"] + 1) & 0xFF
        chunk = (s["chunk"] + (1 if col == 0 else 0)) & 0x3F
        s = dict(s); s["col"] = col; s["chunk"] = chunk
        return s
    return dict(s)


def outputs(s, prefill):
    psel = 1 << s["phase"]
    ilp, olp = LANE[s["phase"]]
    fifo_rd = (not s["done"]) and (prefill or s["phase"] == 0)
    word = ((s["done"] & 1) << 36) | ((int(fifo_rd) & 1) << 35) | \
        ((olp & 0x3F) << 29) | ((ilp & 0x3F) << 23) | \
        ((psel & 0xF) << 19) | ((s["layer"] & 0x1F) << 14) | \
        ((s["chunk"] & 0x3F) << 8) | (s["col"] & 0xFF)
    return word


def main():
    raw = BAKE.read_text().split()
    assert len(raw) >= 2048, f"baked table too short: {len(raw)}"
    b = [int(x, 16) for x in raw[:2048]]
    seed = 0
    for x in b[:64]:
        seed = ((seed * 33) + x) & 0xFFFFFFFF
    rng = random.Random(seed)
    print(f"seq_fsm golden: seed=0x{seed:08x} from {len(b)} baked bytes")

    stim = []  # (rst, prefill, row, tile, frame)

    def nop(pf, n=1):
        for _ in range(n):
            stim.append((0, pf, 0, 0, 0))

    # A. reset + idle in prefill
    stim += [(1, 1, 0, 0, 0)] * 3
    nop(1, 2)
    # B. row pulses advance col/chunk
    for _ in range(5):
        stim.append((0, 1, 1, 0, 0))
        nop(1, rng.randrange(0, 3))
    # C. full 30-layer walk via tile IRQs, baked-count row bursts + combos
    bi = 64
    for _ in range(NLAYERS):
        for _ in range(NPHASE):
            for _ in range(1 + (b[bi] % 3)):
                bi += 1
                stim.append((0, 1, 1, 0, 0))
            if b[bi] & 0x3 == 0:  # simultaneous row+tile: tile wins
                stim.append((0, 1, 1, 1, 0))
            else:
                stim.append((0, 1, 0, 1, 0))
            bi += 1
            nop(1, rng.randrange(0, 2))
    # D. post-DONE stickiness under all-IRQ combos
    nop(1, 2)
    stim += [(0, 1, 1, 1, 1), (0, 1, 0, 1, 1), (0, 1, 1, 1, 0)]
    nop(1, 3)
    # E. reset clears done
    stim += [(1, 1, 0, 0, 0)] * 2
    nop(1, 1)
    # F. decode mode (prefill=0): 2 layers via tiles + frame jump + priority
    for _ in range(2):
        for _ in range(NPHASE):
            stim.append((0, 0, 1, 0, 0))
            stim.append((0, 0, 0, 1, 0))
    stim.append((0, 0, 0, 0, 1))  # frame jumps a layer
    nop(0, 1)
    stim.append((0, 0, 1, 1, 1))  # frame wins over tile+row
    nop(0, 2)
    # G. reset, then full 30-layer walk via frame IRQs only
    stim += [(1, 1, 0, 0, 0)] * 2
    for _ in range(NLAYERS):
        stim.append((0, 1, 0, 0, 1))
        nop(1, rng.randrange(0, 2))
    nop(1, 2)

    s = reset_state()
    words = []
    for (rst, pf, row, tile, frame) in stim:
        s = step(s, rst, row, tile, frame)
        words.append(outputs(s, pf))
    assert s["done"] == 1 and s["layer"] == 29, \
        f"script must end DONE@L29, got {s}"

    (HERE / "stim.txt").write_text(
        "".join(f"{a} {b_} {c} {d} {e}\n" for a, b_, c, d, e in stim))
    (HERE / "expected.hex").write_text(
        "".join(f"{w:010x}\n" for w in words))
    print(f"seq_fsm golden: steps={len(stim)} final=done@{s['layer']} "
          f"words={len(words)}")


if __name__ == "__main__":
    sys.exit(main())
