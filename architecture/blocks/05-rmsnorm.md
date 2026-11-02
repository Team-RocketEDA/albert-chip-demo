# L1.5 RMSNORM_STAGE x2 (digital norm pipeline, single-pass)

Parent I/O: `x[Sx576]` s8 + `resid[Sx576]` s8 -> `y[Sx576]` FXP16.
Entry: tile int8 dequant s8<<8 (exact, PARAMS §2); resid acc saturate-to-s8
then <<8. Exit: `y` requant → int8 (shift+clip, per-use sweep) for
tile/loop re-entry.
Math: `t = x+r`; `ms = mean(t^2)`; `s = 1/sqrt(ms+eps)`, eps=1e-5;
`xh = t*s`; `y = gamma*xh`. NO mean subtraction, NO beta (RMSNorm).
DTYPE: FXP16 = signed16 Q8.8; ACC32 = signed32 Q16.16 guard; REC16
unsigned16. Valid/ready on all stream ports. Weight-stationary: gamma
loaded once, never moves.

## Inner blocks

1. RES_ADD (OPERATION: add -> digital CLA adder array; analog op-amp summer
   NOT used). `t[i] = a[i]+b[i]`, saturate to FXP16. Inner: ADD_ALU +
   SAT_CMP (comparator+MUX) + 1-deep SKID_FIFO.
2. SQR_MEAN (OPERATION: square+mean -> digital multiplier + adder-tree).
   `ms = (1/D)*sum t[d]^2`; D=576. Inner: SQUARE_MUL (17x17->34b,
   truncate 32b) + MEAN_ACC (32b) + ROW_CNT (counter+comparator+MUX).
   TBUF re-read feeds the normalize pass.
3. RSQRT_NR (OPERATION: rsqrt -> Newton-Raphson + LUT seed).
   `s = 1/sqrt(ms+eps)`. Inner: EPS_ADD + SEED_LUT (`exp_lut`, SRAM
   256x16b) + 3x unrolled NR iters (multiplier/multiplier+sub/shifter +
   X_REG) + CONV_CMP + MUX. (Analog alt: SAR-ADC-style
   comparator+integrator loop, not used.)
4. NORMALIZE (OPERATION: mul -> digital multiplier / analog Gilbert mixer
   NOT used). `xh[d] = t[d]*s`. Inner: NORM_MUL (16x16->32b + shifter +
   ROUND_MUX).
5. AFFINE (OPERATION: MAC, gamma only). `y = gamma*xh`. Inner: AFF_MUL +
   G param regfile (576x16b) + COL_CNT (counter + comparator + MUX
   addr-inc).
6. RMS_CTRL + TBUF. STATE_REG (IDLE/ADD_SQR/NORM_AFFINE) + row/col
   comparators + bank/FIFO MUXes. Frame store: TBUF SRAM double buffer,
   2 banks x S*D x16b = 144KB @S=64/D=576 (72KB/frame); TBUF kept because
   mean-of-squares precedes normalize (single reduction, still two memory
   passes); streaming FIFO alt 2-4 deep.
7. EXIT_REQUANT (`requant` leaf). `y_int8 = clip((y*scale)>>shift+zero)`
   per-use; feeds tile/loop re-entry (test: Requant→int8 pinned here).

## Storage / OSS

TBUF 144KB + gamma 1.1KB + 512B LUT: OpenRAM Sky130 (banks) or DFFRAM;
FIFOs BaseJump `bsg_fifo_1r1w_small`; divider/sqrt Berkeley HardFloat
`divSqrtRecFN_small` or hand NR FSM; sim Verilator+cocotb, synth
LibreLane/OpenSTA (`run_hdl_test/run_synth/run_timing`). Golden: HF
MobileLLM RMSNorm + numpy FXP16 replica. Results exit via 2-deep skid FIFO.
Pinned in PARAMS §2 (eps=1e-5; Q8.8; requant shift/scale per-use sweep;
acceptance = gen-subset within −1.8% ref).

Interface tag: SW/digital-only; residual restore + re-entry via ILP/OLP
valid/ready (09 §2).
