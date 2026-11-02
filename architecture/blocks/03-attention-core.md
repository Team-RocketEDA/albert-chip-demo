# L1.3 ATTENTION_CORE (digital island, no weights)

Parent I/O: `Q[Sx576]s8, K[Sx192]s8, V[Sx192]s8` -> `Y[Sx576]s8` (GQA 9Q/3KV,
head_dim 64, causal mask, RoPE on Q/K, KV cache for decode).
`Y` requant → int8 for outProj tile re-entry (shift+clip, per-use sweep,
PARAMS §2); streams via out_fifo.
Math: `L = RoPE(Q)*RoPE(K)^T/sqrt(64)` [SxS, causal]; `A = softmax_row(L)`;
`Y = A*V`, heads concatenated. Q/K/V stream from digital inProj OLP FIFOs.
No weights here (RoPE sin/cos are constant tables).

Top ports: `q_in: in: Sx576 int8`; `k_in/v_in: in: Sx192 int8`;
`qkv_valid: in: 1b`; `s_cfg: in: 7b` (S bound config);
`y_out: out: Sx576 int8`; `y_valid: out: 1b`. Causal forced high this
package (`causal(1'b1)`); one tile-row per tick, non-pipelined
across layer-blocks.

## Inner blocks

1. q_buf (SRAM, stop). Q[S][576] staging, double-buffer 2xSx576B (2x36KB
   @S=64). OSS: OpenRAM bank (1024x32 cuts) or regfile for S<=16.
2. k_buf_transposed (SRAM, stop). K[S][192] for systolic reuse + address-
   transpose FSM. 2x12KB. v_buf (SRAM, stop). V[S][192]. 2x12KB.
3. KV cache (decode): k_cache + v_cache (SRAM, stop). 2048-token window per
   head-dim slice (`sram_1r1w #(192,2048)` each). Prefill fills, decode
   appends; AGU lives in 08.
4. rope_Q/rope_K (`mult` pairs, stop). Inverse-freq sin/cos rotation on
   Q/K pairs (`rope_theta` 10000.0; table width is a §9 reverify item).
5. qk_systolic (OPERATION: MAC array, stays digital). `q_row x k_col`
   -> `logit: out: 24b acc`. `L_raw[i][j] = sum_d Q[i][d]*K[j][d]`
   (S^2*576 MACs). 8x8=64-PE array via `mac_array #(8,32)` time-mux.
   OSS: BaseJump-STL systolic / fixed-point ALU; func: HF MobileLLM
   attention (causal + RoPE + repeat-KV reference).
6. scale_shifter (shifter, stop). `L = L_raw/8` = arith >>3 (Q6.10).
7. softmax_pipe:
   - rowmax_tree (comparator+reg): `m = max_j L[i][j]`, streaming tree,
     causal positions masked to -inf before max.
   - sub_exp (ALU subtractor + SRAM LUT + multiplier + adder):
     `e = exp(l-m)`, 256x16b LUT + linear interp. (Analog alt: subthreshold
     diff-pair, rejected for drift.)
   - sum_recip (adder-tree + LUT + multiplier + subtractor):
     `s = sum e`; `inv = 1/s` via 256-entry LUT + 1 Newton-Raphson iter.
   - norm_mul (multiplier): `A[i][j] = e*inv`.
8. score_sram (SRAM, stop). A[S][S] buffer (4KB @S=64/16b). Decouples QK^T
   producer from AV consumer.
9. av_mac_array (multiplier+adder). `Y[i][d] = sum_j A[i][j]*V[j][d]`
   (second `mac_array #(8,32)`); GQA head-concat MUX out
   (9x[Sx64] -> [Sx576]).
10. out_fifo (FIFO, stop). 512b words, depth 4. CDC to outProj ILP
    tile FIFO (digital boundary).

## Storage / OSS

All activation SRAM on digital island. Q 2x36KB + K/V 2x12KB @S=64/8b
(+ 2048-deep KV cache); score 4KB; LUTs 2x512B ROM; FIFOs depth 2-4.
Proxy may narrow to 256-wide datapath, fold 576 by 3 passes.
OSS: HF transformers + aihwkit; OpenRAM + sky130_sram_macros via OpenLane;
Yosys/Verilator/cocotb/OpenSTA per engine flow; gdsfactory skywater130.
Pinned in PARAMS §1 (9Q/3KV heads, head_dim 64, reverify vs HF) + §2
(8b acts, 4b-equiv sweep variant). No committed RTL beyond skeletons —
sizes stand per PARAMS §9 checklist.

Interface tag: SW/digital-only; QKV in via OLP FIFOs, AV out via ILP FIFOs (09 §2).
