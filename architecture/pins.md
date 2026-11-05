# Macro pin contract — audited from `src/components/*.v` (base e6cddef)

Source of truth: the RTL port lists themselves. Any edit to a macro's
ports MUST update this doc, `pins.json`, and `TestPinNames` together.

## Power/clock convention

- Every macro takes `clk` (in, 1b) + `rst_n` (in, 1b, async-active-low).
- No macro declares `VPWR` / `VGND` / `VPB` / `VNB` in RTL. Those are
  backend PDK pins, added at synthesis/floorplan (standard-cell well
  taps), never part of the sim port list. `pins.json` records only the
  RTL ports below.
- All other widths are parametric expressions over the module parameters
  (`S/H/KV/FF/C/P/W`). Contract dims (`src/project.yaml`): S=64, H=576,
  KV=192, FF=1536, C=256; leaves default W=8, P=32.

## mac_array (`mac_array.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| ce | in | 1 |
| clr | in | 1 |
| avec | in | P*W |
| bvec | in | P*W |
| acc_in | in | 32 |
| acc_out | out | 32 |

## inproj_tile (`inproj_tile.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| tok_in | in | S*H*8 |
| tok_valid | in | 1 |
| cfg_scale | in | 16 |
| cfg_zero | in | 16 |
| tok_ready | out | 1 |
| y_out | out | S*(H+2*KV)*8 |
| y_valid | out | 1 |

## attention_core (`attention_core.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| q_in | in | S*H*8 |
| k_in | in | S*KV*8 |
| v_in | in | S*KV*8 |
| qkv_valid | in | 1 |
| s_cfg | in | 7 |
| qkv_ready | out | 1 |
| y_out | out | S*H*8 |
| y_valid | out | 1 |

## outproj_tile (`outproj_tile.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| z_in | in | S*H*8 |
| z_valid | in | 1 |
| cfg_scale | in | 16 |
| cfg_zero | in | 16 |
| z_ready | out | 1 |
| slice_out | out | S*C*8 |
| slice_valid | out | 1 |

## rmsnorm_stage (`rmsnorm_stage.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| x_in | in | S*H*8 |
| resid_in | in | S*H*8 |
| in_valid | in | 1 |
| in_ready | out | 1 |
| y_out | out | S*H*16 |
| y_valid | out | 1 |
| yq_out | out | S*H*8 |
| yq_valid | out | 1 |

## ffn_tile (`ffn_tile.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| x_in | in | S*H*8 |
| x_valid | in | 1 |
| start | in | 1 |
| x_ready | out | 1 |
| y_out | out | S*H*8 |
| y_valid | out | 1 |
| done | out | 1 |

## lm_head (`lm_head.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| x_last_in | in | H*8 |
| x_valid | in | 1 |
| pred_out | out | 15 |
| done | out | 1 |

## embed_top (`embed_top.v`)

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| ids_in | in | S*16 |
| ids_valid | in | 1 |
| ids_ready | out | 1 |
| x0_out | out | S*H*8 |
| x0_valid | out | 1 |

## layer_etched (`layer_etched.v`)

Unrolled single decoder-layer macro (30x etched array at the top; no
loopback). Doc: `architecture/top-level.md`. Contains `assign`
(combinational tie-offs), so it is WIRING, never STITCH.

| Pin | Dir | Width |
|---|---|---|
| clk | in | 1 |
| rst_n | in | 1 |
| x_in | in | S*H*8 |
| x_valid | in | 1 |
| x_ready | out | 1 |
| x_out | out | S*H*8 |
| y_valid | out | 1 |
