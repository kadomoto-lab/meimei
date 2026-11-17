# Vivado non-project batch flow for mm_fpga_top on the Nexys Video
#   vivado -mode batch -source build.tcl -tclargs <stage> <config> <imem_words> <dmem_words> <clk_mhz> [<code.hex> <data.hex>]
#     stage : elab (RTL elaboration only) | synth | synthfast (no timing-driven opt) | impl | bit          config: small (MM_SMALL) | full (8-wide)
#     words : IMEM 32-bit words (16384 = 64 KiB), DMEM 64-bit words (8192 = 64 KiB)
# outputs in ./out_<config>_<imem_words>_<dmem_words>/ : reports, checkpoints, bitstream
lassign $argv stage config iw dw mhz code_hex data_hex
set part xc7a200tsbg484-1
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize $here/../rtl]
set out  [file normalize ./out_${config}_${iw}_${dw}]
file mkdir $out
set_param general.maxThreads 8
# fewer threads (and parallel synthesis workers) when the host is short of memory: VIV_THREADS=2 with
# WSLENV=VIV_THREADS when run from WSL
if {[info exists ::env(VIV_THREADS)]} { set_param general.maxThreads $::env(VIV_THREADS) }

read_verilog -sv [list \
    $rtl/cpu_pkg.sv $rtl/mm_pkg.sv $rtl/rvc.sv $rtl/muldiv.sv $rtl/mm_mem.sv $rtl/alu.sv $rtl/decoder.sv \
    $rtl/mm_decode.sv $rtl/fpu.sv $rtl/issue_queue.sv $rtl/mm_freelist.sv $rtl/mm_wbpipe.sv $rtl/frontend.sv $rtl/mm_core.sv \
    $rtl/mm_soc.sv $here/rtl/uart.sv $here/rtl/mm_fpga_top.sv ]
read_xdc $here/nexys_video.xdc

set defs [list MM_IMEM_WORDS=$iw MM_DMEM_WORDS=$dw]
if {$config eq "small"} { lappend defs MM_SMALL }
if {$code_hex ne ""} { lappend defs "MM_IMEM_INIT=\"[file normalize $code_hex]\"" "MM_DMEM_INIT=\"[file normalize $data_hex]\"" }

set t0 [clock seconds]
if {$stage eq "elab"} {
    synth_design -rtl -top mm_fpga_top -part $part -verilog_define $defs -generic CLK_MHZ=$mhz
    exit
}
# synthfast: no timing-driven optimization (much faster on this design; area is similar, timing is pessimistic)
set extra [expr {$stage eq "synthfast" ? "-no_timing_driven" : ""}]
synth_design -top mm_fpga_top -part $part -verilog_define $defs -generic CLK_MHZ=$mhz -flatten_hierarchy rebuilt {*}$extra
puts "SYNTH_TIME [expr {[clock seconds] - $t0}] s"
write_checkpoint -force $out/post_synth.dcp
report_utilization -file $out/util_synth.rpt
report_utilization -hierarchical -hierarchical_depth 4 -file $out/util_synth_hier.rpt
report_timing_summary -max_paths 10 -file $out/timing_synth.rpt
if {$stage eq "synth" || $stage eq "synthfast"} { exit }

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/post_route.dcp
report_utilization -file $out/util_route.rpt
report_timing_summary -max_paths 10 -file $out/timing_route.rpt
if {$stage eq "bit"} { write_bitstream -force $out/mm_fpga_top.bit }
