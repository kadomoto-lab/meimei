#
# Freestanding self-test image for the V80 simulation (no newlib: the Vitis / riscv-gnu toolchains
# do not agree on the link addresses for their libc, and the self-test only needs the SoC header).
#
#   make [PREFIX=riscv64-unknown-elf-]        -> code.hex / data.hex
#
TOOLS   ?= ../../../../software/software_tools
ITERS   ?= 1000
PREFIX  ?= riscv64-unknown-elf-
CC      = $(PREFIX)gcc
OBJDUMP = $(PREFIX)objdump
ARCH    = -march=rv64imfdc_zicsr -mabi=lp64d -mcmodel=medany -msmall-data-limit=0 -mno-relax
EXPECT  ?= 0x79d0be5ae1616157
CFLAGS  = $(ARCH) -O2 -g -Wall -ffreestanding -fno-builtin -I$(TOOLS) \
          -DLCG_ITERS=$(ITERS) -DEXPECT_ACC=$(EXPECT)ull
LDFLAGS = $(ARCH) -nostdlib -nostartfiles -T $(TOOLS)/link.ld

all: code.hex

app.elf: start.S selftest.c $(TOOLS)/link.ld $(TOOLS)/soc.h
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ start.S selftest.c
	$(OBJDUMP) -d -S $@ > app.dump

code.hex: app.elf
	python3 $(TOOLS)/elf2hex.py $< .

clean:
	rm -f app.elf app.dump code.hex data.hex

.PHONY: all clean
