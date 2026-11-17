# software — bare-metal programs for the meimei SoC

Layout follows mm-node (`software_tools/` + one directory per program):

```
software/
├── software_tools/   shared build settings and runtime
│   ├── Makefile.inc  toolchain / flags / rules (app.elf -> app.dump, code.hex, data.hex)
│   ├── link.ld       memory map: .text in IMEM, everything else in DMEM, 16 KiB stack at the top
│   ├── crt0.S        gp / sp, clear .bss, fcsr = 0, constructors, main(), exit()
│   ├── syscalls.c    newlib stubs: stdout/stderr -> UART, sbrk heap in DMEM, _exit -> SIM_EXIT
│   ├── soc.h         memory map, device registers, rdcycle / rdinstret, sim_exit()
│   └── elf2hex.py    ELF -> code.hex (32-bit words, IMEM) + data.hex (64-bit words, DMEM)
├── hello/            printf hello world
├── tests/            self-checking C tests (+ host golden outputs)
├── coremark/         EEMBC CoreMark (core_*.c from upstream, port/ for this SoC)
└── embench/          Embench-IoT (`EMBENCH=<tree>`, not vendored) + run_v80.py for the V80
```

## Toolchain

`riscv64-unknown-elf-gcc` from riscv-gnu-toolchain (GCC 15.1, newlib 4.4), configured for the core:

```bash
git clone https://github.com/riscv-collab/riscv-gnu-toolchain && cd riscv-gnu-toolchain
mkdir build && cd build
../configure --prefix=$HOME/opt/riscv64 --with-arch=rv64imfdc_zicsr --with-abi=lp64d --with-cmodel=medany --disable-gdb
make -j4 newlib          # about 1-2 h; more parallel jobs need > 8 GB RAM
```

`Makefile.inc` uses `RISCV ?= $(HOME)/opt/riscv64`; override with `make RISCV=/path`.
Compiler flags: `-march=rv64imfdc_zicsr -mabi=lp64d -mcmodel=medany -O2`, newlib-nano.

## Memory map (rtl/mm_soc.sv)

| address | size | |
|---|---|---|
| `0x0000_1000` | 4 KiB | reserved (boot ROM / reset vector, not implemented) |
| `0x1000_0000` | 4 KiB | UART: `+0` TXDATA (W), `+4` STATUS (R: bit0 TX ready, bit1 RX valid), `+8` RXDATA (R `{valid[8], data}`, W bit0=1 pops) |
| `0x1000_1000` | 4 KiB | GPIO: `+0` IN (R), `+8` OUT (RW) |
| `0x1000_2000` | 4 KiB | timer / run status: `+0` MTIME (cycles), `+8` INSTRET, `+0x10` EXIT (W: ends the run, exit code) |
| `0x8000_0000` | 64 KiB | instruction SRAM (reset vector; fetch only) |
| `0x8001_0000` | 64 KiB | data SRAM (.rodata .data .bss heap stack) |

The memories are Harvard: loads cannot read IMEM, so constant data is linked into DMEM and loaded
from `data.hex` together with `.data`.

## Building and running

```bash
make -C software                 # hello, tests (+ host golden), coremark
make -C sim build CONFIG=small   # 4-wide model (< 1 min); CONFIG=full: 8-wide default configuration (~20 min)
make -C sim run PROG=../software/hello
make -C sim test                 # all C tests
make -C sim check PROG=../software/tests/build/float_ops   # lockstep against the ISS (sim/rvsim.py)
make -C software/coremark ITERATIONS=10 && make -C sim coremark
make -C software/embench         # Embench-IoT: build/<bench>/{app.elf,code.hex,data.hex}
```
