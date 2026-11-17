read_liberty asap7_rvt_tt.lib
read_verilog $::env(NET)
link_design $::env(TOP)
create_clock -name clk -period 1000 [get_ports clk]
set_input_delay 0 -clock clk [delete_from_list [all_inputs] [get_ports clk]]
set_output_delay 0 -clock clk [all_outputs]
report_checks -group_path_count 100000 -endpoint_path_count 1 -format end -digits 1 > sta_stage_end.rpt
