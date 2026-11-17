#!/bin/sh
# run every C test in ../software/tests/build on the SoC model and compare the UART output with
# the host golden output; also requires exit code 0. usage: run_tests.sh <Vtb_soc> [CHECK=1: ISS lockstep]
VTB=$(realpath "$1"); fail=0; n=0
cd "$(dirname "$0")"
for d in ../software/tests/build/*/; do
  t=$(basename $d); n=$((n+1))
  ( cd $d && $VTB +CODE=code.hex +DATA=data.hex +MAXCYC=${MAXCYC:-20000000} ${CHECK:++TRACE=rtl_trace.txt} > sim.log )
  tr -d '\r' < $d/uart.log > $d/uart.txt
  echo "exit $(awk '{print $2}' $d/sim_result.txt)" >> $d/uart.txt
  res=$(cat $d/sim_result.txt)
  if cmp -s $d/uart.txt $d/golden.txt; then st=PASS; else st=FAIL; fail=$((fail+1)); fi
  if [ -n "$CHECK" ]; then python3 rvsim.py $d --check $d/rtl_trace.txt --quiet | tail -1; fi
  echo "$st $t ($res)"
done
echo "$((n-fail))/$n tests passed"
[ $fail = 0 ]
