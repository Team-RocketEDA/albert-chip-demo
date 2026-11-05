# sim_verilator — Verilator benches with Surfer-ready waveforms.
#
# Run from anywhere inside the repo (paths resolve to the repo root):
#   make -C src/sim_verilator embed     # token ids -> embed vectors (REAL check)
#   make -C src/sim_verilator rmsnorm   # 576-lane RMSNorm frame (REAL check)
#   make -C src/sim_verilator top       # full-model smoke (EXPECT X: top is structural)
#   make -C src/sim_verilator all
#   make -C src/sim_verilator clean
#
# Waves land in this dir as waves_*.fst; open with:
#   surfer src/sim_verilator/waves_embed.fst
HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(HERE)/../..)
# Tools resolve via PATH — run under ./build.sh so rocket-engine's
# provisioned bins (oss-cad-suite) and venv come first. Standalone,
# RE_ROOT defaults to the sister folder; RE_PY to plain python3.
RE_ROOT ?= $(abspath $(ROOT)/../rocket-engine)
RE_PY ?= python3
# Verilator from PATH; override with VL=/path/to/verilator. No machine paths here.
VL ?= $(shell command -v verilator)
ifeq ($(VL),)
$(error verilator not on PATH — install oss-cad-suite or set VL=/path/to/verilator)
endif
# Build parallelism knob: C++ compile is parallel-safe, Verilator's
# translate stage is the memory hog. Lower when sharing the box
# (the 31 GB machine also hosts synth runs).
VL_JOBS ?= 20
VLFLAGS := --cc --exe --trace-fst --build -j $(VL_JOBS) -Wall -Wno-UNUSEDPARAM
# Codec bench: no trace (embed+head tables are ~50 MB of state).
# Same suppression posture as the top bench (full-tree build).
CODECFLAGS := --cc --exe --build -j $(VL_JOBS) -Wno-UNDRIVEN -Wno-UNUSED \
  -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM \
  -Wno-UNUSEDSIGNAL -Wno-WIDTHCONCAT -Wno-WIDTHTRUNC -Wno-PINCONNECTEMPTY \
  -Wno-BLKSEQ -Wno-GENUNNAMED -Wno-UNSIGNED -Wno-SYNCASYNCNET
# -Wno-UNUSEDPARAM: embed_lut's E is compat-only by design (DUT-owned, do not edit).
# Minimal closures: codec/l0probe stimulate the layer-0 cone only, so they
# compile exactly the files it reaches — never the full tree (the old
# `$(shell ls *.v)` compiled all 29 files including the 147 Mbit embed
# image and the structural top, same OOM class as the 30-layer build).
# The `top` target below stays full-tree by design (it IS the full-model
# smoke); bound it with VL_JOBS instead.
CODEC_SRCS := $(ROOT)/src/components/attention_core.v \
  $(ROOT)/src/components/div_unit.v $(ROOT)/src/components/dotK.v \
  $(ROOT)/src/components/embed_lut.v $(ROOT)/src/components/exp_lut.v \
  $(ROOT)/src/components/fifo_sync.v $(ROOT)/src/components/ffn_tile.v \
  $(ROOT)/src/components/inproj_tile.v $(ROOT)/src/components/layer_etched.v \
  $(ROOT)/src/components/lm_head.v $(ROOT)/src/components/mac_array.v \
  $(ROOT)/src/components/outproj_tile.v $(ROOT)/src/components/regfile_dp.v \
  $(ROOT)/src/components/requant.v $(ROOT)/src/components/rmsnorm_d.v \
  $(ROOT)/src/components/rmsnorm_stage.v $(ROOT)/src/components/seq_fsm.v \
  $(ROOT)/src/components/silu_lut.v $(ROOT)/src/components/softmax_d.v \
  $(ROOT)/src/components/sram_1r1w.v
# l0probe needs only the layer cone (no embed/head tables).
L0_SRCS := $(filter-out %/embed_lut.v %/lm_head.v,$(CODEC_SRCS))

