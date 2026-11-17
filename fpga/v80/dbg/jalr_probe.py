#!/usr/bin/env python3
"""Probe how the meimei core behaves on the V80 bitstream when a jump touches a register.

The expectations are the correct results (Verilator, and the V80 since 12f5d89).  Before that
fix the 2026-11-10 bitstream went wrong in every case that writes or reads an integer register
(`jal ra`/`jal s0`: "BA no exit", the `jalr` cases: "nothing"): Vivado had made every register
release overwrite the whole free list.  The cases stay as a quick check
that renaming works on a new bitstream.

    $ ./fpga/v80/dbg/jalr_probe.py                # full matrix
    $ ./fpga/v80/dbg/jalr_probe.py --only jal_s0  # a single case
    $ ./fpga/v80/dbg/jalr_probe.py --keep         # keep the generated *.hex

Requires the QDMA queue from `fpga/v80/README.md` ("V80 build", step 4: a `qdma01001-MM-0` node and
`sw/queue_mk.sh` run).  `clear` is always used: a shorter image must not inherit words from
the previous run, otherwise stale instruction words make the results look random.

Each case puts a marker byte on the UART and the `PROG` stub at word 12:

* `PROG` prints `A` and stores 0x123 to `TIMER+0x10` (EXIT), so `A` + `EXIT 0x123` means the
  program reached word 12 and exited cleanly;
* layout `A`: word 0 is the jump under test, word 1 is `jal x0,+400` (a marker `C` lives at
  word 101), word 2 is a marker `B`.  Output `B` = the jump went to word 2, `C` = the jump
  fell through, nothing = the core hung;
* layout `XY`: word 0..2 build t0 = word 5 and `jalr x0, 0(t0)`; word 4..6 is a marker `Y`
  (the jump lands on its `sb`, whose base t0 is no longer the UART), word 7..9 a marker `X`;
* layout `R` (`layout_reg`): word 0..2 build r = word 5 and `jalr x0, 0(r)`, word 3 jumps to
  a marker `C` at word 101 (fall-through), word 5..7 is a marker `B` (the target).
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

NOP = 0x00000013
FAR = 0x1900006F          # jal x0, +400 (word 1 -> word 101)
RET = 0x00008067          # jalr x0, 0(ra)

# the program at word 12: print 'A' and store 0x123 to EXIT (TIMER+0x10)
PROG = [0x10000637, 0x04100593, 0x00B60023, 0x10002537, 0x12300593, 0x00B52823, 0x0000006F]


def lui(rd, imm20):
    return ((imm20 & 0xFFFFF) << 12) | ((rd & 0x1F) << 7) | 0x37


def addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((rd & 0x1F) << 7) | 0x13


def jal(rd, off):
    """JAL's immediate is scattered over bits 31:12 (imm[20|10:1|11|19:12])."""
    off &= 0x1FFFFF
    return (((off >> 20) & 1) << 31) | (((off >> 1) & 0x3FF) << 21) \
        | (((off >> 11) & 1) << 20) | (((off >> 12) & 0xFF) << 12) \
        | ((rd & 0x1F) << 7) | 0x6F


