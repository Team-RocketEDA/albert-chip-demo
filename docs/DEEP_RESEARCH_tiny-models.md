# Deep research: smallest open-weight models for a tiny RTL transformer demo
*Generated: 2026-11-02 | Sources: ~25 unique (HF configs + pages opened and grepped, arXiv abs pages, vendor/measured docs) | Confidence: Medium-High on rankings and sim math; Medium on exact param strings*

## Meta-only constraint (user directive, 2026-11-02) — REVISED TOP PICK

Open weights MUST be from Meta. Prior BERT-Tiny/SmolLM/TinyStories survey
below is retained as non-Meta reference only. Revised ranking (all verified
via web, HF pages opened):

1. `facebook/MobileLLM-125M` — 124.6M params (30 layers / 576 hidden / GQA,
   table 30|9|3|576), causal LM, HF Transformers + PyTorch, `trust_remote_code`
   custom modeling, arxiv 2402.14905, license **fair-noncommercial-research**
   (research/demo OK, not commercial), UNGATED (page + usage snippet opened,
   no login wall). Smallest Meta checkpoint. Zero-shot commonsense eval story.
2. `facebook/opt-125m` — ~125M decoder-only (OPT suite 125M–175B, v4.19 docs),
   license "other" (OPT research terms); older architecture, weaker eval story.
3. `meta-llama/Llama-3.2-1B` — 1.24B, GATED (HF token + license accept),
   Llama 3.2 Community License. Large anchor, not the demo vehicle.
4. `facebook/MobileLLM-350M` — 345.3M (32|15|5|960). Step-up option.

Decoder-only delta (applies to all four): causal mask, no CLS pooler in the
ALBERT sense; eval is zero-shot commonsense/generation vs HF golden, not
GLUE classification. The attention+FFN RTL skeleton blocks transfer directly
(decoder block = encoder block + causal mask + KV cache); pooler head becomes
a last-token projection at implementation time. Sim proxy (L=1/H=32/int8,
~70K MACs, ~6 s serial) is unchanged — it is arch-level, checkpoint-agnostic.
Full MobileLLM-125M MAC budget: derive from opened config at bring-up
(PARAMS §9); belongs on Verilator + MAC array regardless.

## Executive Summary
The smallest credible open-weight transformer with a real tokenizer and a GLUE-style eval story is **BERT-Tiny (4.4M params)** — `google/bert_uncased_L-2_H-128_A-2` (Apache-2.0), with `prajjwal1/bert-tiny` (MIT) as a license-alternate. But even 4.4M params is far too big to simulate in Icarus Verilog: at measured ~11.3k cycles/s, serial 1-MAC/cycle inference needs ~700 s/token at 8M weights. The demo strategy is therefore a **scaled proxy** (L=1, H=32, ff=64, S=8, int8, ~12K params, ~70K MACs) that fits the same parameterized RTL and runs in ~6 s serial (sub-second with an 8-wide MAC array, no VCD). Full-size weights belong in Verilator (30–100× faster) plus a parallel MAC array.

## 1. Smallest open-weight candidates (ranked for RTL fit)
1. `google/bert_uncased_L-2_H-128_A-2` — 2 layers, H=128, 2 heads, ff=512, vocab 30522, ~4.4M params; Apache-2.0; real WordPiece tokenizer; BERT ⇒ GLUE/SST-2 fine-tune path. Canonical top pick.
2. `prajjwal1/bert-tiny` — same net, MIT license. License-alternate.
3. `huawei-noah/TinyBERT_General_4L_312D` — ~14.5M (4L/312H/1200); best documented distillation story (96.8% of BERT-base GLUE). No license tag on repo page.
4. `albert/albert-base-v2` — ~11M (12 shared layers, E128/H768/ff3072, SentencePiece); demonstrates cross-layer sharing + factorized embeddings. Apache-2.0.
5. `roneneldan/TinyStories-1Layer-21M` — single-block generative demo, real GPT-Neo BPE tokenizer; no GLUE story.
Disqualified: nanoGPT-Shakespeare (10.8M, char vocab — no real tokenizer); SmolLM-135M (reference ceiling only).

