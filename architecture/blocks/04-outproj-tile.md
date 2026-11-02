# L1.4 OUTPROJ_TILE_ARRAY (analog, column-split, concat not sum)

Parent I/O: `Z[Sx768]` -> `Zout[Sx768]`. Math: `Zout = Z*W^T`, W:[768x768]
pinned, weight-stationary. Demo proxy S<=64, reduced cols; golden vs HF
ALBERT out_proj.

Partition rule: W^T (768 rows=k x 768 cols=j) is COLUMN-split across tiles:
tile t holds cols `[t*C:(t+1)*C]` (C=256 x 3 tiles). Each tile computes a
disjoint output-column slice; full rows reassemble by digital CONCAT MUX.
No analog sum across tiles. (A k-split 512+256 WOULD need a cross-tile adder
tree; this partition avoids it.) 6 ILP/6 OLP = lane parallelism; 4 PCM/weight
= +/- pair x MSB/LSB slices; activations duration-encoded.

## Inner blocks (per tile)

1. in_fifo (FIFO, stop). `z_stream_in: in: S*768 int8`; `z_row_out: out: 768 int8`.
   2 banks x 64 x 768B = 96KB double buffer. OSS: Cummings / BaseJump
   `bsg_fifo_1r1w` / PULP `fifo_v3`.
2. dac_row_array (DAC x768 rows, 6 ILP). `z_row: in: 768 int8` ->
   `v_row: out: 768 analog-V`. `Tk = |Z|*T_lsb` (512-wide rows time-muxed
   over ceil(768/512) passes; sign -> +/- select).
   OPERATION duration-encode -> comparator+counter + 1-bit DAC switch +
   op-amp driver.
3. pcm_crossbar (mixer array + storage). `v_row: in` -> `i_col: out: C analog-I`.
   `I[k,j] = V[k]*(Gpos-Gneg)` with MSB/LSB bit-weight pair (4 PCM/cell).
   PCM pinned; digital OpenRAM/Sky130 SRAM shadow holds MSB/LSB copy for
   program/verify/scrub only (off datapath).
4. col_summer_array (summer+integrator+amplifier per col).
   `Vj = Rf * sum_k I[k,j]` over the pulse window (Kirchhoff + TIA/integrator).
5. adc_col_array (ADC xC, 6 OLP). `dout[j] = quantize(Vj/Vref*2^(N-1))`.
   OPERATION quantize -> SAR ADC. OSS: open Sky130 SAR ADC blocks;
   func: numpy round/clip.
6. scale_shift_unit (ALU+shifter+adder, digital). `q[j] = clip8((raw*scale)>>shift + bias)`.
7. out_fifo (FIFO, stop). Packs slice rows; 2*Smax*C bytes (32KB for C=256).
8. concat_mux (MUX + SRAM, stop). `Zout[i,:] = concat(slices)` by column index;
   pure steering, zero arithmetic. Output bank 64x768B (OpenRAM) or stream MUX
   into the next norm-stage FIFO.
9. tile_ctrl (regfile+comparator+ALU FSM). Loops i in 0..S-1, passes over
   512-wide chunks; counters vs bounds.

## Storage

Tokens/results: in_fifo 96KB DBUF, out_fifo 32KB/slice, concat bank 64x768B.
Weights: PCM conductance (stationary) + offline SRAM shadow. All tile I/O
token-streamed via FIFOs. Sizes scale linearly with S and C.
Unresolved: single-tile rows x cols (assumed C=256x3); PCM compact model;
DAC/ADC bit counts; T_lsb clock.

## Interface integration (09-interface.md)

256+256 mesh-concat pairing into one OLP (p1: olp0-2); CONCAT MUX reassembles
by column index. Column-split, never analog cross-tile sum.
