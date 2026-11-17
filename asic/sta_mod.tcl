read_liberty asap7_rvt_tt.lib
read_verilog $::env(NET)
link_design $::env(TOP)
create_clock -name clk -period 1000 [get_ports clk]
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -digits 1 -fields {fanout} > sta_$::env(TOP).rpt
report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -group_path_count 200 -endpoint_path_count 1 -format end -digits 1 > sta_end_$::env(TOP).rpt
