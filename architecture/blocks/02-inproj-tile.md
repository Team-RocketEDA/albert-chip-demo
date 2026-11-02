# L1.2 INPROJ_TILE_ARRAY (analog MAC slice, weight-stationary)

Parent I/O: `Xl[Sx768]` int8 -> `Y[Sx2304]` int8. Math: `Y = Xl*W^T`,
W:[2304x768] pinned, never moves. One slice covers 512x512 weights;
full inProj = 5x2 tiles; 768-col input split 512+256 with digital post-sum.
Demo proxy: S<=64, single 512-col slice.

Top ports: `tok_in: in: Sx768 int8` (512-chunks); `w_pinned: internal: 512x512
analog-G` (4PCM/weight, static); `y_out: out: Sx512 int8-calibrated`;
`cfg_slope/cfg_offset: in: 512x16b`; clk/rst/valid-ready.

## Inner blocks (per slice)

1. input_vector_FIFO. `in_tok: in: 512x8b`; `out_chunk: out: 512x8b`.
   Double buffer, 64-entry x 512B ring in SRAM (~1KB/buffer).
   Decomp: SRAM bank + regfile rd/wr pointers + comparator + MUX.
2. row_DAC_driver_array (512 rows). `d_in: in: 512x8b` -> `t_pulse/v_row: out: analog`.
   `T_on[i]=|x[i]|*T_lsb`, sign selects +/- driver.
   Decomp: 8b latch + down-counter (ALU+comparator) + IDAC + driver amplifier.
   OPERATION duration-encode -> counter + current-steering DAC + op-amp driver.
3. pcm_crossbar_core. `v_row: in: 512xV` -> `i_col: out: 512xI`.
   `I_j = sum_i V_i*(G+_ij - G-_ij)`, 4PCM/weight (2 pairs).
   Decomp: PCM cell mixer array (`I=V*G`) + column wire summer (Kirchhoff).
   Weights live ONLY here as conductance, programmed once closed-loop.
4. column_summer_integrator_array (512 cols). `V_j=(1/C)*int(I_j dt)-Vcm`,
   +/- pair subtracted. Decomp: subtractor + amplifier/TIA + capacitor.
   OPERATION add/integrate -> op-amp adder/integrator.
5. olp_ADC_quantizer_array. `v_int: in: 512xV` -> `d_raw: out: 512x7b`.
   Decomp: comparator bank + SAR register + internal DAC + shifter.
   OPERATION quantize -> SAR ADC (7b per paper OLP).
6. per_col_calib_offset_add (digital). `d_raw: in: 512x7b` ->
   `y_cal = clip_int8(d_raw*slope_j + off_j)`.
   Decomp: multiplier + adder + shifter + comparator + 512x32b coeff regfile.

## Storage / OSS

W: PCM crossbar only (static). Tokens: input double-buffer SRAM FIFO
(2xSx512x8b, 32KB max demo) + output bank + OLP FIFO. Coeffs: slope+offset
regfile. Golden: HF ALBERT `Linear(768->2304)` slice; analog in Verilog-A/ngspice.
Functional control: Verilog counter/FIFO + Sky130 IDAC/op-amp cells.
Unresolved: exact DAC LSB / V_read / T_window; ADC full-scale/signedness;
256-col remainder pairing (analog vs digital sum point).

## Interface integration (09-interface.md)

5-lane OLP drain (p0: olp0-4); QKV thirds separable per lane for direct
ATTN_WAIT handoff. Duration-encode/digitize/calib chain per interface §4-6.