all: embed rmsnorm top

embed: $(HERE)/obj_embed/Vtb_embed
	cd $(ROOT) && ./src/sim_verilator/obj_embed/Vtb_embed

# Prompt mode: token ids in, vectors out, wave in waves_prompt.fst.
# Usage: make -C src/sim_verilator prompt PROMPT_IDS="1 2 0x42"
PROMPT_IDS ?= 1 2 0x42
prompt: $(HERE)/obj_embed/Vtb_embed
	cd $(ROOT) && ./src/sim_verilator/obj_embed/Vtb_embed $(PROMPT_IDS)

# Text mode: English in, vectors out (tokenizer bridge, then the same bench).
# Usage: make -C src/sim_verilator prompt-text PROMPT_TEXT="hello world"
# Decode model id outputs back with: python3 weights/tokenize.py --decode <ids>
PROMPT_TEXT ?= hello world
prompt-text: $(HERE)/obj_embed/Vtb_embed
	cd $(ROOT) && ./src/sim_verilator/obj_embed/Vtb_embed $$($(RE_PY) $(ROOT)/weights/tokenize.py "$(PROMPT_TEXT)")

# --trace-max-width 4608: Verilator's default (256b) silently drops the
# 4608-bit vec from the wave; the lookup is invisible in Surfer without this.
$(HERE)/obj_embed/Vtb_embed: $(HERE)/tb_embed.sv $(HERE)/tb_embed.cpp $(ROOT)/src/components/embed_lut.v
	cd $(HERE) && $(VL) $(VLFLAGS) --trace-max-width 4608 --top-module tb_embed --Mdir obj_embed \
	  tb_embed.sv tb_embed.cpp $(ROOT)/src/components/embed_lut.v

rmsnorm: $(HERE)/obj_rmsnorm/Vtb_rmsnorm
	cd $(ROOT) && ./src/sim_verilator/obj_rmsnorm/Vtb_rmsnorm

# -Wno-UNUSEDSIGNAL: rmsnorm_d keeps always-zero upper bits of >> results
# as shift headroom (DUT-owned, sim- and proof-verified; do not edit).
$(HERE)/obj_rmsnorm/Vtb_rmsnorm: $(HERE)/tb_rmsnorm.sv $(HERE)/tb_rmsnorm.cpp $(ROOT)/src/components/rmsnorm_d.v
	cd $(HERE) && $(VL) $(VLFLAGS) -Wno-UNUSEDSIGNAL --top-module tb_rmsnorm --Mdir obj_rmsnorm \
	  tb_rmsnorm.sv tb_rmsnorm.cpp $(ROOT)/src/components/rmsnorm_d.v

inproj: $(HERE)/obj_inproj/Vtb_inproj
	cd $(ROOT) && ./src/sim_verilator/obj_inproj/Vtb_inproj

# Chunk equivalence: monolithic inproj vs 2-slice harness, exact compare.
# Needs the metaprogrammed wrappers first:
#   python3 weights/bake/chunk.py --chunks 2 --layers 0
#   python3 weights/bake/emit_chunks.py --chunks 2 --layers 0
chunk-equiv: $(HERE)/obj_chunk_equiv/Vtb_chunk_equiv
	cd $(ROOT) && ./src/sim_verilator/obj_chunk_equiv/Vtb_chunk_equiv

# - UNUSEDSIGNAL: unused FIFO status/read taps + mac acc_ext headroom
#   (same class as the rmsnorm target).
# - WIDTHEXPAND: narrow counters compared against 32-bit loop bounds;
#   Verilog zero-extends, semantics preserved (same class as top).
# - SYNCASYNCNET: seq_fsm samples rst_n synchronously while the rest of
#   the tree is async; reset is held >=2 cycles in sim so both release
#   together. Unify the reset topology later; not a sim bug.
# - PINCONNECTEMPTY: u_wsram .ra/.wa intentionally empty in inference
#   (host-loaded 4KB bank footprint, we=0; see inproj_tile header).
# - WIDTHCONCAT: {S*NO*8{1'b0}} y_out_q zero-init exceeds the 8192-bit
#   replication heuristic at S=2 (15360b); legitimate wide clear.
INPROJFLAGS := $(VLFLAGS) -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND \
  -Wno-SYNCASYNCNET -Wno-PINCONNECTEMPTY -Wno-WIDTHCONCAT
