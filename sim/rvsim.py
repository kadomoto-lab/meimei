#!/usr/bin/env python3
# Instruction-set simulator for the meimei SoC (RV64IMFDC_Zicsr, memory map of rtl/mm_soc.sv),
# built on the random-test ISS components (tb/fpmodel.py, tb/rvc.py, tb/gen.py).
#
#   rvsim.py <prog dir | code.hex data.hex> [--check rtl_trace.txt] [--max N]
#
# Without --check it runs the program and prints the UART output and the exit code.
# With --check it runs in lockstep with the commit trace of the RTL simulation (sim/tb_soc.sv
# +TRACE=...): every committed pc and register write is compared, and values that cannot be
# reproduced (cycle / time CSRs, the MTIME register) are taken from the RTL trace.
import sys, os, argparse
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'tb'))
import fpmodel as fm, rvc
from gen import sx, muldiv, fp_op, HALT

M, M32 = (1 << 64) - 1, 0xffffffff
IMEM, DMEM, SZ = 0x80000000, 0x80010000, 0x10000
UART, GPIO, TIMER = 0x10000000, 0x10001000, 0x10002000

def load_hex(path, width):
    out = bytearray()
    for l in open(path):
        l = l.strip()
        if l: out += int(l, 16).to_bytes(width, 'little')
    return out

