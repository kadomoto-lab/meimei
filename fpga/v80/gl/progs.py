#!/usr/bin/env python3
"""Write the free-list probe programs (fixed in 12f5d89; <name>.code.hex) and an empty data image into a directory.

Results on the 2026-11-10 netlist (gate level) / Verilator:
  tA   jal s0 ; EXIT <- s0                    exit 0x80000004 / same   (the link value is right)
  tB   jal s0 ; EXIT <- 0x55                  exit 0x55       / same
  tC   jal s0 ; 4 UART markers ; EXIT <- 0x66 BCDE, no EXIT  / exit 0x66   <-- fails
  tD   addi s0 ; EXIT <- 0x77                 exit 0x77       / same
  m1/m2/m4  1/2/4 markers ; EXIT              ok              / ok
  jx4  jal x0 ; 4 markers ; EXIT <- 0x50      ok              / ok
  jal_s0 / jalr_x0_x0 ...                     as fpga/v80/dbg/jalr_probe.py on the board
With the free-list fix (12f5d89) every program gives the Verilator result at gate level.
"""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dbg"))
from jalr_probe import CASES, FAR, jal, lui, addi, sw, mark  # noqa: E402

A1, A2, S0, NOP = 11, 12, 8, 0x13


def ex_reg(r):
    return [lui(A1, 0x10002), sw(r, A1, 16), jal(0, 0)]


def ex_c(c):
    return [addi(A2, 0, c)] + ex_reg(A2)


def marks(n):
    w = []
    for i in range(n):
        w += mark("BCDE"[i])
    return w


PROGS = {
    "tA": [jal(S0, 8), FAR] + ex_reg(S0),
    "tB": [jal(S0, 8), FAR] + ex_c(0x55),
    "tC": [jal(S0, 8), FAR] + marks(4) + ex_c(0x66),
    "tD": [addi(S0, 0, 5), NOP] + ex_c(0x77),
    "m1": marks(1) + ex_c(0x41),
    "m2": marks(2) + ex_c(0x42),
    "m4": marks(4) + ex_c(0x44),
    "jx4": [jal(0, 8), NOP] + marks(4) + ex_c(0x50),
}
for k, (w, _) in CASES.items():
    PROGS[k] = w

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)
for k, w in PROGS.items():
    with open(os.path.join(out, k + ".code.hex"), "w") as f:
        f.write("\n".join("%08x" % (x & 0xFFFFFFFF) for x in w + [NOP] * 8) + "\n")
with open(os.path.join(out, "zero.data.hex"), "w") as f:
    f.write("0000000000000000\n")