$(HERE)/obj_inproj/Vtb_inproj: $(HERE)/tb_inproj.sv $(HERE)/tb_inproj.cpp \
    $(ROOT)/src/components/inproj_tile.v $(ROOT)/src/components/fifo_sync.v \
    $(ROOT)/src/components/sram_1r1w.v $(ROOT)/src/components/mac_array.v \
    $(ROOT)/src/components/regfile_dp.v $(ROOT)/src/components/requant.v \
    $(ROOT)/src/components/seq_fsm.v
	cd $(HERE) && $(VL) $(INPROJFLAGS) --trace-max-width 15360 --top-module tb_inproj --Mdir obj_inproj \
	  tb_inproj.sv tb_inproj.cpp $(ROOT)/src/components/inproj_tile.v $(ROOT)/src/components/fifo_sync.v \
	  $(ROOT)/src/components/sram_1r1w.v $(ROOT)/src/components/mac_array.v \
	  $(ROOT)/src/components/regfile_dp.v $(ROOT)/src/components/requant.v \
	  $(ROOT)/src/components/seq_fsm.v

$(HERE)/obj_chunk_equiv/Vtb_chunk_equiv: $(HERE)/tb_chunk_equiv.sv $(HERE)/tb_chunk_equiv.cpp \
    $(ROOT)/src/components/inproj_tile.v $(ROOT)/src/components/fifo_sync.v \
    $(ROOT)/src/components/sram_1r1w.v $(ROOT)/src/components/mac_array.v \
    $(ROOT)/src/components/regfile_dp.v $(ROOT)/src/components/requant.v \
    $(ROOT)/src/components/seq_fsm.v \
    $(ROOT)/src/generated/layer0_inproj_c0.v \
    $(ROOT)/src/generated/layer0_inproj_c1.v \
    $(ROOT)/src/generated/layer0_inproj_c2x.v
	cd $(HERE) && $(VL) $(INPROJFLAGS) --trace-max-width 15360 --top-module tb_chunk_equiv --Mdir obj_chunk_equiv \
	  tb_chunk_equiv.sv tb_chunk_equiv.cpp $(ROOT)/src/components/inproj_tile.v $(ROOT)/src/components/fifo_sync.v \
	  $(ROOT)/src/components/sram_1r1w.v $(ROOT)/src/components/mac_array.v \
	  $(ROOT)/src/components/regfile_dp.v $(ROOT)/src/components/requant.v \
	  $(ROOT)/src/components/seq_fsm.v \
	  $(ROOT)/src/generated/layer0_inproj_c0.v \
	  $(ROOT)/src/generated/layer0_inproj_c1.v \
	  $(ROOT)/src/generated/layer0_inproj_c2x.v

$(HERE)/obj_codec/Vtb_codec: $(HERE)/tb_codec.sv $(HERE)/tb_codec.cpp \
    $(ROOT)/src/generated/layer0_etched.v $(CODEC_SRCS)
	cd $(HERE) && $(VL) $(CODECFLAGS) --trace-max-width 7680 --top-module tb_codec --Mdir obj_codec \
	  tb_codec.sv tb_codec.cpp $(ROOT)/src/generated/layer0_etched.v $(CODEC_SRCS)