def jalr(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | ((rs1 & 0x1F) << 15) | ((rd & 0x1F) << 7) | 0x67


def _s(rs2, rs1, imm, funct3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | ((rs2 & 0x1F) << 20) | ((rs1 & 0x1F) << 15) \
        | (funct3 << 12) | ((imm & 0x1F) << 7) | 0x23


def sb(rs2, rs1, imm):
    return _s(rs2, rs1, imm, 0)


def sw(rs2, rs1, imm):
    return _s(rs2, rs1, imm, 2)


def mark(ch):
    """`li t0,0x10000000 ; li t1,ch ; sb t1,0(t0)` -- three words, writes one byte."""
    return [lui(5, 0x10000), addi(6, 0, ord(ch)), sb(6, 5, 0)]


def blank(n=200):
    return [NOP] * n


def layout_a(jump):
    """word0 = jump, word1 = far jump with marker C at 101, word2 = marker B."""
    w = blank()
    w[0] = jump
    w[1] = FAR
    w[2:5] = mark("B")
    w[12:19] = PROG
    w[101:104] = mark("C")
    return w


# name -> (words, expected result)
# `nothing` = the core hung, `no exit` = it ran but the EXIT store never landed
CASES = {
    "jal_x0": (layout_a(jal(0, 8)), "BA exit"),
    "jal_ra": (layout_a(jal(1, 8)), "BA exit"),
    "jalr_x0_x0": (layout_a(jalr(0, 0, 8)), "BA exit"),
    "jalr_ra_x0": (layout_a(jalr(1, 0, 8)), "BA exit"),
    "jalr_t0_x0": (layout_a(jalr(5, 0, 8)), "BA exit"),
}
# rs1 != 0 needs the base in a register first; the jump itself is the XY case with t0 = word 5
_rs1 = blank()
_rs1[0:3] = (lui(5, 0x80000), addi(5, 5, 20), jalr(0, 5, 0))
_rs1[4:7] = mark("Y")
_rs1[7:10] = mark("X")
_rs1[12:19] = PROG
CASES["jalr_x0_t0"] = (_rs1, "XA exit")


def layout_reg(r):
    """r = word 5 address; jalr x0, 0(r). B = jumped to the target, C = fell through."""
    w = blank()
    w[0:3] = (lui(r, 0x80000), addi(r, r, 20), jalr(0, r, 0))
    w[3] = jal(0, 4 * (101 - 3))
    w[5:8] = mark("B")
    w[12:19] = PROG
    w[101:104] = mark("C")
    return w


# non-link registers (s0 = x8, t1 = x6): no RAS push/pop (they failed the same way before 12f5d89)
CASES["jal_s0"] = (layout_a(jal(8, 8)), "BA exit")
CASES["jalr_s0_x0"] = (layout_a(jalr(8, 0, 8)), "BA exit")
CASES["jalr_x0_t1"] = (layout_reg(6), "BA exit")
CASES["jalr_x0_s0"] = (layout_reg(8), "BA exit")
CASES["jalr_x0_ra"] = (layout_reg(1), "BA exit")

assert jal(0, 8) == 0x0080006F and jal(0, 400) == FAR  # encoder sanity


def write_hex(path, words):
    with open(path, "w", encoding="ascii") as fd:
        fd.write("\n".join("%08x" % (x & 0xFFFFFFFF) for x in words) + "\n")


def describe(uart, code):
    if uart and code is not None:
        return uart + " exit"
    if uart:
        return uart + " no exit"
    return "exit only" if code is not None else "nothing"


def run_case(win, name, words, tmp, dur):
    code = os.path.join(tmp, name + ".code.hex")
    data = os.path.join(tmp, "data.hex")
    write_hex(code, words)
    write_hex(data, [0])
    load_image(win, code, data, clear=True, quiet=True)
    win.w32(0x20000, 0x1)                       # CTRL.run
    t0 = time.time()
    out, code_exit = [], None
    while time.time() - t0 < dur:
        while win.r32(0x21004) & 1:
            out.append(chr(win.r32(0x21000) & 0xFF))
        if win.r32(0x20008) & 1:
            code_exit = win.r32(0x2000C)
            break
        time.sleep(0.0002)
    return "".join(out), code_exit


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dev", default=os.environ.get("QDMA_DEV", "/dev/qdma01001-MM-0"))
    ap.add_argument("--base", default=os.environ.get("V80_BASE", "0x020100100000"))
    ap.add_argument("--dur", type=float, default=1.5, help="seconds to drain per case")
    ap.add_argument("--only", help="run a single case name")
    ap.add_argument("--keep", action="store_true", help="keep the generated hex files")
    args = ap.parse_args()

    tmp = tempfile.mkdtemp(prefix="jalr_probe.")
    win = Window(args.dev, int(args.base, 0))
    names = [args.only] if args.only else list(CASES)
    bad = 0
    print("%-12s %-14s %s" % ("case", "measured", "expected"))
    try:
        for name in names:
            words, expect = CASES[name]
            uart, code = run_case(win, name, words, tmp, args.dur)
            got = describe(uart, code)
            ok = got.strip() == expect.strip()
            bad += 0 if ok else 1
            print("%-12s %-14s %-14s %s" % (name, got.strip() or "-", expect,
                                            "ok" if ok else "MISMATCH"))
    finally:
        win.close()
        if not args.keep:
            for f in pathlib.Path(tmp).iterdir():
                f.unlink()
            os.rmdir(tmp)
        else:
            print("kept", tmp)
    print("%d/%d cases correct" % (len(names) - bad, len(names)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
