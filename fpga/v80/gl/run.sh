#!/bin/bash
# Gate-level simulation of the synthesized meimei block (used to find the free-list bug fixed in 12f5d89).
#
#   fpga/v80/gl/run.sh build [dcp]     netlist from a checkpoint of the BD build (~5 min) + xvlog/xelab (~15 min)
#   fpga/v80/gl/run.sh synth [small|full]  synthesize the current RTL standalone (synth.tcl, ~25 min) instead,
#                                      to check an RTL change at gate level before building a PDI
#   fpga/v80/gl/run.sh <prog> [...]    run probe programs (progs.py names), ~20 s - 2 min each
#   CODE=<code.hex> DATA=<data.hex> fpga/v80/gl/run.sh -  run any image (e.g. software/hello; ~10 min)
# env: V80_RELEASE (the V80 base-design package, default $HOME/v80_release), VIVADO_BIN
#
# Run the programs one after another: parallel xsim runs on one snapshot clobber each other.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
B=$HERE/build
VIV=${VIVADO_BIN:-/tools/Xilinx/Vivado/2024.1/bin}
DCP_DEFAULT=${V80_RELEASE:-$HOME/v80_release}/v80/hw/redad_v80/build/prj.runs/top_meimei_top_0_synth_1/top_meimei_top_0.dcp
mkdir -p "$B"; cd "$B"
if [ "$1" = build ] || [ "$1" = synth ]; then
    if [ "$1" = build ]; then
        dcp=${2:-$DCP_DEFAULT}
        "$VIV/vivado" -mode batch -nojournal -nolog -source "$HERE/export.tcl" -tclargs "$dcp" "$B/meimei_funcsim.v" > export.log
        python3 "$HERE/mk_tb.py" "$HERE/../sim/tb_v80.sv" tb_gl.sv top_meimei_top_0
    else
        "$VIV/vivado" -mode batch -nojournal -nolog -source "$HERE/synth.tcl" -tclargs "$B" "${2:-small}" > synth.log
        python3 "$HERE/mk_tb.py" "$HERE/../sim/tb_v80.sv" tb_gl.sv mm_v80_top_bd
    fi
    "$VIV/xvlog" -sv tb_gl.sv > xvlog_tb.log
    "$VIV/xvlog" meimei_funcsim.v "$VIV/../data/verilog/src/glbl.v" > xvlog_net.log
    "$VIV/xelab" -mt 16 -L unisims_ver -L secureip tb_v80 glbl -s gl > xelab.log
    python3 "$HERE/progs.py" "$B/progs"
    echo "built $B (snapshot gl)"
    exit 0
fi
if [ "$1" = - ]; then
    "$VIV/xsim" gl -R -log run_image.log -testplusarg CODE=$CODE -testplusarg DATA=$DATA \
        -testplusarg MAXCYC=${MAXCYC:-500000} > /dev/null 2>&1 || true
    sed -n '/\[tb\] loaded/,$p' run_image.log | grep -vE '^(INFO|[$]finish|run:|exit)' | head -40
    exit 0
fi
for p in "$@"; do
    "$VIV/xsim" gl -R -log "run_$p.log" -testplusarg CODE=progs/$p.code.hex \
        -testplusarg DATA=progs/zero.data.hex -testplusarg MAXCYC=${MAXCYC:-2500} > /dev/null 2>&1 || true
    printf '%-12s ' "$p"; grep -E "exit code|TIMEOUT|^[A-E]+" "run_$p.log" | sed 's/ after.*//' | tr '\n' ' '; echo
done
