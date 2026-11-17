read_liberty asap7_rvt_tt.lib
read_verilog fo4.v
link_design fo4
create_clock -name vclk -period 1000
set_input_delay 0 -clock vclk [get_ports a]
set_output_delay 0 -clock vclk [get_ports y]
set_input_transition 10 [get_ports a]
report_checks -from [get_ports a] -to [get_ports y] -digits 2 -fields {slew cap}