# Layer-0 fidelity probe: dumps the calibrated layer0 x_out frame for
# golden_l0bit.py (bit-golden). Same full-tree suppression posture.
$(HERE)/obj_l0probe/Vtb_l0probe: $(HERE)/tb_l0probe.sv $(HERE)/tb_l0probe.cpp \
    $(ROOT)/src/generated/layer0_etched.v $(L0_SRCS)
	cd $(HERE) && $(VL) $(CODECFLAGS) --trace-max-width 7680 --top-module tb_l0probe --Mdir obj_l0probe \
	  tb_l0probe.sv tb_l0probe.cpp $(ROOT)/src/generated/layer0_etched.v $(L0_SRCS)

l0probe: $(HERE)/obj_l0probe/Vtb_l0probe
	cd $(ROOT) && ./src/sim_verilator/obj_l0probe/Vtb_l0probe $(ID) weights/bake/embed_full_pt.hex /tmp/l0probe.out

# Token codec: make codec [ID=1] [TOKENS=1] chains single-token runs
# (each pred feeds the next id). Needs emit_layers.py output first
# (src/generated/layer0_etched.v).
codec: $(HERE)/obj_codec/Vtb_codec
	cd $(ROOT) && id="$(ID)"; [ -n "$$id" ] || id=1; \
	n="$(TOKENS)"; [ -n "$$n" ] || n=1; i=0; \
	while [ $$i -lt $$n ]; do \
	  out=$$(./src/sim_verilator/obj_codec/Vtb_codec $$id); \
	  echo "$$out"; \
	  case "$$out" in *pred=*) \
	    id=$$(echo "$$out" | sed 's/.*pred=\([0-9]*\).*/\1/');; \
	    *) break;; \
	  esac; \
	  i=$$((i+1)); \
	done; true

top: $(HERE)/obj_top/Vtb_top
	cd $(ROOT) && ./src/sim_verilator/obj_top/Vtb_top

# TOPFLAGS: smoke target, defaults only (no -Wall). The tree above the
# leaves is unfinished structural RTL, so its lint classes are suppressed
# here with prejudice and documented: UNCONNECTED/PINMISSING ports,
# UNDRIVEN floats, UNUSED stubs, WIDTHEXPAND in DUT expressions.
# --unroll-limit 131072: the ffn y_out pack is a flat S*H=36864 generate
# (and RoPE ~24K nested); Verilator's default 16384 trips on depth, not
# on any real loop bug. The inproj tile packs clocked instead; unifying
# the style is lane cleanup, not needed for the sim.
# - WIDTHCONCAT: full-frame zero-inits ({S*H*8{1'b0}} etc., up to 491520b
#   in inproj at S=64); legitimate wide clears, same class as inproj S=2.
# - WIDTHTRUNC: guarded-by-construction narrowings, all covered by passing
#   stitch sims — attention row/col counters wrap at nrows-1/S-1 so the
#   dropped 7th bit is always 0; (l_raw>>>3) lanes are saturation-guarded
#   to [-32768,32767] before the 16-bit take; outproj SRAM/accum indices
#   fit their maxima by construction (C*NP-1, S*C-1 per the header). The
# wrapper (tb_top.sv) itself must stay warning-free — verified by the
# zero-mention check below. Tighten this the day the stitching lands.
TOPFLAGS := --cc --exe --trace-fst --build -j $(VL_JOBS) --unroll-limit 131072 \
  -Wno-UNDRIVEN -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING \
  -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
  -Wno-WIDTHCONCAT -Wno-WIDTHTRUNC
$(HERE)/obj_top/Vtb_top: $(HERE)/tb_top.sv $(HERE)/tb_top.cpp $(ROOT)/src/components/*.v
	cd $(HERE) && $(VL) $(TOPFLAGS) --top-module tb_top --Mdir obj_top \
	  tb_top.sv tb_top.cpp $(ROOT)/src/components/*.v

clean:
	rm -rf obj_embed obj_rmsnorm obj_inproj obj_chunk_equiv obj_codec obj_top waves_embed.fst waves_rmsnorm.fst waves_inproj.fst waves_top.fst
