#!/bin/sh
# random differential test: OoO RTL (Verilator) vs Python RV64IMFDC_Zicsr ISS
#   usage: [MODE=...] run.sh [N seeds] [first seed]
#   MODE: (empty) random | loop | fp (F/D + M) | fpcsr (fp + Zicsr) | fploop | rvc (RVC-heavy loop);
#         append +c to re-layout any program with compressed instructions (e.g. MODE=loop+c)
cd "$(dirname "$0")/.."
if [ ! -x obj/Vtb ] || [ -n "$REBUILD" ]; then
  verilator --binary --timing $VFLAGS -Wno-fatal -Wno-MULTIDRIVEN -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-TIMESCALEMOD \
    --top-module tb -Mdir obj rtl/cpu_pkg.sv rtl/mm_pkg.sv rtl/rvc.sv rtl/muldiv.sv rtl/mm_mem.sv rtl/alu.sv rtl/decoder.sv rtl/mm_decode.sv \
    rtl/fpu.sv rtl/issue_queue.sv rtl/mm_freelist.sv rtl/mm_wbpipe.sv rtl/frontend.sv rtl/mm_core.sv tb/tb.sv -j $(nproc) >/dev/null 2>&1 || { echo build failed; exit 1; }
fi
cd tb
N=${1:-100}; S=${2:-1}; fail=0; ti=0; tc=0
for s in $(seq $S $((S+N-1))); do
  python3 gen.py $s $MODE && ../obj/Vtb +CYC=${CYC:-6000} >/dev/null
  python3 cmp.py || { echo "MISMATCH seed $s"; fail=$((fail+1)); }
  c=$(cat cycles.txt); [ "$c" -gt 0 ] || { echo "NO HALT seed $s"; fail=$((fail+1)); }
  ti=$((ti+$(cat iss_count.txt))); tc=$((tc+c))
done
echo "$((N-fail))/$N passed, IPC = $(python3 -c "print(round($ti/$tc,3))") ($ti insns / $tc cycles)"
