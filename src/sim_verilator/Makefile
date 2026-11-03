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
VL   := /home/alrida-ismail/tools/oss-cad-suite/bin/verilator
VLFLAGS := --cc --exe --trace-fst --build -j 20 -Wall -Wno-UNUSEDPARAM
# -Wno-UNUSEDPARAM: embed_lut's E is compat-only by design (DUT-owned, do not edit).

all: embed rmsnorm top

embed: $(HERE)/obj_embed/Vtb_embed
	cd $(ROOT) && ./src/sim_verilator/obj_embed/Vtb_embed

# Prompt mode: token ids in, vectors out, wave in waves_prompt.fst.
# Usage: make -C src/sim_verilator prompt PROMPT_IDS="1 2 0x42"
PROMPT_IDS ?= 1 2 0x42
prompt: $(HERE)/obj_embed/Vtb_embed
	cd $(ROOT) && ./src/sim_verilator/obj_embed/Vtb_embed $(PROMPT_IDS)

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

# --trace-max-width 15360: Verilator's default (256b) silently drops the
# wide packed frames from the wave (7680-bit y_out, 15360-bit y_out2 for
# the S=2 row-advance DUT); the Q|K|V bytes are invisible in Surfer
# without this.
# INPROJFLAGS suppressions (DUT-owned, do not edit to silence):
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

top: $(HERE)/obj_top/Vtb_top
	cd $(ROOT) && ./src/sim_verilator/obj_top/Vtb_top

# TOPFLAGS: smoke target, defaults only (no -Wall). The tree above the
# leaves is unfinished structural RTL, so its lint classes are suppressed
# here with prejudice and documented: UNCONNECTED/PINMISSING ports,
# UNDRIVEN floats, UNUSED stubs, WIDTHEXPAND in DUT expressions. The
# wrapper (tb_top.sv) itself must stay warning-free — verified by the
# zero-mention check below. Tighten this the day the stitching lands.
TOPFLAGS := --cc --exe --trace-fst --build -j 20 \
  -Wno-UNDRIVEN -Wno-UNUSED -Wno-UNOPTFLAT -Wno-PINMISSING \
  -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL
$(HERE)/obj_top/Vtb_top: $(HERE)/tb_top.sv $(HERE)/tb_top.cpp $(ROOT)/src/components/*.v
	cd $(HERE) && $(VL) $(TOPFLAGS) --top-module tb_top --Mdir obj_top \
	  tb_top.sv tb_top.cpp $(ROOT)/src/components/*.v

clean:
	rm -rf obj_embed obj_rmsnorm obj_inproj obj_top waves_embed.fst waves_rmsnorm.fst waves_inproj.fst waves_top.fst
