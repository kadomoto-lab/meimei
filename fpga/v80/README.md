# meimei on the Alveo V80

`mm_v80_top` wraps `mm_soc` in an AXI4-Lite slave so a PCIe host can load an image into IMEM/DMEM,
start the core, drain its console and read the exit code: the host loads the image over AXI and
the UART is a FIFO read over the same port.

| file | role |
|---|---|
| `mm_v80_top.sv` | the V80 top: `mm_soc` + the host register block, `cpu_clk`/`s_axi_aclk` |
| `mm_host_axi.sv` | AXI4-Lite slave + the host register map (IMEM/DMEM/CTRL/STATUS/UART) |
| `mm_uart_host_tx.sv` | 4 KiB TX FIFO between the core's UART and the host reads |
| `mm_v80_top_bd.v` | plain-Verilog shell with the `X_INTERFACE_*` attributes for the BD cell |
| `load_coremark.py` | host loader / console dumper (QDMA character device) |
| `sim/` | Verilator testbench (`tb_v80.sv`) + a freestanding self-test program |

RTL changes on the meimei side are limited to two files: `rtl/mm_soc.sv` gains the `host_imem_*` /
`host_dmem_*` ports (plus `mtime_o`), and `rtl/mm_mem.sv`'s `mm_dmem` gains a host write port.

## Host register map

The slave decodes the low 20 bits of the AXI address, so it can be mapped anywhere on a 1 MiB
boundary. The design places it at `0x0201_0010_0000` (256 KiB) inside the NoC M00 aperture.

| offset | access | contents |
|---|---|---|
| `0x00000`–`0x0FFFF` | W | IMEM, 64 KiB: little-endian 32-bit words, word i at `4*i`. All four byte strobes are required, otherwise the write gets `SLVERR` |
| `0x10000`–`0x1FFFF` | W | DMEM, 64 KiB: 64-bit words as two 32-bit halves — `8*i+0` = low, `8*i+4` = high; byte strobes are honoured |
| `0x20000` | RW | CTRL: W bit0 `run` (level; 0 holds the core in reset), bit1 clear the EXIT latch, bit2 flush the TX FIFO; R bit0 = `run` |
| `0x20004` | R | STATUS: bit0 `run`, bit1 EXIT latched |
| `0x20008` | R | EXIT_STATUS: bit0 = the program has stored to `TIMER+0x10` |
| `0x2000c` | R | EXIT_CODE: that stored value (0 = pass) |
| `0x20010` | R | MTIME_LO: `cpu_clk` cycles since `CTRL.run` went to 1 |
| `0x20014` | R | MTIME_HI |
| `0x21000` | R | UART_TX_DATA: head byte of the TX FIFO; reading pops it |
| `0x21004` | R | UART_TX_STATUS: bit0 data valid, bit1 full |
| `0x21008` | W | UART_RX_DATA: push a byte into the core's UART RX FIFO |
| `0x2100c` | R | UART_RX_STATUS: always 0 (the RX path is push-only) |

IMEM/DMEM are write-only: reads there return 0. Unmapped writes are answered with `SLVERR`. One
outstanding read and one outstanding write are accepted — AXI4-Lite allows no more, and the host
must not start a second read before the first `rvalid` handshake.

`mm_soc`'s reset is `cpu_rst_n & ctrl_run`, so every run starts at the reset vector with MTIME = 0
and the host must keep `run = 0` while it loads. `cpu_clk` has to be the same clock as
`s_axi_aclk` (the EXIT pulse is latched in the `s_axi_aclk` domain) — the V80 build wires both to
`cips/pl0_ref_clk`, 100 MHz.

## Simulation

```
cd fpga/v80/sim
make build     # Verilator model in obj_small/ (MM_SMALL is on by default)
make run       # builds prog/{code,data}.hex, loads, runs, diffs uart.txt against prog/expected.txt
```

`make run` should print

```
v80 self-test: axi load / run / uart
acc=79d0be5ae1616157
scratch=00000000123477ef
PASS
[tb] exit code 0 after 5549 cycles (mtime=5184 cycles)
```

and `diff -u prog/expected.txt uart.txt` comes back empty. `+MAXCYC=<cycles>` bounds the run
(`MAXCYC`, default 2000000, is passed through), `+UART=<file>` names the console capture.

