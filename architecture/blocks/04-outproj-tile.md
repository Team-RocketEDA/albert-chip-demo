# L1.4 OUTPROJ_TILE_ARRAY (digital, column-split, concat not sum)

Parent I/O: `Z[Sx576]` -> `Zout[Sx576]`. Math: `Zout = Z*W^T`, W:[576x576]
pinned in SRAM, weight-stationary. Demo proxy S<=64; golden vs HF MobileLLM
out-proj. Column split: tile holds cols `[t*C:(t+1)*C]`, C=256 x 3 slices
(2x256 + 64-tail); full rows reassemble by digital CONCAT MUX.
No cross-tile adder tree (a k-split WOULD need one; this partition avoids
it). Tiles are time-mux passes of one MAC tile in the proxy.

## Inner blocks (per tile, all §00-E RTL)

1. in_fifo (`fifo_sync`, stop). `z_stream_in: in: S*576 int8`;
   `z_row_out: out: 576 int8`. 2 banks x 64 x 576B = 72KB double buffer.
2. w_sram_bank (`sram_1r1w`, STATIONARY). W slice `[576x256]` int8 per tile
   (144KB); host-loaded once, no write port during inference.
3. mac_array (`mac_array #(8,32)`). `z_row` x W-slice rows -> 256x s32 psums;
   chunk loop over K=576 (2x256 + 64-tail).
4. accum_regfile (`regfile_dp`). 256x s32 per tile slice.
5. scale_shift_unit (`shifter` + `adder`, digital). `q[j] =
   clip8((raw*scale)>>shift + zero)`; per-use coeffs via
   `cal_addr.layer5b`.
6. out_fifo (`fifo_sync`, stop). Packs slice rows; 2*Smax*C bytes (32KB for
   C=256).
7. concat_mux (`muxN` + SRAM, stop). `Zout[i,:] = concat(slices)` by column
   index; pure steering, zero arithmetic. Output bank 64x576B or stream MUX
   into the next norm-stage FIFO.
8. tile_ctrl (`seq_fsm` leaf: counter+comparator FSM + MUX). Loops i in
   0..S-1, chunk passes over K; counters vs bounds.

## Storage

Tokens/results: in_fifo 72KB DBUF, out_fifo 32KB/slice, concat bank 64x576B.
Weights: SRAM banks (stationary). All tile I/O token-streamed via FIFOs.
Sizes scale linearly with S and C.
Pinned in PARAMS §4 (C=256x3 digital slices) + §3 (32-lane MAC, 100MHz) +
§2 (int8/s32; per-use requant sweep).

## Interface integration (09-interface.md)

256+256(+64-tail) mesh-concat pairing into one OLP (p1: olp0-2); CONCAT
MUX reassembles by column index. Column-split, never cross-tile sums.
