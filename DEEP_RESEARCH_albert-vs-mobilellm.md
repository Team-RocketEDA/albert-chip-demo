# ALBERT vs MobileLLM-125M: switch-vs-stick study for the tiny-RTL demo
*Generated: 2026-11-02 | Workflow: albert-mobilellm-switch-study (3 parallel researchers + critic + follow-up + synthesis) | Status: partial (primary-1 structural-delta researcher returned incomplete; its per-block verdicts survive via synthesis) | Confidence: High on dims/MAC math; Medium on RoPE/RMSNorm-as-shipped and wall clocks*

## Executive Summary
**Verdict: STICK with the ALBERT skeleton for the tiny-RTL demo; do not switch the demo vehicle to full MobileLLM-125M.** A full MobileLLM-125M prefill is ~14.2G MACs (~2.6x an ALBERT-base pass) — ~14.5 days serial in icarus, viable only on Verilator + 8-wide MAC array (~26 min–87 min). The retarget touches only 12 of 34 skeleton files + 1 new LUT, so the architecture transfers — but the switch buys nothing for a Nov-4 demo: same proxy, same sim path, plus gated NC custom code and an unreconciled embedding-tie discrepancy. Switch only when Verilator + array + proxy-weight subset are all available.

## 1. Verified MobileLLM-125M config (opened pages)
- L=30, qHeads=9, kvHeads=3, H=576, I=1536, 124.6M params — paper Table 9 (arXiv HTML v2, 6-column row verified) + GitHub training config, 3 corroborating sources.
- Head dim 64; K/V dim 192; Q-head repeat factor 3.
- SwiGLU (paper S2.2.1, `hidden_act: silu`, gate/up 576→1536, down 1536→576) — SURVIVES outright, no counterevidence.
- GQA kv=3: K/V params+cache shrink exactly 3.0x (663,552 → 221,184/layer); scoped: Q/O unaffected, full attention-proj saving ~442k/layer (~12% of per-layer ~3.54M), not a whole-model 3x.
- RoPE: SURVIVES downgraded — config shows `rope_theta: 10000.0`, `max_positions: 2048`, `model_type: llama`; reference `modeling_llama.py` has rotary-embed + causal mask. But the paper body contains no literal 'RoPE'/'rotary' string — claim rests on config + reference impl, NOT paper text, and the shipped `modeling_mobilellm.py` was never opened (Hub gated 401).
- RMSNorm: SURVIVES downgraded ('strictly simpler' → 'fewer reductions, same sqrt/divide core') — `variance=mean(x^2); x*rsqrt(var+eps)*weight`, no mean subtraction, no beta. Still needs sqrt/rsqrt+scale.
- Tokenizer: LlamaTokenizer, bos `<s>` eos `</s>` unk `<unk>`, add_bos_token true.
- License: FAIR non-commercial-research; Hub gated manual + `trust_remote_code=True` custom code (`MobileLLMForCausalLM`).
- Embedding tie DISCREPANCY (unreconciled): HF card says Shared Embeddings Yes; training config says `tie_word_embeddings: false`. Affects LM-head `$readmemh` bank count only.

## 2. Sim cost (MACs verified, wall clocks inherited-unverified)
- Prefill S=128/layer: QKV+O 113.25M + scores+AV 18.87M + SwiGLU 339.74M = 471.86M; x30 = **14.156B MACs (~28.3B FLOPs)**, amortized 110.6M/token.
- Decode/token (KV cache, ctx128): 3.686M/layer; x30 = **110.6M MACs/token**.
- Serial icarus @11.3k cyc/s: prefill ~14.5 days; decode ~2.7 h/token. 8-wide: ~43.5 h / ~20.4 min. Verilator 30x: ~11.6 h / ~5.4 min; 100x: ~3.5 h / ~1.6 min. Verilator+8-wide: 30x → ~87 min / ~41 s; 100x → ~26 min / ~12 s.
- `$readmemh`: ~125MB int8 bin (~250–375MB hex), one-time parse of seconds; load order embed → L0..29 {Q,K,V,O; 2 norms; gate,up,down} → final norm → LM head; one hex per `sram_1r1w` bank. Full table is Verilator-only; icarus loads proxy subset.
- Anchors (11.3k cyc/s, Verilator 30–100x) inherited from prior research, not re-measured.

