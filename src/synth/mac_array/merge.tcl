-- merge.tcl — magic batch LEF/DEF -> GDS (run via run.sh in this dir).
lef read $::env(PDK)/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
lef read $::env(PDK)/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
def read pnr/mac_array.def
load mac_array
gds write mac_array.gds
quit -noprompt
