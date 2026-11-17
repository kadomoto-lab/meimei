# mm_dmem alone, out of context, on the V80 part: print how each RAM copy's write port is wired and
# write a funcsim netlist for tb_dmem.sv (the copy-0 write-enable bug fixed in 64cef2a).
#   vivado -mode batch -source dmem_ooc.tcl -tclargs <mm_mem.sv> <out dir>
lassign $argv src out
set R [file normalize [file dirname [info script]]/../../../../rtl]
read_verilog -sv [list $R/cpu_pkg.sv $R/mm_pkg.sv $src]
synth_design -top mm_dmem -part xcv80-lsva4737-2MHP-e-S -mode out_of_context -verilog_define MM_SMALL -generic WORDS=8192 > $out/synth.log
proc drv {pin} {
  set net [get_nets -quiet -of $pin]
  if {$net eq ""} { return "<unconnected>" }
  set d [get_pins -quiet -leaf -of $net -filter {DIRECTION==OUT}]
  if {$d eq ""} { return "net $net" }
  return "[get_property REF_NAME [get_cells -of $d]]"
}
proc dump {} {
  foreach c [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.URAM.*}] {
    set s "[file tail $c]:"
    foreach p {EN_A RDB_WR_A EN_B RDB_WR_B} { append s " $p=[drv [get_pins $c/$p]]" }
    set ba ""; set bb ""
    for {set i 0} {$i < 9} {incr i} { append ba "[string index [drv [get_pins $c/BWE_A[$i]]] 0]"; append bb "[string index [drv [get_pins $c/BWE_B[$i]]] 0]" }
    append s " BWE_A=$ba BWE_B=$bb"
    set da 0; set db 0; set ina 0; set inb 0
    for {set i 0} {$i < 64} {incr i} {
      if {[llength [get_pins -quiet -leaf -of [get_nets -quiet -of [get_pins $c/DOUT_A[$i]]] -filter {DIRECTION==IN}]]} {incr da}
      if {[llength [get_pins -quiet -leaf -of [get_nets -quiet -of [get_pins $c/DOUT_B[$i]]] -filter {DIRECTION==IN}]]} {incr db}
      if {![string match "GND*" [drv [get_pins $c/DIN_A[$i]]]]} {incr ina}
      if {![string match "GND*" [drv [get_pins $c/DIN_B[$i]]]]} {incr inb}
    }
    append s " DOUT_A_used=$da DOUT_B_used=$db DIN_A_nonconst=$ina DIN_B_nonconst=$inb"
    puts "URAM $s"
  }
}

dump
foreach c [get_cells -hier -filter {PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.*}] {
  set s "BRAM [file tail $c]:"
  foreach p [get_pins $c/WE*] { append s " [file tail $p]=[string index [drv $p] 0]" }
  puts $s
}
write_verilog -mode funcsim -force $out/dmem_funcsim.v
