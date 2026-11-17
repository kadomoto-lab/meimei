# Synthesize the meimei block (mm_v80_top_bd) out of context, without the V80 shell, and write a
# gate-level netlist -- the same netlist the BD build makes for the meimei cell, in ~25 min instead
# of a full PDI build. Used to check an RTL fix at gate level before building a PDI.
#   vivado -mode batch -source synth.tcl -tclargs <out dir> [small|full]
lassign $argv out cfg
set R [file normalize [file dirname [info script]]/../../../rtl]
set V [file normalize [file dirname [info script]]/..]
read_verilog -sv [list $R/cpu_pkg.sv $R/mm_pkg.sv $R/rvc.sv $R/muldiv.sv $R/mm_mem.sv $R/alu.sv $R/decoder.sv \
    $R/mm_decode.sv $R/fpu.sv $R/issue_queue.sv $R/mm_freelist.sv $R/mm_wbpipe.sv $R/frontend.sv $R/mm_core.sv \
    $R/mm_soc.sv $V/mm_uart_host_tx.sv $V/mm_host_axi.sv $V/mm_v80_top.sv]
read_verilog $V/mm_v80_top_bd.v
if {$cfg eq "full"} {
    synth_design -top mm_v80_top_bd -part xcv80-lsva4737-2MHP-e-S -mode out_of_context
} else {
    synth_design -top mm_v80_top_bd -part xcv80-lsva4737-2MHP-e-S -mode out_of_context -verilog_define MM_SMALL
}
write_checkpoint -force $out/meimei_ooc.dcp
write_verilog -mode funcsim -force $out/meimei_funcsim.v
report_utilization -file $out/util.rpt
