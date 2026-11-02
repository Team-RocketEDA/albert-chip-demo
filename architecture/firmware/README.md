# MCU control spec — GOLDEN C MODEL for the hardwired seq FSM (architecture, pre-silicon)

Status: GOLDEN MODEL ONLY — no processor ships. Equations below are
written in RV32IM-subset C (MUL/MULH only, no DIV/REM; division by shift or
Newton-Raphson) so each maps 1:1 onto the hardwired FSM datapath (M-mode
`mtvec` map + custom MMIO kept identical). Everything time-critical
(phase stepping, stall) is HW FSM; the model owns layer boundaries,
recalibration math, boot/config, and policy.

## IRQ map

| IRQ | Source | Action |
|---|---|---|
| 0 | recal_timer `(now-t0) > T_RECAL` | recal ISR: ref read → scale update → cal SRAM rewrite |
| 1 | layer_done (l==11 path or per-layer) | layer-boundary ISR: next-layer kick / pooler steer / done flag |
| 2 | fifo_err (overflow/underflow any lane) | error ISR: freeze FSM, latch status, halt |
| 3 | olp_phase_done | phase-boundary ISR: switch cal bank, advance phase strobe |

`almost_full` stall is pure HW (credit counters), never an IRQ — weights stay
stationary with zero firmware involvement.

## Instruction subset (the only ones the firmware may emit)

`LUI AUIPC JAL JALR BEQ BNE BLT BGE BLTU BGEU LB LH LW LBU LHU SB SH SW
ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI ADD SUB SLL SLT SLTU XOR SRL
SRA OR AND MUL MULH FENCE ECALL MRET` + CSR (`CSRRW/CSRRS`) for
mstatus/mie/mtvec/mscratch/mcause/mepc. No DIV/REM, no F/D, no C (optional).

## MMIO map (32-bit, base 0x4000_0000)

```text
0x00 CTRL      [0]=seq_start [1]=pooler_tap_en [2]=error_halt (FW asserts)
0x04 STATUS    [0]=busy [3:1]=phase [7:4]=layer [8]=recal_pending [9]=fifo_err
0x08 LAYER_CFG {S[7:0], num_layers[3:0]}
0x0C T_RECAL   drift timer period
0x10 CAL_BASE  cal bank window {layer,block,phase} (08-D4 22b addr, low 16b zero)
0x14 REF_EXP   expected ref-column digitized value (per block)
0x18 REF_MEAS  last ref-column measured value (HW-written)
0x1C SCORE_C   correct counter (07 scoreboard, read-only)
0x20 SCORE_T   total counter (07 scoreboard, read-only)
0x24 MARGIN_TH early-exit margin threshold (paper L116 policy; 0xFFFFFFFF = off)
0x28 MARGIN    current tap margin = max-runnerup (07, read-only)
0x2C IRQ_ARG   trap context {layer[23:20],block[19:18],phase[17:16],tile[15:10]}
0x30 FW_STATUS firmware heartbeat/error code
```

Trap: `mtvec` direct to `trap_entry` (naked: save ra/t0, `csrr a0,mcause`,
`jal trap_dispatch`, restore, `mret`). Custom encoding: mcause low 2 bits =
IRQ# (0 recal, 1 layer, 2 fifo_err, 3 phase). `trap_dispatch` decodes +
reads IRQ_ARG, so ISRs take no args. Score pack is 16b+16b (subsets ≤1000).

## Handlers (full C in mcu_fw.c)

## Handlers (full C in mcu_fw.c)

- `recal_isr()`: decode IRQ_ARG → layer/block/phase/tile; read REF_MEAS,
  fixed-point `s_new = s_old * ref_exp/ref_meas` via MUL+qrecip (no DIV),
  rewrite that use's cal SRAM slice, clear timer.
  Deadline: finishes inside one OLP drain wave.
- `layer_done_isr()`: if MARGIN > MARGIN_TH at any layer, stop early and
  report (paper L116 policy); else if l<11 kick next layer (CTRL.seq_start,
  ping-pong swap is HW); if l==11 steer bank to pooler CLS MUX, set done,
  copy SCORE_C/T.
- `phase_isr()`: CAL_BASE = IRQ_ARG bank bits (next phase's resident coeff
  set — recal shadow already resident, zero PCM traffic).
- `error_isr()`: freeze, latch STATUS, heartbeat error code, halt.
- `boot()`: load cal defaults + HWA tables + gamma/beta + LAYER_CFG, program
  weights assumed done (closed-loop external), verify via ref-column read,
  start layer 0, WFI loop.

Cycle budget: ISRs are tens of instructions (loads, MULH, stores, CSR);
all fit inside inter-phase OLP drain gaps. Core sleeps (WFI) otherwise —
control plane costs ~nothing next to 262k-MAC analog integrations.
