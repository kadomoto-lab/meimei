# Write a gate-level (funcsim) netlist of the meimei block from a Vivado checkpoint.
#   vivado -mode batch -source export.tcl -tclargs <dcp> <out.v>
# <dcp> is normally the OOC synthesis checkpoint of the BD cell:
#   <redad_v80>/build/prj.runs/top_meimei_top_0_synth_1/top_meimei_top_0.dcp
lassign $argv dcp out
open_checkpoint $dcp
write_verilog -mode funcsim -force $out