class Sim:
    def __init__(self, code, data):
        self.imem = bytearray(SZ); self.imem[:len(code)] = code
        for a in range(len(code), SZ, 4): self.imem[a:a + 4] = (0x13).to_bytes(4, 'little')
        self.dmem = bytearray(SZ); self.dmem[:len(data)] = data
        self.x = [0] * 32; self.f = [0] * 32; self.pc = IMEM
        self.fflags = 0; self.frm = 0; self.n = 0; self.gpo = 0
        self.uart = bytearray(); self.exit = None; self.unknown = False

    # ---- data bus
    def load(self, a, size):
        if DMEM <= a and a + size <= DMEM + SZ: return int.from_bytes(self.dmem[a - DMEM:a - DMEM + size], 'little')
        dw, off = a & ~7, a & 7
        if dw == UART: v = 1 << 32                    # STATUS: TX ready, no RX data
        elif dw == GPIO + 8: v = self.gpo
        elif dw == TIMER: v = 0; self.unknown = True  # MTIME
        elif dw == TIMER + 8: v = self.n - 1          # INSTRET (instructions before this one)
        else: v = 0
        return (v >> (8 * off)) & ((1 << (8 * size)) - 1)

    def store(self, a, size, v):
        v &= (1 << (8 * size)) - 1
        if DMEM <= a and a + size <= DMEM + SZ: self.dmem[a - DMEM:a - DMEM + size] = v.to_bytes(size, 'little'); return
        dw, off = a & ~7, a & 7
        if dw == UART and off == 0: self.uart.append(v & 0xff)
        elif dw == GPIO + 8:
            m = ((1 << (8 * size)) - 1) << (8 * off)
            self.gpo = (self.gpo & ~m) | (v << (8 * off))
        elif dw == TIMER + 16: self.exit = sx(v, 32) if size >= 4 else v

    # ---- one instruction; returns (pc, written register name or None)
    def step(self):
        pc = self.pc; x, f = self.x, self.f
        off = pc - IMEM
        h = int.from_bytes(self.imem[off % SZ:off % SZ + 2], 'little')
        if h & 3 == 3: ins, ilen = int.from_bytes(self.imem[off % SZ:off % SZ + 4], 'little'), 4
        else: ins, ilen = rvc.expand(h), 2
        self.n += 1; self.unknown = False
        op = ins & 0x7f; rd = (ins >> 7) & 31; f3 = (ins >> 12) & 7; rs1 = (ins >> 15) & 31; rs2 = (ins >> 20) & 31
        a, b = x[rs1], x[rs2]; npc = (pc + ilen) & M; w = None; fw = None; fl = 0
        ii = sx(ins >> 20, 12) & M
        rm = self.frm if f3 == 7 else f3
        w32 = lambda v: sx(v, 32) & M
        if op in (0x33, 0x3b) and (ins >> 25) == 1: w = muldiv(f3, a, b, op == 0x3b)
        elif op in (0x13, 0x33):
            o2 = b if op == 0x33 else ii; sh = o2 & 63
            if f3 == 0: w = a - o2 if (op == 0x33 and (ins >> 30) & 1) else a + o2
            elif f3 == 1: w = a << sh
            elif f3 == 2: w = int(sx(a, 64) < sx(o2, 64))
            elif f3 == 3: w = int(a < o2)
            elif f3 == 4: w = a ^ o2
            elif f3 == 5: w = (sx(a, 64) >> sh) if (ins >> 30) & 1 else a >> sh
            elif f3 == 6: w = a | o2
            else: w = a & o2
        elif op in (0x1b, 0x3b):
            o2 = b if op == 0x3b else ii; sh = o2 & 31; a32 = a & M32
            if f3 == 0: w = w32(a32 - o2 if (op == 0x3b and (ins >> 30) & 1) else a32 + o2)
            elif f3 == 1: w = w32(a32 << sh)
            elif f3 == 5: w = w32(sx(a32, 32) >> sh) if (ins >> 30) & 1 else w32(a32 >> sh)
        elif op == 0x37: w = sx(ins & 0xfffff000, 32)
        elif op == 0x17: w = pc + sx(ins & 0xfffff000, 32)
        elif op == 0x6f:
            imm = sx(((ins >> 31) & 1) << 20 | ((ins >> 12) & 0xff) << 12 | ((ins >> 20) & 1) << 11 | ((ins >> 21) & 0x3ff) << 1, 21)
            w = pc + ilen; npc = (pc + imm) & M
        elif op == 0x67: w = pc + ilen; npc = (a + ii) & M & ~1
        elif op == 0x63:
            imm = sx(((ins >> 31) & 1) << 12 | ((ins >> 7) & 1) << 11 | ((ins >> 25) & 0x3f) << 5 | ((ins >> 8) & 0xf) << 1, 13)
            t = {0: a == b, 1: a != b, 4: sx(a, 64) < sx(b, 64), 5: sx(a, 64) >= sx(b, 64), 6: a < b, 7: a >= b}.get(f3, False)
            if t: npc = (pc + imm) & M
        elif op == 0x03:
            size = [1, 2, 4, 8, 1, 2, 4, 8][f3]
            v = self.load((a + ii) & M, size)
            w = sx(v, 8 * size) & M if f3 < 4 else v
        elif op == 0x23:
            self.store((a + sx((ins >> 25) << 5 | rd, 12)) & M, [1, 2, 4, 8, 8, 8, 8, 8][f3], b)
        elif op == 0x07:
            v = self.load((a + ii) & M, 4 if f3 == 2 else 8)
            fw = fm.box(v, 0) if f3 == 2 else v
        elif op == 0x27:
            size = 4 if f3 == 2 else 8
            self.store((a + sx((ins >> 25) << 5 | rd, 12)) & M, size, f[rs2])
        elif op in (0x43, 0x47, 0x4b, 0x4f):
            fmt = (ins >> 25) & 3; rs3 = ins >> 27
            fa, fb, fc = (fm.unbox(f[r], fmt) for r in (rs1, rs2, rs3))
            fw, fl = fm.fma(fa, fb, fc, fmt, rm, neg_prod=op in (0x4b, 0x4f), neg_c=op in (0x47, 0x4f))
            fw = fm.box(fw, fmt)
        elif op == 0x53: fw, w, fl = fp_op(ins, x, f, rm)
        elif op == 0x73 and f3 & 3:
            csr = ins >> 20; src = rs1 if f3 & 4 else a
            old = {0x001: self.fflags, 0x002: self.frm, 0x003: self.frm << 5 | self.fflags, 0xc02: self.n - 1}.get(csr, 0)
            if csr in (0xc00, 0xc01): self.unknown = True
            if (f3 & 3) == 1 or rs1 != 0:
                new = src if (f3 & 3) == 1 else (old | src if (f3 & 3) == 2 else old & ~src)
                if csr == 0x001: self.fflags = new & 0x1f
                elif csr == 0x002: self.frm = new & 7
                elif csr == 0x003: self.fflags = new & 0x1f; self.frm = (new >> 5) & 7
            w = old
        # FENCE / ECALL / EBREAK / unknown opcodes: no-op (the core has no traps)
        self.fflags |= fl
        self.pc = npc
        if w is not None and rd: x[rd] = w & M; return pc, ins, 'x%d' % rd
        if fw is not None: f[rd] = fw & M; return pc, ins, 'f%d' % rd
        return pc, ins, None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('prog', nargs='+')
    ap.add_argument('--check'); ap.add_argument('--max', type=int, default=50_000_000)
    ap.add_argument('--quiet', action='store_true')
    o = ap.parse_args()
    code_f, data_f = (os.path.join(o.prog[0], 'code.hex'), os.path.join(o.prog[0], 'data.hex')) if len(o.prog) == 1 else o.prog
    s = Sim(load_hex(code_f, 4), load_hex(data_f, 8))
    tr = open(o.check) if o.check else None
    for i in range(o.max):
        pc, ins, reg = s.step()
        if tr:
            line = tr.readline().split()
            if not line: print('RTL trace ended before the ISS at instruction %d (pc %x)' % (i, pc)); return 1
            rpc = int(line[0], 16); rreg = line[1] if len(line) > 1 else None
            if rpc != pc or rreg != reg:
                print('MISMATCH at instruction %d: ISS pc %x insn %08x writes %s, RTL pc %x writes %s' % (i, pc, ins, reg, rpc, rreg)); return 1
            if reg:
                rv = int(line[2], 16)
                cur = (s.x if reg[0] == 'x' else s.f)[int(reg[1:])]
                if s.unknown: (s.x if reg[0] == 'x' else s.f)[int(reg[1:])] = rv
                elif rv != cur:
                    print('MISMATCH at instruction %d: pc %x insn %08x %s ISS %016x RTL %016x' % (i, pc, ins, reg, cur, rv)); return 1
        if s.exit is not None: break
    else:
        print('no exit after %d instructions' % o.max); return 1
    if not o.quiet: sys.stdout.write(s.uart.decode('latin-1'))
    print('[rvsim] exit %d after %d instructions%s' % (s.exit, s.n, ' (lockstep with RTL trace: OK)' if tr else ''))
    return 0

if __name__ == '__main__':
    sys.exit(main())
