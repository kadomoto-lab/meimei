#!/bin/sh
# SystemVerilog -> Verilog for Yosys: asic/sv2v.sh <small|full> <out.v>
O=$(realpath -m "$2"); cd "$(dirname "$0")/.."
D="-DSYNTHESIS"; [ "$1" = small ] && D="$D -DMM_SMALL"
R=rtl
$HOME/opt/sv2v/sv2v-Linux/sv2v $D $R/cpu_pkg.sv $R/mm_pkg.sv $R/rvc.sv $R/muldiv.sv $R/mm_mem.sv $R/alu.sv $R/decoder.sv \
  $R/mm_decode.sv $R/fpu.sv $R/issue_queue.sv $R/mm_freelist.sv $R/mm_wbpipe.sv $R/frontend.sv $R/mm_core.sv > "$O" || exit 1
# always_comb blocks reading module arrays through functions: sv2v lists the arrays, Yosys wants @(*)
sed -i -E '/edge/!s/always @\(.*\)( begin.*)?$/always @(*)\1/' "$O"
