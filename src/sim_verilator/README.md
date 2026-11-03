# Verilator benches — tokens in, waveforms out

Three benches, all run from anywhere inside the repo via
`make -C src/sim_verilator <target>`. Waves land next to the Makefile.

| target  | what it proves | honest status |
|---|---|---|
| `embed` | token ids -> baked 576-byte embed vectors, byte-exact | REAL check, must PASS |
| `rmsnorm` | one baked 576-lane RMSNorm frame vs golden, 3-LSB tol | REAL check, must PASS |
| `top` | whole tree elaborates under Verilator, FST dumps | SMOKE only — top is structural, outputs float |

Open any wave with Surfer and add the named signals:

```sh
surfer src/sim_verilator/waves_embed.fst    # token_id, vec
surfer src/sim_verilator/waves_rmsnorm.fst  # x, gamma, y, y_valid
surfer src/sim_verilator/waves_top.fst      # ids_in, pred_out, done
```

The `embed` and `rmsnorm` drivers print every input with its output, so
the terminal transcript itself is the readable reference: token id in,
vector out; lane in, norm out. `top` prints `pred_out`/`done` but both
are placeholders until the hierarchy above the leaves is stitched.
