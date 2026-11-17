#!/bin/bash
# Synthesize mm_dmem alone and simulate the netlist (the copy-0 write-enable bug fixed in 64cef2a), ~3 min.
#   fpga/v80/gl/dmem/run.sh [mm_mem.sv]     default: rtl/mm_mem.sv
# Prints one line per URAM / BRAM (EN / RDB_WR / BWE drivers: V=VCC G=GND L=LUT) and the
# gate-level read-back of host / core writes on both load ports ("ERRORS 0" = good).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
VIV=${VIVADO_BIN:-/tools/Xilinx/Vivado/2024.1/bin}
SRC=$(realpath "${1:-$HERE/../../../../rtl/mm_mem.sv}")
B=$HERE/../build/dmem; rm -rf "$B"; mkdir -p "$B"; cd "$B"
"$VIV/vivado" -mode batch -nojournal -nolog -source "$HERE/dmem_ooc.tcl" -tclargs "$SRC" "$B" > ooc.log 2>&1
grep -E "^(URAM|BRAM)" ooc.log
"$VIV/xvlog" -sv "$HERE/tb_dmem.sv" > xvlog_tb.log
"$VIV/xvlog" dmem_funcsim.v "$VIV/../data/verilog/src/glbl.v" > xvlog.log
"$VIV/xelab" -L unisims_ver -L secureip tb glbl -s sim > xelab.log
"$VIV/xsim" sim -R 2>&1 | grep -E "^(ok|FAIL|ERRORS)"
