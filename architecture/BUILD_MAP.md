# BUILD MAP — inference-closed hierarchy → RTL vehicles

Rule: every block below is on the inference path or feeds it per-phase.
Parked (out of schema, reason recorded): AXI overflow/DRAM spill (conditional;
demo S≤64 fits on-chip — re-add only if S grows past SRAM), performance
counters + trace dump (testbench-only, live in TESTBENCH.md, not the chip).
Mixed-signal side quests live out-of-repo and are NOT this package.

Vehicle key: **DIG** = parametric SystemVerilog RTL (`data_bit_width`),
synthesized, one GDS macro each. **SW** = software/golden side (HF +
numpy), drives the testbench, never taped out. Every port is a digital
bit-vector (+valid/ready).

## L0 blocks

| Block | Vehicle | Flow |
|---|---|---|
| Token IDs in | SW test source | TESTBENCH text→ids |
| EMBED_TOP | DIG | RTL → synth → `embed.gds` |
| INPROJ_TILE | DIG (`mac_array` + SRAM + requant) | RTL → synth → `inproj.gds` |
| ATTENTION_CORE | DIG | RTL → synth → `attn.gds` |
| OUTPROJ_TILE | DIG (`mac_array` + SRAM + concat) | RTL → synth → `outproj.gds` |
| LAYERNORM x2 | DIG | RTL → synth → `ln.gds` |
| FFN_TILE (FC1+GELU+FC2) | DIG (FC MAC tiles + GELU LUT pipe) | RTL → synth → `ffn.gds` |
| POOLER+CLS | DIG | RTL → synth → `head.gds` |
| LOOP_MEM_SEQ | DIG | RTL → synth → `seq.gds` (phase seq + FSM + FIFOs + coeff SRAM) |
| Weights (Wemb/Wp/W/b/gamma/beta) | DIG SRAM macros | OpenRAM cuts, stationary, loaded once |
| GLUE compare | SW scoreboard | TESTBENCH, never taped out |
| seq_fsm control | DIG (hardwired FSM; `mcu_fw.c` = golden C model) | phase/IRQ FSM on-chip (ADR-0001) |

Demo values behind every port below are pinned in [PARAMS.md](PARAMS.md).
Parked items stay parked there too until bring-up.

## IO ports (all digital, bit-widths rendered)

```text
ids[S]u15                    SW  -> EMBED_TOP.id_in
X0[Sx768]s8                  EMBED_TOP.x0_out -> LOOP_MEM_SEQ.x_in
X_l[Sx768]s8                 LOOP -> tile IN_FIFOs (128xint8 lanes + valid/ready)
tok[256x8b]                  FIFO -> mac_array avec lane
wrow[256x8b]                 w_sram -> mac_array bvec lane
psum[32x32b]                 mac_array -> accum regfile
y_cal[Sxint8]                requant -> OLP FIFO -> next island
logits[Cx16b]                head -> SW scoreboard
pred[2b], correct/total[32u] scoreboard -> TESTBENCH report
```

One clock (100MHz) everywhere; CDC (2-flop + gray) ONLY at lane + result
FIFOs. No analog/digital frontier exists — the only crossings are SW/golden
boundaries at ids-in and logits-out.

## Stitch plan (RTL top)

Top module `albert_top` instantiates: `embed`, `inproj_tile`, `attn`,
`outproj_tile`, `ln` x2, `ffn_tile`, `pooler_head`, `seq_fsm` + SRAM bank
macros (OpenRAM) + `fifo_sync` lanes. One synthesis flow per macro, one GDS
each; top-level assembly vs this map for connectivity sign-off.

## Leaf coverage (L2 → vehicle)

All L2 leaves in blocks/01–08 resolve to §00-E parametric RTL modules
(MAC, ALU, FIFO, SRAM, LUT, FSM). No leaf is unassigned; parked items are
listed above, nothing else hangs.
