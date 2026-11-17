# Embench-IoT on the meimei SoC
#   make                         build every benchmark into build/<name>/{app.elf,code.hex,data.hex}
#   make BENCH=crc32             build one
#   make COMP=gcc14              everything (benchmarks, crt0, newlib, libm, link) with the GCC 14.4 toolchain
#                                in ~/opt/riscv64-gcc14 -> build-gcc14/
#   make COMP=gcc12 / COMP=clang compile the benchmark sources with another compiler into build-<COMP>/
#                                (crt0 / syscalls / newlib / libm and the link stay with the GCC 15.1 toolchain)
# Embench itself is not vendored: clone it and point EMBENCH at the tree (default: tag embench-1.0)
#   git clone https://github.com/embench/embench-iot && git -C embench-iot checkout embench-1.0
EMBENCH  ?= $(HOME)/opt/src/embench/embench-1.0
CPU_MHZ  ?= 1          # Embench's iteration scale (1 = the per-MHz score's reference)
BENCHES  ?= $(notdir $(wildcard $(EMBENCH)/src/*))
COMP     ?=            # empty = GCC 15.1 (~/opt/riscv64) for everything

GCC12    ?= /tools/Xilinx/Vitis/2024.1/gnu/riscv/lin/riscv64-unknown-elf/bin/riscv64-unknown-elf-gcc
CLANG    ?= clang --target=riscv64-unknown-elf --sysroot=$(HOME)/opt/riscv64/riscv64-unknown-elf
XCC_gcc12 = $(GCC12)
XCC_clang = $(CLANG)

ifeq ($(strip $(COMP)),gcc14)
RISCV    := $(HOME)/opt/riscv64-gcc14
endif
BDIR      = build$(if $(strip $(COMP)),-$(strip $(COMP)))

ifdef BENCH
BSRCS    = $(wildcard $(EMBENCH)/src/$(BENCH)/*.c) $(EMBENCH)/support/main.c \
           $(EMBENCH)/support/beebsc.c boardsupport.c
BUILD    = $(BDIR)/$(BENCH)
BFLAGS   = $(BXCFLAGS) -I$(EMBENCH)/support -I. -DHAVE_BOARDSUPPORT_H -DCPU_MHZ=$(strip $(CPU_MHZ)) -DWARMUP_HEAT=1 -std=gnu17
ifeq ($(filter gcc12 clang,$(strip $(COMP))),)
SRCS     = $(BSRCS)
XCFLAGS  = $(BFLAGS) -Wno-unused-variable -Wno-unused-but-set-variable -Wno-maybe-uninitialized -Wno-misleading-indentation
else
# objects from the other compiler, passed to the normal link rule as "sources"
XCC      = $(XCC_$(strip $(COMP)))
SRCS     = $(addprefix $(BUILD)/obj/,$(notdir $(BSRCS:.c=.o)))
vpath %.c $(sort $(dir $(BSRCS)))
$(BUILD)/obj/%.o: %.c
	@mkdir -p $(dir $@)
	$(XCC) -march=rv64imfdc_zicsr -mabi=lp64d -mcmodel=medany -O2 -ffunction-sections -fdata-sections \
	  -fno-asynchronous-unwind-tables -I../software_tools $(BFLAGS) -w -c $< -o $@
endif
include ../software_tools/Makefile.inc
else
all:
	@for b in $(BENCHES); do $(MAKE) --no-print-directory BENCH=$$b || exit 1; done
clean:
	rm -rf build build-*
.PHONY: all clean
endif
