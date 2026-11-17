# register-to-register timing of the mapped netlist (no wires: technology mapping only)
#   usage: sta sta.tcl  (env NET = netlist, TOP = top module, NPATH = paths reported)
read_liberty asap7_rvt_tt.lib
read_verilog $::env(NET)
link_design $::env(TOP)
create_clock -name clk -period 1000 [get_ports clk]
set_input_transition 10 [all_inputs]
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] \
    -group_path_count $::env(NPATH) -endpoint_path_count 1 -unique_paths_to_endpoint \
    -format end -digits 1 > sta_end.rpt
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 1 \
    -fields {fanout cap slew} > sta_worst.rpt
