# L1.8 LOOP_MEM_SEQ (control + memory subsystem)

Scope: owns banks/FIFOs/FSM/counters/recal-sequencer/MCU-if/overflow-if.
Does NOT own X/theta content. Weight-stationary: weights never move; only
token vectors + results stream. DTYPE: tok int8, acc int32, q fix16 Q8.8.
Demo S<=64, H=576, FF=1536, L=30 (HF config: max positions 2048; demo
picks S=64 max for the 1-tile proxy).

Top ports: `x_in: in: Sx576 int8` + valid/ready/tag; `theta_req/ack` handshake
to parent store; `ilp_data[0..5]: out: 128xint8` + valid/ready (to tiles);
`olp_data[0..5]: in: 128xacc` + valid/ready; `sw_result_in: in: 576xacc`;
`x_loopback_out: out: 576xint8` (30x loopback); `recal_trig: in: 1b`;
`overflow_req: out: 32b addr + bus`; `layer_done: out: 1b`; `layer_idx: out: 5b`.
Math: `X(l+1) = Layer(Xl)`, l=0..29; 4 digital MAC phases per layer.

## Inner blocks

A. x_bank_file (token/X SRAM). A1 bank_a 64x576 int8 (36KB demo)
   + A2 bank_b identical (ping-pong MUX) + A3 resid_bank Sx576 acc
   (144KB demo, holds Xl for Add) + A4 addr_gen ALU (`addr = base+cnt*stride`;
   OPERATION ADD+MUL -> CMOS adder + shift-add multiplier) + A5 KV-cache AGU
   (append pointer per layer for the 2048-deep decode window, prefill vs
   decode base).
   Total ~216KB demo -> overflow parked (BUILD_MAP). OSS: OpenRAM 8KB banks
   tiled.
B. wcal_bank (requant-coeff SRAM; digital scales, no drift exists).
   Each of the 30 layer-uses needs its own columnwise
   {slope, offset} set, so wcal holds all 30 uses resident (loaded once,
   weight-stationary spirit). Per use: ncols_out x {slope,offset} fix16 =
   4B/entry — inProj QKV 960 (576+192+192) = 3.75KB, outProj 576 = 2.25KB,
   SwiGLU gate 1536 + up 1536 + down 1536 = 18KB; 24KB/use x 30 uses = 720KB
   demo (S-independent: cols only). B1 scale_sram 720KB; B2 spare_sram (~0.2KB,
   reserved); B3 per-phase MUX.
C. stream_fifo_array (6 ILP + 6 OLP). Per lane: C1 fifo_mem 1R1W sync FIFO,
   entry 128xint8 (ILP) / 128xacc (OLP), DEPTH = max(8, 512/64) = 8 demo
   (1 vector in flight + prefetch + recal-stall + CDC skid): 6KB ILP + 24KB OLP.
   C2 ptr_add (adder) + C3 depth_cmp (comparator) + C4 credit_counter (adder+reg).
   Throughput: 1 entry/cycle burst, 1 entry/chunk-group drain.
   Backpressure: almost_full -> FSM stall, never weight fetch.
   OSS: BaseJump `bsg_fifo_1r1w_small` / Forencich `fifo`; Py: `deque(maxlen)`.
D. layer_fsm + phase_counter. D1 layer_counter 5b (l=0..29); D2 phase_counter
   (p=0..3: p0 INPROJ, p1 OUTPROJ, p2 GATE/UP, p3 DOWN; micro m=0..2047
   position mirror counter); D3 state_reg one-hot 13 states
   (IDLE/LOAD_X/P0/ATTN/P1/RMS1/P2/SILU/P3/RMS2/LOOPBACK/RECAL_CHECK/DONE);
   D4 phase_decoder MUX ((l,p) -> tile_sel/fifo_lane_en/cal_addr).
   fifo_lane_en: {p0: ilp0-1/olp0-4; p1: ilp0-1/olp0-2; p2: ilp0-1/olp0-5;
   p3: ilp0-5/olp0-1+half-share}. tile_sel one-hot-per-phase {chunk counter
   enables, coeff-bank select, mac_array lane enables}; idle block clock-gated.
   cal_addr = {layer5b, block2b, phase2b, chunk6b, col8b}
   (23b: layer selects 1 of the 30 resident coeff sets, then block/phase/
   chunk/col); SwiGLU gate/up 6x, down 3x, Q 3x, K/V 1x per output
   (per-chunk coeffs).
   OSS: SystemVerilog FSM + `prim_count`; Py: HF layer loop with phase prints.
E. recal_sequencer (periodic coeff-set rotation + checksum verify; digital
   has no drift, so this is a use-index advance, not a compensation loop).
   E1 rot_timer comparator (`frame_cnt > T_RECAL`); E2 ref_addr_gen ALU
   (points at the next resident layer-use coeff set); E3 verify_alu
   `ok = (crc(coeff_set) == golden)` (OPERATION CRC+XOR -> fixed-point
   ALU; on mismatch: reload set from host image, never a weight move).
F. mcu_if + ext_overflow. F1 seq_fsm: HARDWIRED synchronous sequencer
   (no RV32 — the op list is ~20 fixed ops, a CPU earns nothing here).
   IRQ-triggered states: boot → layer_kick → phase_advance → recal_update →
   done. Recal math is fixed-function CRC+compare datapath
   (same equation as the C golden model). Never: weight moves,
   cycle-critical credit.
   PARKED (not on inference path): F2 ext_overflow AXI (S<=64 never spills;
   re-add only if S outgrows SRAM), perf counters + trace dump (testbench-only,
   see TESTBENCH.md).
   Control pinned: IRQ map + handler equations in C at
   architecture/firmware/ (README + mcu_fw.c) AS GOLDEN MODEL ONLY —
   the shipped control is the F1 hardwired FSM above. C model and FSM
   must agree cycle-behaviorally (same IRQ map, same equations).
   F2 ext_overflow_if AXI4 master: X spill when S*576 exceeds on-chip, embedding
   fetch, theta overflow, trace dump (`addr = BASE + l*S*576 + tok*576`).

## Mapping cheat-sheet (every OPERATION-as-block)

Digital ADD/SUB/PTR/ADDR/COMPARE/MUX/FIFO/SRAM: CMOS stdcells + OpenRAM +
BaseJump FIFOs, never op-amp. Digital MUL/DIV/SHIFT: fixed-point CMOS
multiplier/divider (PULP `fpnew`), integer-emulated in Py. No analog boundary
exists in this package: this block presents valid/ready + chunk count on every
tile-facing port.
Pinned in PARAMS §8 (phase map locked p0..p3; requant rotation + T_RECAL
sweep) + §1 (S≤64 demo) + §5 (DEPTH 8) + §6 (single-clock) + §7 (final
LM head, no snoop).

## Interface integration (09-interface.md)

This block DRIVES the 09-#2 Phase Sequencer outputs (`layer_idx`, `phase`,
`tile_sel` 4b one-hot/phase, `fifo_lane_en` 6+6, `cal_addr`) and PRESENTS
the tile-facing frontier: 6× ILP (`128xint8`+valid/ready) + 6× OLP
(`128xacc`+valid/ready) + chunk count. Backpressure `almost_full` →
FSM stall, never a weight fetch. Digital legs (attention, SwiGLU/SiLU,
RMSNorm, LM head) re-enter through the same valid/ready domain.
Single-clock per PARAMS §6; LM-head final per §7.
