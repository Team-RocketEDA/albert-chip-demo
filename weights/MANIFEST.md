# weights/ — gated Meta checkpoint landing zone (NOT engine-tracked)

`fetch_weights.sh` downloads `facebook/MobileLLM-125M` here with YOUR token
(gated repo: accept the license on the model page first). Weight binaries are
deliberately never ingested as engine ledger documents (1 MB doc limit) —
only this manifest, the fetch script, and the later quantizer outputs'
recipes live in versioned files.

## Expected layout after fetch (`mobilellm-125m/`)

From the opened model page + API record + training config (sizes confirmed
only after YOUR download lands — update this file then):

- `config.json` — 30L / 9H / 3KV / H576 / I1536, silu, rope_theta 10000.0
- `tokenizer.json`, `tokenizer_config.json`, `tokenizer.model` (LlamaTokenizer, BPE)
- `model.safetensors` (possibly sharded `model-0000N-of-0000M.safetensors`)
- `modeling_mobilellm.py`, `configuration_mobilellm.py` (`trust_remote_code`)
- `generation_config.json` (if shipped)

## Downstream (later work, not this drop)

1. `quantize.py` (int8 + per-bank scales; golden-parity check vs HF first).
2. `emit_hex.py`: one `.hex` per `sram_1r1w` bank, same convention as
   `src/spikes/{common,embed}/*.hex` (row-major hex, one value per line).
   Icarus loads a proxy subset; full tables are Verilator-only.
