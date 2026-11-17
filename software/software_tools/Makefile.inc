#
# Shared build settings for bare-metal programs on the meimei SoC (RV64IMFDC_Zicsr)
#   include from an application Makefile after setting SRCS (and optionally XCFLAGS / XLDFLAGS);
#   `make` builds app.elf, app.dump, code.hex and data.hex in BUILD (default: .)
#
# Toolchain: riscv64-unknown-elf (riscv-gnu-toolchain, newlib, configured with
#   --with-arch=rv64imfdc_zicsr --with-abi=lp64d --with-cmodel=medany)
RISCV      ?= $(HOME)/opt/riscv64
PREFIX     ?= $(RISCV)/bin/riscv64-unknown-elf-
CC          = $(PREFIX)gcc
OBJDUMP     = $(PREFIX)objdump
SIZE        = $(PREFIX)size

TOOLS_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
BUILD      ?= .
OPT        ?= -O2

ARCHFLAGS   = -march=rv64imfdc_zicsr -mabi=lp64d -mcmodel=medany
CFLAGS      = $(ARCHFLAGS) $(OPT) -g -Wall -ffunction-sections -fdata-sections \
              -fno-asynchronous-unwind-tables -I$(TOOLS_ROOT) $(XCFLAGS)
LDFLAGS     = $(ARCHFLAGS) -nostartfiles -T $(TOOLS_ROOT)/link.ld -Wl,--gc-sections \
              --specs=nano.specs $(XLDFLAGS)
LIBS        = -lm -lc -lgcc

RUNTIME     = $(TOOLS_ROOT)/crt0.S $(TOOLS_ROOT)/syscalls.c

all: $(BUILD)/code.hex

$(BUILD)/app.elf: $(SRCS) $(RUNTIME) $(TOOLS_ROOT)/link.ld $(TOOLS_ROOT)/soc.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(RUNTIME) $(SRCS) $(LIBS)
	$(OBJDUMP) -d -S $@ > $(BUILD)/app.dump
	$(SIZE) $@

$(BUILD)/code.hex: $(BUILD)/app.elf $(TOOLS_ROOT)/elf2hex.py
	python3 $(TOOLS_ROOT)/elf2hex.py $< $(BUILD)

clean:
	rm -f $(BUILD)/app.elf $(BUILD)/app.dump $(BUILD)/code.hex $(BUILD)/data.hex

.PHONY: all clean
