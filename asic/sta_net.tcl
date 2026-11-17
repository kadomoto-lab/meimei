read_liberty asap7_rvt_tt.lib
read_verilog $::env(NET)
link_design $::env(TOP)
create_clock -name clk -period 1000 [get_ports clk]
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 1 -fields {net} > sta_net_$::env(TOP).rpt
