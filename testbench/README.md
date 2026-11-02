# testbench/ — harness status

Zero-dependency stdlib Python + ngspice-42. HF `transformers` used when
importable, else deterministic demo vocab (bring-up only, never for accuracy).

Vendored macro: `vendor/SKY130_SAR-ADC1` (JKU 12b differential SAR, Apache
2.0, postlayout spice + LEF/GDS + RTL). OLP digitizer model
(`olp_digitizer.py`) is its behavioral stand-in: 7b codes = macro result
bits [11:5]; `start_conversion_in`/`conversion_finished_out` handshake maps
to the tile_ctrl ADC strobe. Transistor-level macro runs standalone for
sign-off, never inside the phase loop (sim-time).

## Files

- `tb_driver.py` — text → `stimulus.mem` (`seq tok id` rows).
- `token_feeder.py` — id → int8 row → ngspice PWL `.inc` (duration encode).
- `tile_col.py` — first tile-column transient check (PASS, see below).
- `olp_digitizer.py` — 7-bit SAR + slope/offset + drift model.
- `tb_scoreboard.py` — logits → GLUE-style accuracy table.

## Verified results (2026-11-02, ngspice-42, host python3.12)

Tile-column slice (8 rows, mixed magnitudes incl. one zero; programmed
G 0.5–5.0 uS; V_read=0.2V, T_lsb=10ns, C=10pF):

| | V(col) |
|---|---|
| analytic golden Q/C | 0.214700 V |
| ngspice transient | 0.214310 V |
| rel. error | **0.182%** (tol 2.0%) — **PASS** |

(First run caught a B-source polarity flip — sim went to −0.214 V; fixed by
sourcing current into the column node. Magnitude matched throughout.)

Chain smoke tests: driver→feeder produces valid PWL (sign + width correct);
digitizer `0.21431V → d_raw=23/127 → y_cal=23`; scoreboard formats per-task
and overall accuracy correctly on synthetic logits.

## Bring-up status vs TESTBENCH.md order

1. SW golden end-to-end — pending (needs HF weights; torch absent here).
2. One tile-column transient vs golden MAC — DONE (this dir).
3. Full p0..p3 loop one layer, digital in the loop — next.
4. 30x loopback + LM head → gen-subset accuracy + benchmarks — queued.
