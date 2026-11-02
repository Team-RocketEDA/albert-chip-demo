# 00 — Shared primitive library (all L1 blocks reference this)

No block invents its own leaves. Digital leaves stop at Section C / B-digital
rows; analog leaves stop at Section A / B-analog rows. Weight-stationary holds
throughout: weights pinned in PCM tiles or shadow SRAM, only tokens move.

## A. Analog workhorse blocks

| Block | Function | Key equation | Serves demo op |
|---|---|---|---|
| OTA / diff pair | Core transconductor, readout front-end | Av = gm·ro | Every MAC column preamp |
| Two-stage Miller op-amp | General high-gain amp | Av = gm1(ro1‖ro2)·gm2(ro5‖ro6) | Column integrator/summer, TIA, DAC driver, ADC residue amp |
| Folded cascode | High-gain stage, wide ICMR at low VDD | Av ≈ gm1·[(gm3·ro3·ro1)‖(gm5·ro5·ro7)] | Fast column integrator, bandgap/LDO error amp |
| Current mirror | Copy/scale bias + signal current | Iout = Iref·(W/L)2/(W/L)1 | DAC row-driver refs, OTA loads, PCM read-bias trees |
| Cascode mirror | High-ro accurate mirror | ro ≈ gm·ro² | High-accuracy row IDACs, integrator loads |
| Wilson mirror | High-ro self-compensated mirror | ro ≈ gm·ro²/2 | Alternate bias branches in DAC/bias-gen |
| Bandgap reference | PVT-stable voltage | Vref ≈ Vbe + K·Vt·ln(N) ≈ 1.2V | ADC/DAC full-scale, PCM V_read, comparator thresholds |
| LDO / regulator | Clean analog supply off noisy rail | Vout = Vref·(1+R1/R2) | Tile analog islands vs digital switching |
| Bias-gen + startup | PTAT/constant-gm current + kick | gm = 1/R loop | Global gm/I bias to OTAs/DACs/comparators |
| Comparator + Schmitt | 1-bit decide + flags | Trips Vref ± hysteresis | SAR/ramp ADC, duration sign, FIFO full/empty |
| Sample-and-hold | Acquire/hold column voltage | Vhold = Vin(t_sample) | ADC front-end per MAC column |
| SC integrator | Discrete-time MAC accumulate | Vout[n] = Vout[n-1] − (C1/C2)·Vin[n] | Duration-MAC + MSB/LSB/chunk accumulate |
| SC differentiator | Edge/high-pass subtract | Vout ≈ −(C1/C2)(Vin[n]−Vin[n-1]) | Drift-recal baseline subtraction, offset cancel |
| PGA / VGA | Programmable range/gain | Vout = −(Rf/Rin)·Vin, Rf switched | Per-col slope-calib amp, ADC driver match |
| Gilbert mixer/mult | 4-quadrant multiply reference | Iout ≈ (2·Ibias/Vt²)·Vrf·Vlo | PCM I=V·G counterpart; GELU tanh-LUT analog ref |
| TIA | Current-to-voltage column readout | Vout = −Rf·Iin | PCM column summer alternative to integrator |
| Charge pump | Above-rail/below-ground bias | Vout ≈ N·Vdd − drops | Program-path HV gate drive only, not inference |
| Level shifter | Cross low-high / analog-digital domains | Out = in shifted to VDDH | DAC latch-to-row-driver, tile_ctrl enables |
| VCO | Clock/phase timebase | fout ≈ Imax/(2·N·C·Vswing) | Duration T_on, SAR/ramp ADC clock, system PLL |
| Peak detector/rectifier | Max/envelope capture | Vpeak ≈ max‖Vin‖ (superdiode) | ADC full-scale set, MAC-output debug |
| Instrumentation amp | Precision diff readout, high CMRR | Vout = (1+2R/Rg)(V+−V−) | Differential ± PCM pair subtract |
| Log amp | Compressive nonlinearity (research) | Vout = −Vt·ln(Vin/(R·Is)) | Research only; activations stay digital |
| ESD / clamp diodes | Pad protection | Clamp ≈ VDD+0.7V / VSS−0.7V | Every tile analog I/O pad |

## B. Multiplication zoo

| Technique | Math | Fit | Character |
|---|---|---|---|
| Booth radix-4 | P=A·B, recoded partial products | Digital MAC PEs | Exact, ~½ PPs, 1-cycle, high area |
| Wallace tree | 3:2 CSA parallel reduction + CPA | High-throughput MAC lanes | Exact, fastest ~logN, largest area |
| Dadda | Minimal-height CSA column reduction | MAC arrays where area > speed | Exact, near-Wallace, less area |
| Fixed-point MAC lane | Y += A·B, wide accum + round/sat | Every digital island | Exact-to-LSB then quantized, 1 MAC/cycle/PE |
| Carry-save accumulator | Redundant S,C held, 1 CPA at end | Systolic accum, chunk recombine, mean/var trees | Bit-exact, O(1)/add + 1 CPA |
| Shift-add | P = Σ b_k·A<<k iterative | Calib slope, requant, NR iters, serial PEs | Exact, tiny area, N-cycle |
| LUT-based mult | P ≈ LUT(v) + slope·delta | softmax exp/recip, sqrt seed, GELU tanh | Approx, 1–2 cyc, ROM+mult+add |
| Log-domain mult | logP = logA+logB, add, antilog | Requant/scale, approx scores only | Approx, small, needs converters |
| Translinear/Gilbert analog | Iout ≈ Ix·Iy/Ibias | Rejected alt for norm/exp/tanh, NOT PCM path | Approx (mismatch/drift), compact |
| Switched-cap mult | Q=C·V sampled, charge-shared | Integrator/accumulate, MDAC alt | ~8–10b (cap match), kT/C noise |
| Duration-MAC, pulse-width (**chosen**) | E=x·w via I=w·V for T=‖x‖·T_lsb | ALL FC tiles + shiftacc recombine | Approx (drift/G/LSB/7b ADC), dense, weight-stationary |
| Bit-serial | 1 bit-plane/cycle vs full B | Narrow proxy paths, serial PE fallback, BIST | Exact, minimal area, N-cyc/word |
| Stochastic/unary | p_z = p_x·p_y via AND, counter | Approx AV/activation exploration only | Approx 1/√N, tiny gates, very slow |

