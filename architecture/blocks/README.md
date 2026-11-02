# Drill-down hub: ALBERT top-down hierarchy

Top: [top-level doc](../top-level.md) · [interactive diagram](../albert-top.html) · [drill-down tree](../blocks-tree.html) · [router](../albert-router.html) (click any block → nested page; hash routes, react-router style).
Build: [BUILD_MAP.md](../BUILD_MAP.md) (every block → ANA subckt or DIG RTL, IO ports with A/D domains, magic stitch plan) · [TESTBENCH.md](../TESTBENCH.md) (text→tokens→SPICE→labels + sim-time benchmarks) · [PARAMS.md](../PARAMS.md) (pinned demo decisions: model, dtypes, analog electrical, tiles, memory, clocks, pooler, recal).
Closure rule: every diagram block is on the inference path or feeds it per-phase. Parked (not hanging, just out of schema): AXI overflow/DRAM spill (conditional, S≤64 never spills) and perf-counters/trace (testbench-only).
Rebuild rule: `archify finalize` overwrites injected links — re-run `scripts/drill_links.py` after every finalize.
Rule: click a block below to go one level in. All leaves resolve into
[00-primitive-library.md](00-primitive-library.md): analog workhorses (§A),
the multiplication zoo (§B), computer-architecture blocks (§C), and the
popular-block quick index (§D: adder, amplifier, subtractor, summer, analog
multiplier/divider, DFF-as-divider/counter, flip-flops, TPU, mult unit, DRAM).
OPERATION-as-blocks are flagged with their later circuit mapping.
Weight-stationary everywhere: weights never move, tokens stream.

```text
L0 albert_top: ids[S]u15 + label[2b] -> pred[2b], correct/total[32u]; X12 loopback 12x
 ├─ L1.1 EMBED_TOP (digital) .................... 01-embed.md
 │    ID_FIFO -> EMB_LUT_BANK -> E128_FIFO -> DOT128_MAC + PROJ_W_BANK
 │    + ACCUM_RF + BIAS_ADD -> REQUANT_CLIP -> X0_DBUF + CTRL_FSM
 ├─ L1.2 INPROJ_TILE_ARRAY (analog) ............. 02-inproj-tile.md
 │    inFIFO -> DAC drivers -> PCM crossbar -> summer/integrator -> ADC -> calib
 ├─ L1.3 ATTENTION_CORE (digital, no weights) ... 03-attention-core.md
 │    Q/K/V SRAM -> systolic -> shift -> softmax pipe -> score SRAM -> AV MAC -> FIFO
 ├─ L1.4 OUTPROJ_TILE_ARRAY (analog) ............ 04-outproj-tile.md
 │    inFIFO -> DAC -> crossbar -> summer -> ADC -> requant -> outFIFO -> concat MUX
 ├─ L1.5 LAYERNORM_STAGE x2 (digital) ........... 05-layernorm.md
 │    RES_ADD -> MEAN -> VAR -> SQRT_RECIP -> NORMALIZE -> AFFINE + TBUF
 ├─ L1.6 FFN_TILE (analog+digital) .............. 06-ffn-tile.md
 │    FC1 tile -> H SRAM -> GELU pipe -> FC2 tile + tile_ctrl
 ├─ L1.7 POOLER_CLASSIFIER_HEAD (digital) ....... 07-pooler-classifier.md
 │    CLS MUX -> pooler MAC+tanh -> classifier MAC -> argmax -> scoreboard
 └─ L1.8 LOOP_MEM_SEQ (control+memory) .......... 08-loop-mem-seq.md
      X banks + cal banks + 12 stream FIFOs + layer FSM + recal + MCU + overflow
 └─ L1.9 INTERFACE (fuses analog+digital islands) ......... 09-interface.md
```

Open-source spine (all blocks): HF `transformers` (`albert-base-v2`) as
functional golden; OpenRAM Sky130 SRAM macros; BaseJump-STL / OpenTitan /
PULP FIFOs and ALUs; Ibex or PicoRV32 MCU; Verilog-A compact models for
analog; Yosys/Verilator/cocotb/Icarus/OpenSTA per the rocket-engine flow.

In-diagram double-click drill-through (archify guided views, one HTML per
level) is not wired yet; this hub is the navigation until that pass.