The toolchain the model is built with matters: verilator 5.044 needs a C++20 compiler with
coroutine support and a libstdc++ that links against this system's glibc. The `Makefile` probes
`CXX_PROBE` for a compiler that accepts `-fcoroutines` (the system `c++` is gcc 8 and does not),
and overrides `CXX`/`LINK`, `LDFLAGS=-static-libstdc++ -static-libgcc` and
`LDLIBS='-pthread -lpthread /usr/lib64/libatomic.so.1'` because `verilated.mk` hardcodes
`CXX=c++` and the brew libstdc++ wants a newer glibc. The variables are named `SIM_CXX` /
`CXX_PROBE` because GNU make's built-in `CXX=g++` defeats `?=`; override the choice with
`make SIM_CXX=/opt/rh/gcc-toolset-13/root/usr/bin/g++ build`. Expect ~3.5 min for a rebuild and
~2 s for the test itself (about 2.4k cycles/s — see `CLAUDE.md`).

The self-test program is freestanding (`-nostdlib`, `-ffreestanding`): the Vitis newlib images
cannot be linked at `0x8000_0000`, so it only uses the SoC header. `prog/Makefile` links it with
`software/software_tools/link.ld` and converts `app.elf` with `software/software_tools/elf2hex.py`,
which produces the 32-bit `code.hex` and 64-bit `data.hex` images.
`make -C prog clean && make -C prog ITERS=100000 EXPECT=0xb0854925df02f88f` builds the longer run (the Makefile appends `ull`; `clean` is needed because the Makefile does not track flag changes).

## V80 build

`MEIMEI_DIR` selects the meimei checkout; point it at this repository.

The base design needs the `smbus` IP in `v80/hw/redad_v80/src/iprepo/smbus_v1_1-20240328`
(copied from `~/smbus_v1_1-20240328`); without it `create_design.tcl` cannot build the
`axi_smbus_rpu` cell.

1. `src/create_design.tcl` adds `rtl/*.sv`, `fpga/v80/*.sv` and `fpga/v80/*.v` to `sources_1` and
   sets `verilog_define = MM_SMALL`. Do **not** define `MM_IMEM_INIT` / `MM_DMEM_INIT`: the host
   loads the image.
2. After `create_root_design`, `src/bd/meimei_bd.tcl::add_meimei_to_bd` inserts `meimei_sc`
   (smartconnect, 1 SI / 2 MI) between `axi_noc_cips/M00_AXI` and
   `base_logic/s_axi_pcie_mgmt_slr0`, adds `meimei_top` (module reference to `mm_v80_top_bd`),
   wires `cips/pl0_ref_clk` / `clock_reset/resetn_pl_ic` / `clock_reset/resetn_pl_periph` and
   assigns `0x0201_0010_0000` + 256 KiB to both `CPM_PCIE_NOC_0` and `CPM_PCIE_NOC_1`.

   Keeping this out of `bd/create_bd_design.tcl` means `scripts/export_bd.sh` can regenerate that
   file from the GUI without losing the hookup.
3. `cd v80/hw/redad_v80 && vivado -source src/create_design.tcl -source src/build_design.tcl -mode batch`
   builds the design (~80 min here) and writes `build/redad_v80.xsa`,
   `build/prj.runs/impl_1/top_wrapper.pdi` and `build/bd_gen/create_bd_design_final.tcl`.
   `v80/build_all.sh` wraps the same flow and then builds the AMC FW and the PDI. On this host the
   full run fails in the FW step (the XSA written before synthesis has no hardware handoff,
   `CRITICAL WARNING: [Project 1-1924]`); `./build_all.sh --skip-hw` then rewrites the XSA from the
   implemented project and makes `redad_v80.pdi` in a few minutes:

   ```
   MEIMEI_DIR=~/Programs/meimei ./build_all.sh || ./build_all.sh --skip-hw
   ```

   Copy each image you want to keep out of `build/` (the next build recreates it): the images that
   ran on the board are kept under `v80/hw/redad_v80/images/<date>_<config>_<MHz>_<commit>/` with a
   `MANIFEST.md`.
4. Write the PDI (~13 min + hot reset) and bring the QDMA queue back — after the hot reset the old
   queue answers with `EIO` and `queue_mk.sh` alone fails with `start failed -22`:

   ```
   sudo ami_tool cfgmem_program -d 01:00.0 -t primary -i redad_v80.pdi -p 0 -y
   sudo sh -c 'echo 1 > /sys/bus/pci/devices/0000:01:00.1/remove; echo 1 > /sys/bus/pci/rescan'
   sudo sh -c 'echo 4 > /sys/bus/pci/devices/0000:01:00.1/qdma/qmax'
   sudo bash -c 'export PATH=/usr/local/sbin:$PATH; cd sw && ./queue_mk.sh -p 0000:01:00.1'
   ./fpga/v80/dbg/jalr_probe.py && ./fpga/v80/dbg/mem_roundtrip.py      # quick sanity checks
   ./fpga/v80/load_coremark.py software/coremark/code.hex software/coremark/data.hex \
       --uart uart.txt
   ```

   The loader holds the core in reset, zeroes IMEM/DMEM, streams both images, sets `CTRL.run` and
   polls the TX FIFO until EXIT latches; it exits with the program's exit code.

