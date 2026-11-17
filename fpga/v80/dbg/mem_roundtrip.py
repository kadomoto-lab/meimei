#!/usr/bin/env python3
"""Check whether the core can see DMEM, both via the host load port and via its own stores.

On the V80 bitstream of 2026-11-10 every load that is served by the DMEM RAM returned 0, whoever
wrote the word (Vivado tied off the write enables of `g_copy[0]`, the RAM
copy of load port 0; fixed in 64cef2a).  All three checks pass on the fixed bitstream.  The EXIT register is the read-out channel:

* `core`  -- the core stores the value, an MMIO load (MTIME) waits for the store buffer to drain,
             and the DMEM load's address depends on the MMIO result (`+ (mtime & 0)`), so the load
             cannot run early and be served by store-to-load forwarding from the SQ / store buffer;
* `2run`  -- run 1 stores the value (the EXIT MMIO store drains the store buffer), run 2 reloads
             only IMEM (no clear) and loads the word;
* `host`  -- the host writes the value over AXI, then the core loads it.

A store followed by a few nops and a load is NOT a RAM test: the store stays in the store buffer
(it drains at SB_THRESH = 9 lines or after 2^20 cycles) and the load is forwarded from it.

    $ ./fpga/v80/dbg/mem_roundtrip.py             # all checks, DMEM offset 0
    $ ./fpga/v80/dbg/mem_roundtrip.py --off 0x10  # a different word

Needs the QDMA queue set up as in `fpga/v80/README.md` ("V80 build", step 4).  None of the programs
contains a BJU uop that touches a register (the free-list bug fixed in 12f5d89).

Hand assembly trap: `lui a0, 0x80010` sign-extends bit 31, giving `0xFFFF_FFFF_8001_0000` — not
DMEM.  Addresses here are built as `lui 0x8001` (0x08001000, bit 19 clear) `slli 4` `addi off`.
"""

import argparse
import os
import pathlib
import sys
import tempfile
import time

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parent))

from load_coremark import Window, load_image  # noqa: E402

UART_TX_BASE = 0x1000_0000
EXIT_BASE = 0x1000_2000
CLEAR = 0x20000
CTRL = 0x20000
EXIT_STATUS = 0x20008
EXIT_CODE = 0x2000C
CTRL_CLEAR_EXIT, CTRL_CLEAR_TX = 0x2, 0x4


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((rd & 0x1F) << 7) | 0x13


def slli(rd, rs1, shamt):
    return ((shamt & 0x3F) << 20) | ((rs1 & 0x1F) << 15) | (1 << 12) | ((rd & 0x1F) << 7) | 0x13


def lw(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | (2 << 12) | ((rd & 0x1F) << 7) | 0x03


def sw(rs2, rs1, imm):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
        | (2 << 12) | ((imm & 0x1F) << 7) | 0x23


NOP = 0x00000013
JAL_X0 = 0x0000006F                                          # jal x0, 0 (park here)
A0, A1, A2, A3 = 10, 11, 12, 13


def dmem_addr(rd, byte_off):
    """rd = 0x8001_0000 + byte_off, three instructions (see the module docstring)."""
    assert 0 <= byte_off < 0x800
    return [lui(rd, 0x8001), slli(rd, rd, 4), addi(rd, rd, byte_off)]


def exit_store(reg):
    """li a1, EXIT_BASE ; sw reg, 0x10(a1)"""
    return [lui(A1, EXIT_BASE >> 12), sw(reg, A1, 0x10)]


def host_read_prog(byte_off):
    """li a0, DMEM+off ; lw a3,0(a0) ; li a1,EXIT ; sw a3,0x10(a1) ; park"""
    return dmem_addr(A0, byte_off) + [lw(A3, A0, 0)] + exit_store(A3) + [JAL_X0]


def andi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | (7 << 12) | ((rd & 0x1F) << 7) | 0x13


def add(rd, rs1, rs2):
    return ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) | ((rd & 0x1F) << 7) | 0x33


def li32(rd, value):
    hi = (value + 0x800) >> 12
    lo = value - (hi << 12)
    return [lui(rd, hi)] + ([addi(rd, rd, lo & 0xFFF)] if lo else [])


A4, A5 = 14, 15


