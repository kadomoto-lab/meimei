#
# V80 top simulation (Verilator): load an image through the host AXI port, run, read the console.
#
#   make build [CONFIG=small|full]   build obj_<CONFIG>/Vtb_v80
#   make run   [CONFIG=small|full]   build the freestanding self-test, load it over AXI,
#                                    compare the console output with prog/expected.txt
#
CONFIG ?= small
OBJ     = obj_$(CONFIG)
VFLAGS_small = +define+MM_SMALL
VFLAGS_full  =
VERILATOR ?= verilator
# Verilator's C++ runtime needs C++20 coroutines (-fcoroutines): gcc >= 11 or clang >= 11.
# Pick the first compiler on this machine that has it (the system `c++` may be gcc 8); override
# with `make SIM_CXX=...`.
# (RHEL gcc-toolset g++ first: it is built for the system glibc; a homebrew g++ fails to link with
#  __libc_single_threaded on RHEL8, and clang++ picks up gcc-toolset's <coroutine> headers)
CXX_PROBE ?= c++ g++ /opt/rh/gcc-toolset-13/root/usr/bin/g++ /opt/rh/gcc-toolset-14/root/usr/bin/g++ \
            /opt/rh/gcc-toolset-15/root/usr/bin/g++ g++-13 g++-12 g++-11 clang++ clang++-21 clang++-20
SIM_CXX ?= $(shell for c in $(CXX_PROBE); do command -v $$c >/dev/null 2>&1 || continue; \
          if echo 'int main(){}' | $$c -fcoroutines -x c++ -fsyntax-only - >/dev/null 2>&1; then echo $$c; break; fi; done)
# verilated.mk is configured for gcc's `-include x` PCH style; clang needs -include-pch.
# verilated.mk hardcodes CXX=c++/LINK=c++ (line 16-17), so both must be overridden on the make
# command line. The gcc-toolset libstdc++.so is an ld script pointing at the system
# /usr/lib64/libstdc++.so.6 (GLIBCXX <= 3.4.25), which lacks what the newer headers expect, so link
# the toolset's libstdc++.a statically. libatomic exists only for the system gcc, so pass it by path.
CXX_MK = CXX=$(SIM_CXX) LINK=$(SIM_CXX)
LINK_MK = LDFLAGS='-static-libstdc++ -static-libgcc' \
          LDLIBS='-pthread -lpthread /usr/lib64/libatomic.so.1'
PCH_MK =
ifneq ($(findstring clang,$(SIM_CXX)),)
PCH_MK = VK_PCH_I_FAST='-include-pch Vtb_v80__pch.h.fast.gch' VK_PCH_I_SLOW='-include-pch Vtb_v80__pch.h.slow.gch'
LINK_MK = LDFLAGS=
endif
JOBS      ?= 8
MAXCYC    ?= 2000000
PREFIX    ?= riscv64-unknown-elf-

RTL_DIR = ../../../rtl
V80_DIR = ..
RTL = $(RTL_DIR)/cpu_pkg.sv $(RTL_DIR)/mm_pkg.sv $(RTL_DIR)/rvc.sv $(RTL_DIR)/muldiv.sv $(RTL_DIR)/mm_mem.sv \
      $(RTL_DIR)/alu.sv $(RTL_DIR)/decoder.sv $(RTL_DIR)/mm_decode.sv $(RTL_DIR)/fpu.sv $(RTL_DIR)/issue_queue.sv \
      $(RTL_DIR)/mm_freelist.sv $(RTL_DIR)/mm_wbpipe.sv $(RTL_DIR)/frontend.sv $(RTL_DIR)/mm_core.sv $(RTL_DIR)/mm_soc.sv \
      $(V80_DIR)/mm_uart_host_tx.sv $(V80_DIR)/mm_host_axi.sv $(V80_DIR)/mm_v80_top.sv
TB = tb_v80.sv

build: $(OBJ)/Vtb_v80
$(OBJ)/Vtb_v80: $(RTL) $(TB)
	$(VERILATOR) --cc --exe --main --timing $(VFLAGS_$(CONFIG)) -O3 --x-assign fast --x-initial fast \
	  -Wno-fatal -Wno-MULTIDRIVEN -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-TIMESCALEMOD \
	  -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-INITIALDLY \
	  --top-module tb_v80 -Mdir $(OBJ) $(RTL) $(TB) > $(OBJ).log 2>&1 || (tail -30 $(OBJ).log; exit 1)
	@echo "building with CXX=$(SIM_CXX)"
	$(MAKE) -C $(OBJ) -f Vtb_v80.mk $(CXX_MK) $(PCH_MK) $(LINK_MK) -j $(JOBS) >> $(OBJ).log 2>&1 || (grep -E "error|Error" $(OBJ).log | head -20; exit 1)

prog/code.hex: prog/selftest.c prog/start.S
	$(MAKE) -C prog PREFIX=$(PREFIX)

run: build prog/code.hex
	$(OBJ)/Vtb_v80 +CODE=prog/code.hex +DATA=prog/data.hex +MAXCYC=$(MAXCYC) +UART=uart.txt > run.log 2>&1; \
	  st=$$?; cat run.log; \
	  if [ $$st -ne 0 ]; then echo "RUN FAILED"; exit $$st; fi; \
	  diff -u prog/expected.txt uart.txt && echo "UART OUTPUT MATCHES prog/expected.txt"

clean:
	rm -rf obj_small obj_full obj_small.log obj_full.log run.log uart.txt
	$(MAKE) -C prog clean

.PHONY: build run clean