## 2. RTL sim-time math (derived, cross-checked)
Per-layer MACs = `4·S·H²` (QKV+out proj) + `2·S²·H` (scores + AV) + `2·S·H·F` (FFN); FLOPs = 2× MACs.
- BERT-Tiny, S=128: 29.36M MACs/layer → 58.7M MACs (117M FLOPs)/pass, ~459K MACs/token.
- ALBERT-base block, S=64: ~459M MACs; ×12 applications = 5.51G MACs (11G FLOPs)/pass, ~86M MACs/token.
- Demo proxy (L=1, H=32, ff=64, S=8, int8): 32,768 + 4,096 + 32,768 = ~70K MACs/pass, ~12K params.
- Measured iverilog throughput: ~11.3k cycles/s (2,108,456 cycles in 187 s, vernier-rv32 toolchain doc). 1M cycles ≈ 90 s wall.
- `$readmemh` of 8M weights (~24–32 MB int8 hex) is a one-time parse of order seconds — negligible next to event evaluation.
- Verilator: ~100× claim (veripool.org docs) with ~30× independent anchor (Embecosm via arXiv html, workload-dependent). Realistic: 30–100× plus divide-by-P with a parallel MAC array.

## 3. Key takeaways
- Pick BERT-Tiny (or MIT twin) as the canonical reference model; demo a scaled proxy on the same RTL.
- Anything at 8M weights in iverilog is infeasible (~700 s/token serial) — Verilator + MAC array for full size.
- Demo proxy: L=1/H=32/ff=64/S=8/int8 via `$readmemh`, no VCD → ~6 s serial, sub-second with 8-wide MAC.
- No-VCD discipline on timing runs; keep event density low (folded datapaths, not fully parallel fabrics).

## Sources
- HF configs (opened + grepped): google/bert_uncased_L-2_H-128_A-2, prajjwal1/bert-tiny, prajjwal1/bert-mini, TinyBERT_General_4L/6L, albert-base-v2, TinyStories-1M/1Layer-21M/33M, SmolLM-135M, dbrll/sheaf-nanogpt-shakespeare mirror.
- Training config: karpathy/nanoGPT `train_shakespeare_char.py` (n_layer 6, n_head 6, n_embd 384).
- Papers (abs pages opened): arXiv 1908.08962 (BERT-Tiny), 1909.10351 (TinyBERT, incl. 96.8% GLUE), 1909.11942 (ALBERT), 2305.07759 (TinyStories).
- Throughput: vernier-rv32 `docs/toolchain.md` raw (11.3k cycles/s measured); veripool.org/verilator (~100× claim); arXiv html 2604.05983v1 (Embecosm ~30×).
- HF Transformers ALBERT model doc (factorized embeddings + sharing, max 512 tokens).

## Methodology
2 parallel researchers (model survey; sim-cost math) + synthesis, per workflow-authoring contract with complete/evidence/unresolved schema. 3 sub-questions per track, ~8 queries each, ~15–30 sources. Every cited number comes from an opened page or a shown derivation.
Sub-questions: (a) smallest open checkpoints with configs/licenses/tokenizers; (b) MAC/token math for demo vs full configs; (c) measured iverilog throughput + Verilator speedup anchors.

## Gaps (stated, not hidden)
- `$readmemh` load time is derived from byte counts, not a published benchmark.
- CVC-vs-Icarus 30–45× (up to 111×, arXiv:1603.08059) seen only in a search snippet.
- Embecosm primary numbers (130 kHz vs 1.4 kHz) seen only in snippets; corroborated only via the Arch-paper ~30× citation.
- 11M/14.5M/67M param strings partly snippet-sourced (consistent with opened configs).
- No license tags on huawei-noah TinyBERT or roneneldan TinyStories repo pages; nanoGPT upstream MIT not confirmed on an opened page.
- Primary-0 (model survey) returned incomplete envelope; its findings survive only via the synthesiser's cited prior-result evidence.
