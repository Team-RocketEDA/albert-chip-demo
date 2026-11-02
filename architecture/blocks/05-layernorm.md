# L1.5 LAYERNORM_STAGE x2 (digital norm pipeline, 2-pass)

Parent I/O: `x[Sx768]` FXP16 + `resid[Sx768]` FXP16 -> `y[Sx768]` FXP16.
Math: `t = x+r`; `mu = mean(t)`; `v = mean((t-mu)^2)`; `xh = (t-mu)/sqrt(v+eps)`;
`y = gamma*xh + beta`. DTYPE: FXP16 = signed16 Q8.8; ACC32 = signed32 Q16.16
guard; REC16 unsigned16. Valid/ready on all stream ports. Weight-stationary:
gamma/beta loaded once, never move.

## Inner blocks

1. RES_ADD (OPERATION: add -> digital CLA adder array; analog op-amp summer NOT used).
   `t[i] = a[i]+b[i]`, saturate to FXP16. Inner: ADD_ALU + SAT_CMP (comparator+MUX)
   + 1-deep SKID_FIFO.
2. MEAN_SUM_DIV (OPERATION: mean -> adder-tree + iterative divider).
   `mu = (1/D)*sum t[d]`; D=768 (not pow2, no pure shift). Inner: ACC_ADD (32b)
   + ACC_REG + ROW_CNT (counter+comparator+MUX) + DIV_CORE (ALU subtract +
   shifter + comparator + MUX + quotient regfile).
3. VAR_SSA (OPERATION: square -> digital multiplier). `v = (1/D)*sum((t-mu)^2)`.
   Inner: SUB_DIFF (subtractor, 17b) + SQUARE_MUL (17x17->34b, truncate 32b) +
   VAR_ACC + reuse DIV_CORE. TBUF re-read for the second pass.
4. SQRT_RECIP (OPERATION: sqrt+reciprocal -> Newton-Raphson + LUT seed).
   `s = 1/sqrt(v+eps)`. Inner: EPS_ADD + SEED_LUT (SRAM 256x16b) + 3x unrolled
   NR iters (multiplier/multiplier/sub+shifter + X_REG) + CONV_CMP+ MUX.
   (Analog alt: SAR-ADC-style comparator+integrator loop, not used.)
5. NORMALIZE (OPERATION: mul -> digital multiplier / analog Gilbert mixer).
   `xh[d] = (t[d]-mu)*s`. Inner: SUB2 + NORM_MUL (16x16->32b + shifter + ROUND_MUX).
6. AFFINE_MAC + PARAM_REGFILE (OPERATION: MAC). `y = gamma*xh + beta`.
   Inner: AFF_MUL + AFF_ADD + G/B regfiles (768x16b each) + COL_CNT
   (counter + comparator + MUX addr-inc).
7. LN_CTRL + TBUF. STATE_REG (IDLE/ADD_MEAN/VAR/NORM_AFFINE) + row/col
   comparators + bank/FIFO MUXes. Frame store: TBUF SRAM double buffer,
   2 banks x S*D x16b = 192KB @S=64/D=768 (96KB/frame); TBUF kept because
   mean precedes variance (two-pass); streaming FIFO alt 2-4 deep.

## Storage / OSS

TBUF 192KB + gamma/beta 3KB + 512B LUT: OpenRAM Sky130 (6x 32KB 1rw + 4KB)
or DFFRAM; FIFOs BaseJump `bsg_fifo_1r1w_small`; divider/sqrt Berkeley
HardFloat `divSqrtRecFN_small` or hand NR FSM; sim Verilator+cocotb, synth
LibreLane/OpenSTA (`run_hdl_test/run_synth/run_timing`). Golden: HF
`AlbertLayerNorm` + numpy FXP16 replica. Results exit via 2-deep skid FIFO.
Unresolved: ADC/dequant resolution in; eps (assumed 1e-12, match HF);
Q-format sign-off needs quantization sweep vs HF golden.

Interface tag: SW/digital-only; residual restore + re-entry via ILP/OLP
valid/ready (09 §2).
