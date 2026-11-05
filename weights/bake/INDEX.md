# Weight-bake artifact index (step 0, `plans/block-logic-plan.md`)

Source: `weights/mobilellm-125m/finetuned/model.safetensors` — verified
272 tensors = 30 layers x 9 + `model.embed_tokens.weight` + `model.norm.weight`;
all F32, shapes exactly per plan (Q 576x576, K/V 192x576, O 576x576,
gate/up 1536x576, down 576x1536, norms 576, embed 32000x576); no `lm_head`,
no biases. All paths below are relative to `weights/bake/`.

Scheme (see `bake.py`): per-channel absmax symmetric int8 —
`scale = max_abs/127` per output row (`1.0` if zero; single scale for 1-D
norms), `q = clip(round_half_away(w/scale), -127, 127)`. Hex convention
matches `testbench/gen_embed_vectors.py`: one value per line, lowercase,
unsigned (`02x` s8 bytes, `08x` s32 psums, `04x` Q8.8 / u15 token ids).
`W_lm` is an embed copy per `architecture/PARAMS.md` sections 1/7/9 —
no second binary is stored; `lm_head` loads `embed_full.hex`.

## Baked `$readmemh` tables (layer 0 proxy + norms + embed)

| file | tensor | bytes |
|---|---|---|
| `layer0_q_proj.hex` | layers.0 q_proj 576x576 | 331776 |
| `layer0_k_proj.hex` | layers.0 k_proj 192x576 | 110592 |
| `layer0_v_proj.hex` | layers.0 v_proj 192x576 | 110592 |
| `layer0_o_proj.hex` | layers.0 o_proj 576x576 | 331776 |
| `layer0_gate_proj.hex` | layers.0 gate_proj 1536x576 | 884736 |
| `layer0_up_proj.hex` | layers.0 up_proj 1536x576 | 884736 |
| `layer0_down_proj.hex` | layers.0 down_proj 576x1536 | 884736 |
| `layer0_input_layernorm.hex` | layers.0 input_ln 576 (1 scale) | 576 |
| `layer0_post_attention_layernorm.hex` | layers.0 post-attn ln 576 (1 scale) | 576 |
| `final_norm.hex` | model.norm 576 (1 scale) | 576 |
| `embed_full.hex` | embed_tokens 32000x576 | 18432000 |
| `embed_proxy64.hex` | first 64 embed rows (= full head) | 36864 |

## Scales / reports / checks

| file | content |
|---|---|
| `scales_baked.json` | scheme + per-channel scales for the 10 baked tables + 32000 embed scales |
| `quant_report.txt` | max/mean abs err for ALL 272 tensors; worst `model.norm.weight` 0.01012262 |
| `bank_check.txt` | every table vs its `src/components` `sram_1r1w` bank — OVERALL: ALL BANKS FIT |
| `bake.py` | the pure-stdlib bake script (re-runnable) |
| `INDEX.md` | this file |

Bank map: Q/K/V tiles stream through `inproj_tile u_wsram` (4096 B: 81/27/27
tiles); O through `outproj_tile u_wsram` (81 tiles); gate/up/down through
`ffn_tile u_gatew/u_upw/u_downw` (8192 B: 108 tiles each, 6x256 chunks);
norms drive `rmsnorm_d` gamma (init image, s8<<8 per PARAMS section 2);
embed fills `lm_head u_wlm` (18432000 B in 18874368 B, 32000/32768 rows) and
`embed_proxy64.hex` exactly fills `embed_top u_dbuf` (36864 B frame).

## Deterministic test vectors (seeds in `tv_manifest.txt`)

`tv_embed_ids.hex` (u15 ids, seed 0xE1BE9) + `tv_embed_golden.hex` (baked rows);
per-matmul `tv_{q,k,v,o,gate,up,down}_act.hex` + `tv_*_golden.hex` (exact
int8xint8->s32 dots of first 8 out-channels, seeds 0xB0C1-0xB0C7, corners
-128/127 forced); `tv_lmhead_act.hex` + `tv_lmhead_golden.hex` (16 vocab rows,
seed 0xB0C8); `tv_rmsnorm_in.hex` + `tv_rmsnorm_golden.hex` (Q8.8, eps 1e-5,
seed 0xB0C9); `tv_silu_stim/golden.txt`, `tv_softmax_stim/golden.txt` (float
references, seeds 0xB0CA/0xB0CB).

Verified: 272-tensor contract asserts in `bake.py`; independent re-quant of
q row 0 matches; `embed_proxy64` == full head; `tv_q_golden` recomputes from
hex; `bank_check.txt` ALL BANKS FIT; iverilog `$readmemh` smoke test loads
`final_norm.hex` + `tv_q_golden.hex` bit-exact
(`norm[0]=67 norm[575]=6a psum[0]=ffffef16 psum[7]=ffffb43c`).
