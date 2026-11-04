-- merge.tcl — magic batch LEF/DEF -> GDS (run via run.sh with CWD=out/<TAG>).
lef read $::env(PDK)/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
lef read $::env(PDK)/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
def read pnr/attention_core.def
load attention_core
gds write attention_core_$::env(TAG).gds
quit -noprompt