## 3. Per-block delta (ALBERT skeleton → MobileLLM decoder)
| Block | Verdict | Change |
|---|---|---|
| Embeddings | SWAP | Tied 32k shared in/out; no 128→768 factorized proj |
| QKV proj | SWAP | Fused 2304×768 → split q 576→576 + k/v 576→192 (GQA) |
| Attention | SWAP | Bidirectional SxS → causal + KV cache |
| RoPE | NEW | Inverse-freq rotation; no ALBERT equivalent |
| Out proj | SHARED-op, new shape | 768→768 → 576→576 |
| Norm | SWAP | Post-LN+beta → pre-RMSNorm x2/layer, no mean/beta |
| FFN | SWAP | GELU 2-mat → SwiGLU 3-mat (gate/up 576→1536, down 1536→576) |
| Head | SWAP | CLS/tanh/argmax-GLUE → last-token tied LM head 32k |
| Layer sharing | SHARED-concept, different pattern | ALBERT 1×12 reuse vs 30 distinct (LS variant: 30→60 x2 repeat) |
| Loopback/seq | RETARGET | 30 layers + cache AGU, prefill/decode phases |

## 4. Skeleton retarget count (34 files)
- TOUCHED 12: `albert_top`, `embed_top`, `inproj_tile` (K/V width 192), `attention_core` (causal+GQA+KV cache), `outproj_tile` (minor), `layernorm_stage` + `layernorm_d` (RMSNorm mode), `ffn_tile` (SwiGLU 3-mat), `pooler_cls_head` (→ last-token LM head), `loop_mem_seq` (30 distinct layers + cache AGU), `softmax_d` (causal port), `seq_fsm` (prefill/decode phases). +1 NEW `silu_lut.v`; `gelu_lut.v` retired.
- UNTOUCHED 22: fifo, regfile, sram, dram_ctrl, muxN, adder/sub/mult, mac_unit, mac_array, dotK, dff, alu_bit, shifter, requant, cmp, exp_lut, tanh_lut, div_unit, embed_lut, irq_sync (+dram_ctrl counted once).
- Param cross-check: ~3.54M/layer x30 + 18.4M embed = 124.6M matches paper.

## 5. Bottom line + risks
STICK: 12-file + 1-new rework buys a 14.5-day serial prefill and gated NC custom code. Switch risks: time blowup without Verilator+8-wide; tie-discrepancy bank miscount; RoPE/RMSNorm assumed from reference impl, not the shipped file; wall clocks inherited, not re-measured. Revisit the switch only with Verilator + array + proxy-weight subset all available — the proxy sim path is identical either way.

## Sources (all opened this pass)
- MobileLLM-125M HF page (200 OK): custom_code + arxiv:2402.14905 tags, FAIR NC-research, trust_remote_code snippets.
- HF API record: gated=manual, `MobileLLMForCausalLM`, auto_map modeling_mobilellm, empty bos/eos/unk in API record.
- arXiv abs 2402.14905: deep+thin, embedding sharing, GQA; ICML 2024.
- arXiv HTML v2 (grep-inspected): Table 9 6-column row; S2.2.1 SwiGLU; S2.2.3 embedding sharing; GQA head-dim-64 text.
- GitHub training config (full body): llama arch, 30L/9H/3KV/576/1536, silu, no bias, rms_norm_eps 1e-5, rope_theta 10000.0, rope_scaling null, max_pos 2048, vocab 32000, tie_word_embeddings false.
- GitHub tokenizer config (full body): LlamaTokenizer, `<s>`/`</s>`/`<unk>`, add_bos true.
- HF transformers `modeling_llama.py` (opened): rotary-embed, causal mask, gate/up/down shapes, k/v 576→192, repeat-KV, RMSNorm forward.

## Methodology
3 parallel researchers (config grounding; structural delta; sim-cost + switch economics) + adversarial critic (5 falsification targets) + gap follow-up + synthesis. Schemas enforced per call; unreconciled items preserved above, not smoothed over.
Sub-questions: (1) exact open config, (2) per-block SHARED/SWAP/NEW, (3) MAC math + wall time + skeleton touch count.

## Gaps (stated, not hidden)
- primary-1 (structural delta) returned incomplete; per-block verdicts survive via synthesis only.
- Shipped `modeling_mobilellm.py` / `configuration_mobilellm` never opened (Hub 401).
- Embedding-tie discrepancy unreconciled (affects LM-head bank count).
- Wall-time anchors inherited, not re-measured; MAC/FLOP counts independently verified.
- Norm/pos literal names inferred from config fields; paper body has no literal RoPE string.
