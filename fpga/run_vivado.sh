#!/bin/sh
# run fpga/build.tcl with the Windows Vivado from WSL: sources are copied to a Windows directory
#   fpga/run_vivado.sh <stage> <config> <imem_words> <dmem_words> <clk_mhz> [<prog dir with code.hex/data.hex>]
# env: VIVADO (default C:\Xilinx\Vivado\2024.2\bin\vivado.bat), WINDIR_WSL (default /mnt/c/Users/$USER_WIN/meimei_fpga)
set -e
cd "$(dirname "$0")/.."
VIVADO=${VIVADO:-'C:\Xilinx\Vivado\2024.2\bin\vivado.bat'}
W=${WINDIR_WSL:-/mnt/c/Users/${USER_WIN:-$USER}/meimei_fpga}
mkdir -p $W/rtl $W/fpga/rtl $W/prog
cp rtl/*.sv $W/rtl/ && cp fpga/build.tcl fpga/nexys_video.xdc $W/fpga/ && cp fpga/rtl/*.sv $W/fpga/rtl/
HEX=""
if [ -n "$6" ]; then
  # per-bank images: instruction memory NSLOT word banks (16 for small, 32 for full), data memory 2 banks
  if [ "$2" = small ]; then NB=16; else NB=32; fi
  cp $6/code.hex $W/prog/code.hex; cp $6/data.hex $W/prog/data.hex
  python3 fpga/split_hex.py $W/prog/code.hex $3 $NB && python3 fpga/split_hex.py $W/prog/data.hex $4 2
  HEX="../prog/code.hex ../prog/data.hex"
fi
cd $W/fpga
cmd.exe /c "$VIVADO -mode batch -nojournal -log vivado_$2_$3_$4.log -source build.tcl -tclargs $1 $2 $3 $4 $5 $HEX"
echo "reports: $W/fpga/out_$2_$3_$4/"
