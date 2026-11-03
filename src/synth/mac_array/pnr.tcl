# pnr.tcl — OpenROAD floorplan/place/route for mac_array (demo scope).
# Single ideal clock, no CTS, no power grid (tapcells + abutted rows).
# Run via run.sh. Env: PDK, LIB.
set PDK $::env(PDK)
set LIB $::env(LIB)
set HERE [file dirname [info script]]

read_liberty $LIB
read_lef $PDK/libs.ref/sky130_fd_sc_hd/techlef/sky130_fd_sc_hd__nom.tlef
read_lef $PDK/libs.ref/sky130_fd_sc_hd/lef/sky130_fd_sc_hd.lef
read_verilog $HERE/nl/mac_array.nl.v
link_design mac_array

create_clock -name clk -period 25 [get_ports clk]
set_clock_uncertainty 0.5 [get_clocks clk]

initialize_floorplan -die_area "0 0 480 480" -core_area "15 15 465 465" -site unithd
make_tracks
tapcell \
  -tapcell_master sky130_fd_sc_hd__tap_1 \
  -endcap_master sky130_fd_sc_hd__decap_3 \
  -distance 14

global_placement -skip_io
repair_design
place_pins -hor_layers met3 -ver_layers met2
detailed_placement
detailed_placement -disallow_one_site_gaps

# DEF round-trip: drops the pinless tapcell power phantom (see README)
# so TritonRoute only sees real SIGNAL nets.
write_def $HERE/pnr/mac_array.placed.def
puts "PLACE DONE"
