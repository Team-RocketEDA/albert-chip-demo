# L1.3 ATTENTION_CORE (digital island, no weights)

Parent I/O: `Q,K,V[Sx768]` each -> `Y[Sx768]`.
Math: `L = QK^T/sqrt(64)` [SxS]; `A = softmax_row(L)`; `Y = A*V`.
d_model=768, H=12, d_k=64 (inferred from sqrt64 + ALBERT-base; confirm vs HF
config). Q/K/V stream from analog inProj OLPs via FIFOs. No weights here.

Top ports: `q/k/v_stream: in: 512b` word + valid/ready; `s_cfg: in: 7b`
(S<=64/128); `y_stream: out: 512b`. 1 tile-row per tick, non-pipelined
across layer-blocks.

## Inner blocks

1. q_buf (SRAM, stop). `wdata: in: 512b`; `rdata: out: 64x8b row`; `addr: in: 6b`.
   Q_bank[S][768] staging, double-buffer 2xSx768B (2x48KB @S=64).
   OSS: OpenRAM bank (1024x32 cuts) or regfile for S<=16.
2. k_buf_transposed (SRAM, stop). Stores K^T [768][S] for systolic reuse.
   2x48KB + address-transpose FSM.
3. v_buf (SRAM, stop). V[S][768], 2x48KB.
4. qk_systolic (OPERATION: MAC array, stays digital). `q_row: in: 768x8b`;
   `k_col: in: 768x8b`; `logit: out: 24b acc`.
   `L_raw[i][j] = sum_d Q[i][d]*K[j][d]` (S^2*768 MACs). 8x8=64-PE array,
   12-way head-split MUX at input + edge FIFO (2 rows deep).
   OSS: BaseJump-STL systolic / fixed-point ALU; func: HF BERT attention.
5. scale_shifter (shifter, stop). `L = L_raw/8` = arith >>3 (Q6.10).
6. softmax_pipe:
   - rowmax_tree (comparator+reg): `m = max_j L[i][j]`, streaming tree.
   - sub_exp (ALU subtractor + SRAM LUT + multiplier + adder):
     `e = exp(l-m)`, 256x16b LUT + linear interp. (Analog alt: subthreshold
     diff-pair, rejected for drift.)
   - sum_recip (adder-tree + LUT + multiplier + subtractor):
     `s = sum e`; `inv = 1/s` via 256-entry LUT + 1 Newton-Raphson iter.
   - norm_mul (multiplier): `A[i][j] = e*inv`.
7. score_sram (SRAM, stop). A[S][S] buffer (4KB @S=64/16b). Decouples QK^T
   producer from AV consumer.
8. av_mac_array (OPERATION: multiplier+adder). `Y[i][d] = sum_j A[i][j]*V[j][d]`.
   Same 8x8 PE array reused or second instance; head-concat MUX out
   (12x[Sx64] -> [Sx768]).
9. out_fifo (FIFO, stop). 512b words, depth 4. CDC to outProj ILP duration
   encoder (DAC boundary).

## Storage / OSS

All activation SRAM on digital island (paper: intermediates in SRAM).
Q/K/V 3x2x48KB @S=64/8b; score 4KB; LUTs 2x512B ROM; FIFOs depth 2-4.
Proxy may narrow to 256-wide datapath, fold 768 by 3 passes.
OSS: HF transformers + aihwkit; OpenRAM + sky130_sram_macros via OpenLane;
Yosys/Verilator/cocotb/OpenSTA per engine flow; gdsfactory skywater130.
Unresolved: H=12/d_k=64 confirm; fixed-point width (8b vs 4b-equiv);
no committed RTL yet — sizes are proposal.

Interface tag: SW/digital-only; QKV in via OLP FIFOs, AV out via ILP FIFOs (09 §2).
