# L1.8 LOOP_MEM_SEQ (control + memory subsystem)

Scope: owns banks/FIFOs/FSM/counters/recal-sequencer/MCU-if/overflow-if.
Does NOT own X/theta content. Weight-stationary: weights never move; only
token vectors + results stream. DTYPE: tok int8, acc int32, q fix16 Q8.8,
dur 1b pulse (512 steps). Demo S<=64, H=768, FF=3072, L=12 (paper S=512).

Top ports: `x_in: in: Sx768 int8` + valid/ready/tag; `theta_req/ack` handshake
to parent store; `ilp_data[0..5]: out: 128xint8` + valid/ready (to tiles);
`olp_data[0..5]: in: 128xacc` + valid/ready; `sw_result_in: in: 768xacc`;
`x_loopback_out: out: 768xint8` (12x loopback); `recal_trig: in: 1b`;
`overflow_req: out: 32b addr + bus`; `layer_done: out: 1b`; `layer_idx: out: 4b`.
Math: `X(l+1) = Layer(Xl)`, l=0..11; 4 analog phases per layer.

## Inner blocks

A. x_bank_file (token/X SRAM). A1 bank_a 64x768 int8 (49KB demo; 393KB paper)
   + A2 bank_b identical (ping-pong MUX) + A3 resid_bank Sx768 acc
   (192KB demo, holds Xl for Add) + A4 addr_gen ALU (`addr = base+cnt*stride`;
   OPERATION ADD+MUL -> CMOS adder + shift-add multiplier).
   Total ~290KB demo; ~2.3MB paper -> overflow. OSS: OpenRAM 8KB banks tiled.
B. wcal_bank (calibration shadow SRAM; PCM weights stay on tile).
   B1 scale_sram (cols x fix16, ~8.6KB demo); B2 drift_sram (t0 + alpha,
   `s_eff = s*(1+alpha*(t-t0))`; OPERATION MUL+ADD -> fixed-point CMOS ALU);
   B3 per-phase MUX.
C. stream_fifo_array (6 ILP + 6 OLP). Per lane: C1 fifo_mem 1R1W sync FIFO,
   entry 128xint8 (ILP) / 128xacc (OLP), DEPTH = max(8, 512/64) = 8 demo
   (1 vector in flight + prefetch + recal-stall + CDC skid): 6KB ILP + 24KB OLP.
   C2 ptr_add (adder) + C3 depth_cmp (comparator) + C4 credit_counter (adder+reg).
   Throughput: 1 entry/cycle burst, 1 entry/512 analog cycles drain.
   Backpressure: almost_full -> FSM stall, never weight fetch.
   OSS: BaseJump `bsg_fifo_1r1w_small` / Forencich `fifo`; Py: `deque(maxlen)`.
D. layer_fsm + phase_counter. D1 layer_counter 4b (l=0..11); D2 phase_counter
   (p=0..3, PAPER MAPPING ADOPTED — decision recorded in 09-interface.md,
   supersedes the old p0-p2=inProj-thirds note: p0 INPROJ, p1 OUTPROJ, p2 FC1,
   p3 FC2; micro m=0..511 mirror counter); D3 state_reg one-hot 12 states
   (IDLE/LOAD_X/INPROJ/ATTN_WAIT/OUTPROJ/ADDNORM1/FFN1/GELU_WAIT/FFN2/
   ADDNORM2/LOOPBACK/RECAL_CHECK/DONE); D4 phase_decoder MUX
   ((l,p) -> tile_sel/fifo_lane_en/cal_addr).
   fifo_lane_en: {p0: ilp0-1/olp0-4; p1: ilp0-1/olp0-2; p2: ilp0-1/olp0-5;
   p3: ilp0-5/olp0-1+half-share}. tile_sel one-hot-per-phase {row-drivers,
   cap-share select (p2 analog-sum mode), ADC enable}; idle block tristated.
   cal_addr = {block2b, phase2b, tile6b (1-of-34), col/half10b}; FC2 6x entries
   per output (per-chunk coeffs), FC1 1x per output (shared-pair coeff).
   OSS: SystemVerilog FSM + `prim_count`; Py: HF layer loop with phase prints.
E. recal_sequencer. E1 drift_timer comparator (`(now-t0) > T_RECAL`);
   E2 ref_addr_gen ALU; E3 update_alu `s_new = s_old*(ref_exp/ref_meas)`
   (OPERATION DIV+MUL -> fixed-point divider/multiplier, NOT op-amp).
F. mcu_if + ext_overflow. F1 mcu_core RV32 (Ibex/PicoRV32, bought IP: SRAM+ALU+
   regfile, no recurse): microcode for D/E, SW-op dispatch, recal ISR, perf
   counters, HWA table load. Never: PCM weight moves, cycle-critical credit.
   F2 ext_overflow_if AXI4 master: X spill when S*768 exceeds on-chip, embedding
   fetch, theta overflow, trace dump (`addr = BASE + l*S*768 + tok*768`).

## Mapping cheat-sheet (every OPERATION-as-block)

Digital ADD/SUB/PTR/ADDR/COMPARE/MUX/FIFO/SRAM: CMOS stdcells + OpenRAM +
BaseJump FIFOs, never op-amp. Digital MUL/DIV/SHIFT: fixed-point CMOS
multiplier/divider (PULP `fpnew`), integer-emulated in Py. Analog boundary is
INTERFACE ONLY here: duration DAC, PCM summer/integrator, OLP ADC — this block
presents valid/ready + duration-step count.
Unresolved: 4-phase mapping sign-off; drift coeffs/T_RECAL; S target and column
factor (DEPTH 8 vs 16); clock-domain split; pooler placement per-layer vs final.
