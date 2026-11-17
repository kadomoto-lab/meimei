#!/usr/bin/env python3
"""Load a meimei image into the V80 (mm_v80_top) and dump its UART output.

The host reaches mm_v80_top through the QDMA character device: the design maps a
256 KiB AXI-Lite window at 0x0201_0010_0000 (register map: fpga/v80/README.md).  Writing or
reading a byte offset in that window turns into an AXI4-Lite transaction, so a
plain seek()+write() on the device node behaves like mmio.

Usage:
    ./load_coremark.py code.hex data.hex
    ./load_coremark.py --dev /dev/qdma01001-MM-0 --base 0x020100100000 ...

Notes:
  * code.hex is one 32-bit word per line (IMEM, 4-byte spacing).
  * data.hex is one 64-bit word per line (DMEM, 8-byte spacing).
  * Both files are written in the byte order the RTL expects (little endian).
  * The CPU is held in reset until every word is in place (CTRL.RUN = 0), which
    is mandatory: the host load port has priority over the CPU store port.
"""

import argparse
import mmap
import os
import struct
import sys
import time

DEF_DEV = "/dev/qdma01001-MM-0"
DEF_BASE = 0x0201_0010_0000

# register offsets inside the 256 KiB window (fpga/v80/README.md, "Host register map")
REG_CTRL = 0x20000
REG_STATUS = 0x20004
REG_EXIT_STATUS = 0x20008
REG_EXIT_CODE = 0x2000C
REG_MTIME_LO = 0x20010
REG_MTIME_HI = 0x20014
REG_UART_TX_DATA = 0x21000
REG_UART_TX_STATUS = 0x21004
REG_UART_RX_DATA = 0x21008
REG_UART_RX_STATUS = 0x2100C

CTRL_RUN = 1 << 0
CTRL_CLEAR_EXIT = 1 << 1
CTRL_CLEAR_TX = 1 << 2

IMEM_OFF = 0x00000
DMEM_OFF = 0x10000
WINDOW = 0x40000  # 256 KiB


class Window:
    """Byte-offset accessor for the mm_v80_top AXI-Lite window."""

    def __init__(self, dev, base, size=WINDOW):
        self.size = size
        self.f = open(dev, "r+b", buffering=0)
        try:
            self.mm = mmap.mmap(self.f.fileno(), size, access=mmap.ACCESS_WRITE)
        except (OSError, ValueError):
            self.mm = None  # fall back to seek()/write()
        self.base = base

    def _seek(self, off):
        self.f.seek(self.base + off)

    def w32(self, off, val):
        buf = struct.pack("<I", val & 0xFFFFFFFF)
        if self.mm is not None:
            self.mm[off:off + 4] = buf
        else:
            self._seek(off)
            self.f.write(buf)

    def r32(self, off):
        if self.mm is not None:
            return struct.unpack("<I", self.mm[off:off + 4])[0]
        self._seek(off)
        return struct.unpack("<I", self.f.read(4))[0]

    def zero(self, off, length):
        chunk = bytes(length)
        if self.mm is not None:
            self.mm[off:off + length] = chunk
        else:
            self._seek(off)
            self.f.write(chunk)

    def close(self):
        if self.mm is not None:
            self.mm.flush()
            self.mm.close()
        self.f.close()


def read_hex(path, bits):
    """Read elf2hex output: one word per line, word width = bits."""
    words = []
    with open(path, "r", encoding="ascii") as fd:
        for n, line in enumerate(fd, 1):
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            try:
                val = int(line, 16)
            except ValueError:
                sys.exit(f"{path}:{n}: not a hex word: {line!r}")
            if val < 0 or val >= (1 << bits):
                sys.exit(f"{path}:{n}: 0x{val:x} does not fit in {bits} bits")
            words.append(val)
    return words


def load_image(win, code_hex, data_hex, clear=True, quiet=False):
    win.w32(REG_CTRL, 0)                       # hold the CPU in reset
    win.w32(REG_CTRL, CTRL_CLEAR_EXIT)
    win.w32(REG_CTRL, CTRL_CLEAR_TX)

    code = read_hex(code_hex, 32)
    data = read_hex(data_hex, 64)

    if clear:
        # a shorter image must not inherit stale words from the previous run
        win.zero(IMEM_OFF, 0x10000)
        win.zero(DMEM_OFF, 0x10000)

    for i, word in enumerate(code):
        win.w32(IMEM_OFF + 4 * i, word)
    for i, word in enumerate(data):
        off = DMEM_OFF + 8 * i
        win.w32(off, word & 0xFFFFFFFF)         # low half of the 64-bit word
        win.w32(off + 4, word >> 32)            # high half

    if not quiet:
        print(f"[host] imem {len(code)} words, dmem {len(data)} words loaded")


def run_and_spool(win, tx_path, poll_s=0.0001, verbose=False):
    win.w32(REG_CTRL, CTRL_RUN)                 # release the CPU
    started = time.time()
    tx = open(tx_path, "w", encoding="ascii") if tx_path else None
    chars = 0
    exit_code = None
    def drain():
        n = 0
        while win.r32(REG_UART_TX_STATUS) & 1:
            ch = win.r32(REG_UART_TX_DATA) & 0xFF
            sys.stdout.write(chr(ch))
            sys.stdout.flush()
            if tx:
                tx.write(chr(ch))
                tx.flush()
            n += 1
        return n

    try:
        while True:
            chars += drain()
            if win.r32(REG_EXIT_STATUS) & 1:
                exit_code = win.r32(REG_EXIT_CODE)
                # A short program can print and exit between the drain above and the EXIT read
                # (each QDMA register access takes tens of microseconds); the EXIT store is
                # ordered after the UART stores, so everything it printed is in the FIFO now.
                chars += drain()
                break
            time.sleep(poll_s)
    except KeyboardInterrupt:
        print("\n[host] interrupted")
    finally:
        if tx:
            tx.close()

    elapsed = time.time() - started
    mtime = win.r32(REG_MTIME_LO)
    print(f"\n[host] exit={exit_code} mtime={mtime} ns ({elapsed:.3f} s wall, {chars} chars)")
    return exit_code


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("code_hex", help="IMEM image (32-bit words, one per line)")
    ap.add_argument("data_hex", help="DMEM image (64-bit words, one per line)")
    ap.add_argument("--dev", default=os.environ.get("QDMA_DEV", DEF_DEV),
                    help=f"QDMA character device (default {DEF_DEV})")
    ap.add_argument("--base", default=os.environ.get("V80_BASE", hex(DEF_BASE)),
                    help="AXI window base address")
    ap.add_argument("--uart", default=None, help="also write the console to this file")
    ap.add_argument("--no-clear", action="store_true",
                    help="do not zero IMEM/DMEM before loading")
    args = ap.parse_args()

    base = int(args.base, 0) if isinstance(args.base, str) else args.base
    win = Window(args.dev, base)
    try:
        load_image(win, args.code_hex, args.data_hex, clear=not args.no_clear)
        code = run_and_spool(win, args.uart)
    finally:
        win.close()
    sys.exit(0 if code == 0 else 1)


if __name__ == "__main__":
    main()