def core_roundtrip_prog(byte_off, value):
    """sw value -> MMIO load of MTIME (drains the store buffer) -> lw at an address that depends on
    the MMIO result -> EXIT."""
    prog = dmem_addr(A0, byte_off) + li32(A3, value) + [sw(A3, A0, 0)]
    prog += [lui(A4, EXIT_BASE >> 12), lw(A5, A4, 0), andi(A5, A5, 0), add(A0, A0, A5), lw(A2, A0, 0)]
    return prog + exit_store(A2) + [JAL_X0]


def store_only_prog(byte_off, value):
    """sw value ; EXIT 0x77 (the EXIT MMIO store leaves the SQ only when the store buffer is empty)"""
    return dmem_addr(A0, byte_off) + li32(A3, value) + [sw(A3, A0, 0), addi(A2, 0, 0x77)] \
        + exit_store(A2) + [JAL_X0]


class Runner:
    def __init__(self, dev, base, tmp):
        self.win = Window(dev, base)
        self.tmp = tmp
        self.code = os.path.join(tmp, "code.hex")
        self.data = os.path.join(tmp, "data.hex")
        with open(self.data, "w", encoding="ascii") as fd:
            fd.write("0000000000000000\n")

    def run(self, words, dur=1.0):
        with open(self.code, "w", encoding="ascii") as fd:
            fd.write("\n".join("%08x" % (w & 0xFFFFFFFF) for w in words) + "\n")
        load_image(self.win, self.code, self.data, clear=True, quiet=True)
        return self.run_only(dur)

    def run_only(self, dur=1.0):
        self.win.w32(CTRL, 1)                                # CTRL.run
        t0 = time.time()
        while time.time() - t0 < dur:
            if self.win.r32(EXIT_STATUS) & 1:
                return self.win.r32(EXIT_CODE)
            time.sleep(0.0002)
        return None

    def run_imem_only(self, words, dur=1.0):
        """reload IMEM only (no clear: DMEM keeps what the previous run stored) and run"""
        for v in (0, CTRL_CLEAR_EXIT, CTRL_CLEAR_TX):
            self.win.w32(CTRL, v)
        for i, w in enumerate(list(words) + [0] * 32):
            self.win.w32(4 * i, w)
        return self.run_only()

    def close(self):
        self.win.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dev", default=os.environ.get("QDMA_DEV", "/dev/qdma01001-MM-0"))
    ap.add_argument("--base", default=os.environ.get("V80_BASE", "0x020100100000"))
    ap.add_argument("--off", default="0x0", help="DMEM byte offset (must be 4-byte aligned)")
    ap.add_argument("--value", default="0xCAFEBABE", help="32-bit value to load/store")
    args = ap.parse_args()

    byte_off = int(args.off, 0)
    value = int(args.value, 0) & 0xFFFFFFFF
    tmp = tempfile.mkdtemp(prefix="mem_roundtrip.")
    run = Runner(args.dev, int(args.base, 0), tmp)
    bad = 0
    try:
        # 1) the core's own store -> drain -> dependent load (served by the RAM)
        got = run.run(core_roundtrip_prog(byte_off, value))
        bad += _report("core   sw->drain->dep lw", byte_off, got, value)

        # 1b) run 1 stores, run 2 (IMEM reload only) loads
        v2 = value ^ 0xFFFF
        ex1 = run.run(store_only_prog(byte_off, v2))
        got = run.run_imem_only(host_read_prog(byte_off)) if ex1 == 0x77 else None
        bad += _report("2run   sw | reload | lw  ", byte_off, got, v2)

        # 2) the host writes over AXI, then the core loads the same word
        with open(run.code, "w", encoding="ascii") as fd:
            fd.write("\n".join("%08x" % (w & 0xFFFFFFFF) for w in host_read_prog(byte_off)) + "\n")
        load_image(run.win, run.code, run.data, clear=True, quiet=True)
        run.win.w32(0x10000 + byte_off, value)                   # DMEM segment, byte offset
        got = run.run_only()
        bad += _report("host   AXI -> core lw     ", byte_off, got, value)
    finally:
        run.close()
        for f in pathlib.Path(tmp).iterdir():
            f.unlink()
        os.rmdir(tmp)
    return 1 if bad else 0


def _report(what, off, got, want):
    ok = got == want
    print("%s dmem+0x%x = %s (want %s) %s" % (what, off, _h(got), _h(want), "ok" if ok else "MISMATCH"))
    return 0 if ok else 1


def _h(v):
    return "timeout" if v is None else "0x%08x" % v


if __name__ == "__main__":
    sys.exit(main())