## Synthesis results (`MM_SMALL`, 100 MHz)

`synth_design -top mm_v80_top` on its own (host block included) gives

| | used | available |
|---|---|---|
| CLB LUTs | 429,994 (16.7 %) | 2,574,208 |
| Registers | 133,759 (2.6 %) | 5,148,416 |
| Block RAM / URAM | 0 / 4 | 3,741 / 1,925 |
| DSP | 0 | 10,848 |

and the full design (shell + NoC + meimei) of the image that runs on the board (commits `64cef2a` +
`12f5d89`, 2026-11-11) routes at 100 MHz with WNS +0.133 ns / WHS +0.010 ns, no failing endpoints,
458,651 CLB LUTs (17.8 %), 177,976 registers and 78.5 Block RAM tiles. On the board it runs CoreMark
at 7.882 CoreMark/MHz (10000 iterations, 12.7 s, CRC valid). The worst setup path of the first build
was inside the core, `u_core/can_v_reg[2]` → `u_core/g_iq[6].iq/jd_reg[6][2]`, so the
margin is thin — the 8-wide build (which closes ~68 MHz on the Nexys Video) would need a slower
`cpu_clk` (see the `axi_clock_converter` note below).

## Known limitations

* *(fixed in `12f5d89`, confirmed on the board 2026-11-11)* On the 2026-11-10 bitstream no C program
  ran: every register released at commit overwrote the whole integer free list, because Vivado 2024.1
  made the per-entry write condition `pidx(padd(tail, n)) == e` true for every entry. It first looked
  like "`jalr` / a BJU uop touching a register hangs the core" (`dbg/jalr_probe.py`). `mm_freelist`
  now computes the position inline. With both fixes, `hello`, the SoC C tests and CoreMark
  (7.882 CoreMark/MHz, 10000 iterations, CRC valid) run on the V80.
* The host write port has priority over the CPU store port in `mm_dmem`, so a load must not race a
  running core. `CTRL.run = 0` is required while loading (the loader does this).
* *(fixed in `64cef2a`, confirmed on the board 2026-11-11)* On the 2026-11-10 bitstream every load
  served by the DMEM RAM returned 0 — host-written and core-written words alike — because Vivado
  2024.1 tied the write enables of `g_copy[0]` (the RAM copy read by load port 0) to GND. `mm_dmem`
  now folds the write enable into a per-byte enable vector. A store followed by a few nops and a
  load is not a RAM test (the store buffer forwards it); use `fpga/v80/dbg/mem_roundtrip.py`.
  `make run` alone would not catch a regression (`prog/selftest.c` never reads static data before
  overwriting it).
* The same-cycle store→load bypass in `mm_dmem` (`byp_m`) covers CPU stores only; a host write to a
  word that the core is reading at that instant is not forwarded.
* IMEM/DMEM cannot be read back over AXI, so load errors are not detectable from the host. `clear`
  (zeroing both memories before loading) is therefore not optional: a shorter image that inherits
  stale words from the previous run looks like a random failure.
* `CTRL.run` resets the SoC but not the `mm_host_axi`/QDMA side, and a wedged core cannot be observed
  from the host (the AXI registers stay responsive, MTIME keeps counting, no error is reported). If
  the results start looking stale, reset `CTRL.run` to 0 and reload with `clear`; after a
  `qdma_request_wait_for_cmpl` timeout in dmesg only a PDI reload is known to be safe.
* The `smartconnect` in front of meimei runs in low-area mode (the NoC M00 port advertises
  `HAS_BURST == 1`), so WRAP bursts get a DECERR. The loader issues plain single-beat accesses, so
  it is unaffected.
* The `dbg/jalr_probe.py` and `dbg/mem_roundtrip.py` checks need a hand-built
  program loaded through the same AXI window; hand assembly is easy to get wrong (`lui a0, 0x80010`
  sign-extends to `0xFFFF_FFFF_8001_0000`, which is not DMEM and reads as 0 — build it as
  `lui 0x8001; slli 4; addi`).
* If `cpu_clk` ever has to be slower than `s_axi_aclk` (8-wide, or a worse placement), add a
  50 MHz output to `usr_clk_wiz` and an `axi_clock_converter` —
  but then the EXIT latch in `mm_v80_top` needs an asynchronous handshake instead of the plain
  level latch it uses now.
