#!/bin/sh
# FPU unit test: random + special-value vectors from fpmodel.py applied to the FPU modules
#   usage: tb/fpu/run.sh [N vectors] [seed]
cd "$(dirname "$0")"
if [ ! -x obj/Vfpu_tb ] || [ -n "$REBUILD" ]; then
  verilator --binary --timing -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-TIMESCALEMOD \
    --top-module fpu_tb -Mdir obj ../../rtl/cpu_pkg.sv ../../rtl/mm_pkg.sv ../../rtl/muldiv.sv ../../rtl/fpu.sv fpu_tb.sv -j $(nproc) >/dev/null 2>&1 \
    || { echo build failed; exit 1; }
fi
python3 fpu_vec.py ${1:-100000} ${2:-1} > vectors.txt && ./obj/Vfpu_tb | grep -E "MISMATCH|passed"
