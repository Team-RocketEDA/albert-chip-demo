# TESTBENCH — text in, text out, sim-time benchmarks

Proves the stitched RTL is a transformer. Chain (all under `testbench/` +
`rtl/`). Electrical values are now digital timing (sysclk, MACs/cycle,
chunk counts) pinned in [PARAMS.md](PARAMS.md) §3/§6, not chosen here.
(Historic analog `tile_col.py` / `olp_digitizer.py` scripts remain on disk
for the out-of-repo mixed-signal side quest; they are not on this chain.)

```text
text in  -> HF MobileLLM tokenizer -> ids[S]u15
         -> EMBED_TOP (RTL sim or SW golden) -> X0[Sx768]
         -> LOOP 12x { p0 INPROJ MAC tile -> ATTN -> p1 OUTPROJ MAC tile -> LN
                     -> p2 FC1 MAC tile -> GELU pipe -> p3 FC2 MAC tile -> LN }
         -> pooler/classifier -> argmax -> label text out
```

## Stimulus: text to the token stream

1. `tb_driver.py`: takes raw prompts (gen-style pairs), tokenizes with the
   HF MobileLLM tokenizer, emits `stimulus.mem` (ids as `seq tok id` rows,
   S≤64; +seg column for sentence-pair tasks at step 3, see 01 scope note).
2. Token feeder: converts ids → int8 stream rows (embedding + requant, SW
   golden for bring-up; RTL `embed.gds` vectors for sign-off) and drives the
   tile IN_FIFOs as `fifo_sync` write bursts.
3. Each MAC tile runs RTL sim (`mac_array` + accum + requant) on a
   representative chunk-slice; full-tile behavior projected by chunk counts.
4. Requant model: fixed-point `(acc*scale)>>shift + zero` + clip, per-chunk
   scale/zero + 12 resident layer-use sets; no drift injection (none exists).
5. Digital islands: RTL sim (iverilog now, Verilator at scale) fed by FIFO
   vectors; pooler/head produces logits → argmax → label string
   (`entailment`, `positive`, …). `tb_scoreboard.py` compares vs HF golden
   + labels.

## What we post as the final result

- Input sentences → predicted labels table (accuracy vs HF golden, gen-style;
  paper budget ref: −1.8% avg, iso-accuracy on some tasks).
- Waveform + trace excerpt: one token row through p0..p3 (FIFO bursts in,
  MAC accumulations, requant codes out).
- 4-bit-equiv sweep table (paper Fig1e style, integer-emulated).

## Sim-time benchmarking (theoretical token speed)

- `t_sim/row`: RTL sim wall time per token-row per phase (measured, no VCD).
- Frame time (theory): `12 layers × Σ_p S_rows × chunks_p / lanes × T_clk
  + T_sw,p` — same anatomy as blocks/09, with our sim's T values.
- Throughput: tokens/sec = S / frame_time; MACs/inference counted from the
  map (86M MACs/layer FP-equivalent at S=64; 70K MACs proxy pass) →
  effective TOPS (theoretical).
- Honest scope line on every chart: slice-simulated, chunk-count-projected.

## Bring-up order

1. SW golden end-to-end (HF MobileLLM-125M only) → reference table.
2. One MAC tile-chunk (inProj slice) vs golden MAC → calibrate requant.
3. Full p0..p3 loop one layer, proxy dims, digital only → compare table.
4. 12x loopback + pooler tap → gen-subset accuracy + benchmarks.
