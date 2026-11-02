# ADR-0002 — Meta-only open weights (MobileLLM-125M vehicle)

Status: accepted (user directive, 2026-11-02).
Supersedes: the BERT-Tiny vehicle in PARAMS §1 / TESTBENCH (pre-directive).

## Context

Demo needs an open-weight golden + eval story. User constrained: Meta only.

## Decision

- Vehicle: `facebook/MobileLLM-125M` (124.6M, 30L/576H/GQA causal LM,
  FAIR non-commercial-research, ungated, trust_remote_code).
- Runner-up: `facebook/opt-125m` (125M decoder). Anchor: Llama-3.2-1B
  (1.24B, gated) — not the demo vehicle.
- Eval is zero-shot commonsense/generation vs HF golden (decoder-only:
  causal mask, no CLS pooler; pooler head becomes last-token projection).

## Consequences

- ALBERT-base stays the functional math spec; the open-weight golden is
  MobileLLM-125M (DEEP_RESEARCH_tiny-models.md, Meta-only section).
- Proxy sim (L=1/H=32/int8) unchanged — checkpoint-agnostic.
- License note: FAIR NC-research covers research/demo, not commercial use.
