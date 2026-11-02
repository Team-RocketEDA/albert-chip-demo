# L1.6 FFN_TILE (analog-digital: FC1 -> SRAM -> GELU -> FC2)

Parent math: `X[Sx768] -> H = GELU(X*W1^T) -> Y = H*W2^T` [Sx768];
W1:[3072x768], W2:[768x3072], int8-quant, pre-programmed, never move.
Top ports: `X_in: in: S*768 int8` rows; `Y_out: out: S*768 int8/fxp16`;
clk/rst_n/start/done; `cfg_pcm_prog: in: analog` (one-time only).

## Inner blocks

1. fc1_atile (FC1 analog tile array, replicated over out-cols x in-slices).
   `I_part = A_slice * W1_slice^T` per 512-wide in-chunk; full row
   `H_pre[j] = sum` over ceil(768/512)=2 chunks (512+256 padded), accumulated digitally.
   Children (primitives only): fc1_in_fifo (FIFO, 2x512B double buffer);
   dur_encoder (comparator+counter: `PW = |x|*T0`, sign to +/- MUX);
   fc1_dac_row (DAC x512); fc1_xbar (multiplier/mixer + summer + amplifier;
   PCM 4-dev/weight: Gpos_MSB/LSB, Gneg_MSB/LSB differential;
   `I = w*x` via Ohm, col sum via Kirchhoff);
   fc1_integrator (integrator: charge `I*T_pw`; OPERATION duration-MAC ->
   op-amp integrator + capacitor); fc1_adc (ADC+comparator: ramp ADC =
   integrator+comparator+counter; behavioral Verilog-A first, Sky130 SAR later);
   fc1_shiftacc (shifter+adder+regfile: MSB/LSB recombine + +/- subtract +
   2-slice accumulate; `D = (MSB*256+LSB)_pos - (..)_neg`).
2. h_sram_buffer (H pre-GELU store). `H_pre[Sx3072]` latch, double-buffered
   ping/pong (FC1 writes A while GELU reads B). 64*3072*2B = 384KB/bank demo
   (192KB @S=32); S=512 full would be 3MB/bank (tile the S loop in demo).
   OSS: OpenRAM Sky130 macros (1024x1024b cuts / 32KB banks) + regfile wrapper.
3. gelu_dpipe (digital GELU tanh-approx pipeline).
   `GELU(x) = 0.5x(1+tanh(c0(x+0.044715x^3)))`, c0 ~ 0.79788456.
   Children: gelu_in_fifo (FIFO depth 8); gelu_mac1 (multiplier+adder+regfile:
   cubic `u`, then `v = c0*u`); gelu_tanh_lut (SRAM/regfile: tanh(v) 1024x16b
   LUT + linear interp via 1 multiplier + 1 adder; clamp |v|>4 -> +/-1);
   gelu_mac2 (multiplier+adder: `y = 0.5*x*(1+t)`); gelu_out_fifo (FIFO depth 8).
   OPERATION mapping: cubic/MAC -> fixed-point MAC ALU; tanh -> ROM LUT
   (digital counterpart of diff-pair tanh cell). FXP Q4.12 (TBD).
4. fc2_atile (FC2 analog tile array). `Y[i] = sum` over ceil(3072/512)=6 chunks
   of `H_chunk * W2_chunk^T` (6x the accumulations of FC1; matches 6 ILP/OLP
   lane parallelism). Same leaf set as FC1 + fc2_shiftacc (6-chunk digital
   accumulation + dequant rescale).
5. tile_ctrl (digital sequencer). counter+comparator FSM + MUX selects
   (chunk/col/row counters, ping-pong bank MUX, lane MUX). Schedule per token
   row: 2x FC1 chunks -> SRAM flip -> GELU stream -> 6x FC2 chunks -> Y FIFO.

## OSS / sizing

Golden Py: HF `albert-base-v2` FC1 Linear + GELU; PCM/DAC/ADC: Verilog-A
compacts (Stanford RRAM / IBM PCM) for sim, Sky130 tapeout later; FIFOs
BaseJump `bsg_fifo_1r1w`; SRAM OpenRAM; ALU plain Verilog fxp16 + ROM.
Demo: S=32 default; FC cols in 512-wide OLP groups (1-2 groups instantiated).
Unresolved: differential vs MSB/LSB gain; 34-tile FC1/FC2/GELU partition;
Q-formats + tanh entries; no committed FFN RTL (all picks are proposals).

## Interface integration (09-interface.md)

FC1 = analog-sum mode (cap-share pair, ONE digitization per output, cleanest);
FC2 = 6x-digital-accum (6x ADC noise path, worst variation) + per-chunk coeff
count. p2 owns whole OLP fabric one wave; p3 drains 6 row-tiles separately.
