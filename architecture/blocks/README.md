# Drill-down hub: MobileLLM decoder top-down hierarchy

Top: [top-level doc](../top-level.md) · [interactive diagram](../mobilellm-top.html) · [drill-down tree](../blocks-tree.html) · [router](../mobilellm-router.html) (click any block → nested page; hash routes, react-router style).
Build: [BUILD_MAP.md](../BUILD_MAP.md) (every block → DIG RTL, IO ports with bit-widths, magic stitch plan) · [TESTBENCH.md](../TESTBENCH.md) (text→tokens→pred + sim-time benchmarks) · [PARAMS.md](../PARAMS.md) (pinned demo decisions: model, dtypes, tiles, memory, clocks, LM head, recal).
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
L0 mobilellm_top: ids[S]u15 -> X0[Sx576] -> LOOP30 -> LM head -> pred[15b]; X30 loopback 30x
 ├─ L1.1 EMBED_TOP (digital) .................... 01-embed.md
 │    ID_FIFO -> EMB_LUT_BANK -> XBUF -> X0_DBUF + CTRL_FSM
 ├─ L1.2 INPROJ_TILE (digital) ................... 02-inproj-tile.md
 │    inFIFO -> w_sram -> mac_array (32-lane) -> accum -> requant -> outFIFO (QKV thirds)
 ├─ L1.3 ATTENTION_CORE (digital, no weights) ... 03-attention-core.md
 │    Q/K/V SRAM + KV cache + RoPE mults -> QK MAC -> scale -> softmax pipe (causal)
 │    -> score SRAM -> AV MAC -> outFIFO
 ├─ L1.4 OUTPROJ_TILE (digital) .................. 04-outproj-tile.md
 │    inFIFO -> w_sram -> mac_array -> accum -> requant -> outFIFO -> concat MUX
 ├─ L1.5 RMSNORM_STAGE x2 (digital) .............. 05-rmsnorm.md
 │    RES_ADD -> SQR_MEAN -> RSQRT_NR -> NORMALIZE -> AFFINE(g) + TBUF
 ├─ L1.6 FFN_TILE (digital SwiGLU) ............... 06-ffn-tile.md
 │    GATE/UP tiles -> SiLU pipe (LUT+mul) -> DOWN tile + tile_ctrl
 ├─ L1.7 LM_HEAD (digital, last-token) ........... 07-lm-head.md
 │    LAST_BUF -> W_SRAM -> LM_MAC -> LOGITS -> ARGMAX -> PRED_FIFO
 └─ L1.8 LOOP_MEM_SEQ (control+memory) ........... 08-loop-mem-seq.md
      X banks + wcal (720KB) + 12 stream FIFOs + layer FSM + recal + SEQ_FSM + overflow
 └─ L1.9 INTERFACE (digital island contract) ..... 09-interface.md
```

Open-source spine (all blocks): HF `transformers` (`facebook/MobileLLM-125M`,
gated custom code — user fetches) as functional golden; OpenRAM Sky130 SRAM
macros; BaseJump-STL / OpenTitan / PULP FIFOs and ALUs; hardwired `seq_fsm`
(ADR-0001, no MCU); Yosys/Verilator/cocotb/Icarus/OpenSTA per the rocket-engine
flow.

In-diagram double-click drill-through (archify guided views, one HTML per
level) is not wired yet; this hub is the navigation until that pass.
