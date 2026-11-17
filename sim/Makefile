#
# SoC simulation (Verilator): bare-metal programs from ../software on mm_soc
#
#   make build [CONFIG=full|small]           build obj_<CONFIG>/Vtb_soc (full: 8-wide default
#                                            configuration, ~20 min; small: 4-wide MM_SMALL, < 1 min)
#   make run PROG=../software/hello          run one program (prog dir with code.hex / data.hex)
#   make check PROG=...                      run + lockstep comparison with the ISS (rvsim.py)
#   make test                                all C tests: UART output == host golden, exit code 0
#   make coremark                            CoreMark (../software/coremark, ITERATIONS from its Makefile)
#
CONFIG ?= small
OBJ     = obj_$(CONFIG)
VFLAGS_small = +define+MM_SMALL
VFLAGS_full  =
VERILATOR ?= verilator
RTL = ../rtl/cpu_pkg.sv ../rtl/mm_pkg.sv ../rtl/rvc.sv ../rtl/muldiv.sv ../rtl/mm_mem.sv ../rtl/alu.sv \
      ../rtl/decoder.sv ../rtl/mm_decode.sv ../rtl/fpu.sv ../rtl/issue_queue.sv ../rtl/mm_freelist.sv ../rtl/mm_wbpipe.sv \
      ../rtl/frontend.sv ../rtl/mm_core.sv ../rtl/mm_soc.sv tb_soc.sv
VINC = perf.svh
PROG ?= ../software/hello
MAXCYC ?= 50000000

build: $(OBJ)/Vtb_soc
$(OBJ)/Vtb_soc: $(RTL) $(VINC)
	$(VERILATOR) --binary --timing $(VFLAGS_$(CONFIG)) -O3 --x-assign fast --x-initial fast \
	  -Wno-fatal -Wno-MULTIDRIVEN -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-LATCH -Wno-TIMESCALEMOD \
	  --top-module tb_soc -Mdir $(OBJ) $(RTL) -j $(JOBS) > $(OBJ).log 2>&1 || (tail -20 $(OBJ).log; exit 1)
JOBS ?= 8

run: build
	cd $(PROG) && $(abspath $(OBJ))/Vtb_soc +CODE=code.hex +DATA=data.hex +MAXCYC=$(MAXCYC) | grep -v '^- '

check: build
	cd $(PROG) && $(abspath $(OBJ))/Vtb_soc +CODE=code.hex +DATA=data.hex +MAXCYC=$(MAXCYC) +TRACE=rtl_trace.txt > /dev/null
	python3 rvsim.py $(PROG) --check $(PROG)/rtl_trace.txt --quiet

test: build
	./run_tests.sh $(OBJ)/Vtb_soc

coremark: build
	$(MAKE) run PROG=../software/coremark

.PHONY: build run check test coremark
