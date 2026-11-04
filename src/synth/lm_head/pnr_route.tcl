# pnr_route.tcl — OpenROAD global+detail route from placed DEF (demo scope).
# Part of run.sh. The DEF round-trip drops the pinless tapcell power
# phantom that TritonRoute rejects; the placed geometry is untouched.
# Outputs land in out/<TAG>/ (OUT env).
set PDK $::env(PDK)
set HERE [file dirname [info script]]
set OUT $::env(OUT)

read_lef $PDK/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
read_lef $PDK/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
read_def $OUT/pnr/lm_head.placed.def

# Tapcell power nets are real and connected but have no grid; mark them
# special so the routers skip them (librelane pdn_cfg.tcl same pattern).
set block [ord::get_db_block]
foreach {nm ty} {one_ POWER zero_ GROUND} {
  set n [$block findNet $nm]
  if {$n != "NULL"} { $n setSpecial; $n setSigType $ty }
}

create_clock -name clk -period 25 [get_ports clk]
set_clock_uncertainty 0.5 [get_clocks clk]

global_route -verbose
detailed_route -output_maze $OUT/pnr/route.maze.log -output_drc $OUT/pnr/route.drc
report_checks -path_delay min_max -format full_clock_expanded -fields {input_pins nets} -digits 4 > $OUT/pnr/timing.rpt
report_check_types -max_violation_count 10 > $OUT/pnr/drc.rpt
write_def $OUT/pnr/lm_head.def
write_verilog $OUT/pnr/lm_head.pnr.v
puts "PNR DONE"
