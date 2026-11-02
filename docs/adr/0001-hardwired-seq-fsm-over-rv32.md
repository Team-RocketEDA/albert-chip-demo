# ADR-0001: Hardwired IRQ-driven sequencer instead of RV32 MCU

Status: accepted.

## Context

The loop-sequencer block (08) was specified with an RV32IM MCU core
(Ibex/PicoRV32 class) running C firmware for recal math, layer advance,
phase switching, boot, and early-exit policy. The actual op list is ~20
fixed operations on a fixed schedule: a CPU buys programmability the
demo never uses, plus a toolchain (riscv-gcc), boot ROM, and
nondeterminism risks.

## Decision

Ship a hardwired synchronous FSM (`rtl/mcu/seq_fsm`, states: boot →
layer_kick → phase_advance → recal_update → early-exit-check → done),
triggered by the same 4 IRQs. Recal math is a fixed-function MUL+shift
datapath. `architecture/firmware/mcu_fw.c` stays as the golden C model;
model and FSM must agree cycle-behaviorally (same IRQ map, same equations).

## Alternatives considered

- RV32 Ibex/PicoRV32 bought IP + C firmware: rejected — toolchain and
  area for zero used programmability.
- Microcoded mini-sequencer: rejected — microcode ROM is a CPU in a
  trench coat; the op list is short enough to hardwire directly.

## Consequences

- No RISC-V toolchain needed for the chip build; host-gcc syntax check
  of the golden model is enough.
- Deterministic cycle behavior; verification = FSM state coverage +
  equation equivalence vs the C model.
- If the op list ever grows past trivial (e.g., adaptive policies),
  revisit: this ADR expires then.