## C. Computer-architecture blocks

| Block | Function | Consumed by |
|---|---|---|
| Systolic array / PE | 2-D MAC array, Q rows vs K cols, reused for A·V | Attention qk_systolic + av_mac_array |
| SIMD lane | Replicated narrow MAC over heads/rows (folded) | Attention head-split + 768-wide datapath |
| Scoreboard | Track outstanding tile/layer ops, retire in order | Loop FSM (12-state layer_fsm + ATTN_WAIT) |
| Arbiter | Grant shared tile/FIFO-lane access | Phase decoder tile_sel/fifo_lane_en (6 ILP/6 OLP) |
| Crossbar switch | All-to-all steering of slices to banks | OLP concat_mux slice steering |
| NoC router | Packetized token-vector routing (overkill demo-scale) | 12x X loopback + tile-lane routing |
| DMA engine | Block mover without MCU per-beat | EXT overflow AXI4 mover (X spill, embed fetch, trace) |
| Address generator / AGU | Addresses as base+cnt·stride | x_bank addr_gen, calib/ref rows |
| Barrel shifter | Single-cycle variable shift | Attention >>3, OLP requant >>shift |
| Leading-zero counter | Normalize for NR seeds | Recal DIV, attention reciprocal |
| CRC / checksum | Integrity signature, off-datapath | MCU verify (spills, shadow scrub), never credit loop |
| Double-buffer controller | Ping-pong fill/drain overlap | in_fifo DBUF, x_bank/QKV banks, H banks |
| Credit flow control | Free-slot counter vs analog drain | stream_fifo credit_counter + almost_full stall |
| Valid/ready skid buffer | 1–2 deep ready-latency decouple | Tile out_fifo → norm-stage FIFO |
| CDC synchronizer | 2-flop + gray pointers | Digital vs duration-step clock boundary |
| CSR regfile + atomics | MMIO config/status, atomic set/clear | Calib coeffs, S/layer_idx, HWA table |
| Interrupt controller | Prioritize recal/layer_done/FIFO-error IRQs | MCU ISR |
| Performance counters | Cycle/stall/layer tallies, score | Bring-up, trace-dump counts |
| AXI master / slave | Standard bus bridge | Overflow DRAM master + MCU CSR slave |

No committed RTL exists: widths/depths are proposals (S≤64 vs 512, 8b vs
4b-equiv, FIFO 8 vs 16, C=256×3, T_RECAL/drift, DAC/ADC scales). H=12/d_k=64
and eps/Q-formats need HF-config + quantization-sweep sign-off.

## D. Popular-block quick index (headstart + companions)

Digital — adder (CLA/CPA: `S=A+B+Cin`), subtractor (`D=A−B`, adder + invert),
multiplication unit (§B), divider (restoring/NR, §B LUT note), DFF (`Q=D` @clk;
Qbar→D = ÷2; ripple chain = ÷2^N binary counter; Johnson ring = ÷2N with decoded
states; LFSR via XOR feedback for PRBS/dither; T-flip-flop = toggle counter —
this counter+comparator pair IS our duration encoder `PW=|x|·T0`), JK/SR/latch,
register file (multi-port SRAM), shift register, binary/Johnson/ring/LFSR
counter, MUX/DEMUX/decoder/encoder, comparator, parity/CRC, sync/async FIFO,
SRAM (6T, fast, on-chip: all token/result/cal/LUT banks), DRAM (1T1C, destructive
read + refresh, row buffer: bulk embedding table + X spill + trace dump behind
AXI overflow — capacity vs SRAM), TPU (256×256 systolic MAC, weight-stationary
dataflow, unified buffer + accumulators: the digital twin of our PCM tile and
the reference for the digital fallback), MAC lane, ALU, FPU/HardFloat, CORDIC
(shift-add sin/cos/atan/exp/log: tanh/softmax/recip alternative to LUT+NR),
PWM generator (counter + comparator = duration-encode driver).

Analog — amplifier (op-amp/OTA/instrumentation/PGA/VGA: `Av=gm·ro`),
summer (inverting: `Vout=−Rf·ΣVi/Ri` — the Kirchhoff column sum),
subtractor/diff amp (`Vout=(Rf/R1)(V2−V1)` — ± PCM pair subtract),
integrator (`Vout=−1/RC∫Vin`, duration-MAC), differentiator, analog multiplier
(Gilbert/translinear/log-antilog), analog divider (log amp → subtract → antilog,
or multiplier-in-feedback loop), comparator, Schmitt trigger, S/H, peak
detector, rectifier, V-to-I / I-to-V (TIA), current mirror (§A), bandgap, LDO,
charge pump, PLL (phase detector + charge pump + VCO — ties two §A rows together),
DLL, ADC (flash/SAR/ΣΔ/slope), DAC (R-string/current-steering), analog switch MUX,
chopper stabilization.
