# RV64IMFDC_Zicsr random program generator + reference ISS (FP arithmetic: fpmodel.py, bit-exact)
import random, sys
import fpmodel as fm
M32, M = 0xffffffff, (1 << 64) - 1
def sx(v, b): v &= (1 << b) - 1; return v - (1 << b) if v >> (b - 1) else v
def R(f7, rs2, rs1, f3, rd, op): return (f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op) & M32
def I(imm, rs1, f3, rd, op): return ((imm & 0xfff) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op) & M32
def S(imm, rs2, rs1, f3): imm &= 0xfff; return ((imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 31) << 7 | 0x23) & M32
def B(imm, rs2, rs1, f3):
    imm &= 0x1fff
    return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3f) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | ((imm >> 1) & 0xf) << 8 | ((imm >> 11) & 1) << 7 | 0x63) & M32
def U(imm, rd, op): return ((imm & 0xfffff) << 12 | rd << 7 | op) & M32
def J(imm, rd):
    imm &= 0x1fffff
    return (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3ff) << 21 | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xff) << 12 | rd << 7 | 0x6f) & M32
HALT = J(0, 0)
import rvc

def iss(prog, steps=100000, dmem_init=None, partial=False):
    """prog: list of 32-bit words or bytes (may contain RVC). Returns (x, mem words, n, trace, f);
       trace entries (name, value), value None = not checkable (cycle / time CSR reads).
       Final fflags / frm in iss.fflags / iss.frm, last pc in iss.last_pc."""
    if not isinstance(prog, (bytes, bytearray)): prog = b''.join(w.to_bytes(4, 'little') for w in prog)
    imem = bytes(prog) + b'\x13\x00\x00\x00' * 512
    x = [0] * 32; f = [0] * 32; mem = bytearray(2048); pc = 0; n = 0; trace = []
    fflags = 0; frm = 0
    if dmem_init:
        for i, v in enumerate(dmem_init): mem[8 * i:8 * i + 8] = v.to_bytes(8, 'little')
    w32 = lambda v: sx(v, 32) & M
    for _ in range(steps):
        h = int.from_bytes(imem[pc:pc + 2], 'little')
        if h & 3 == 3: ins, ilen = int.from_bytes(imem[pc:pc + 4], 'little'), 4
        else: ins, ilen = rvc.expand(h), 2
        n += 1
        if ins == HALT: break
        op = ins & 0x7f; rd = (ins >> 7) & 31; f3 = (ins >> 12) & 7; rs1 = (ins >> 15) & 31; rs2 = (ins >> 20) & 31
        a, b = x[rs1], x[rs2]; npc = (pc + ilen) & M; w = None; fw = None; fl = 0; unknown = False
        ii = sx(ins >> 20, 12) & M
        rm = frm if f3 == 7 else f3
        if op in (0x33, 0x3b) and (ins >> 25) == 1:
            w = muldiv(f3, a, b, op == 0x3b)
        elif op in (0x13, 0x33):
            o2 = b if op == 0x33 else ii
            sh = o2 & 63
            if f3 == 0: w = a - o2 if (op == 0x33 and (ins >> 30) & 1) else a + o2
            elif f3 == 1: w = a << sh
            elif f3 == 2: w = int(sx(a, 64) < sx(o2, 64))
            elif f3 == 3: w = int(a < o2)
            elif f3 == 4: w = a ^ o2
            elif f3 == 5: w = (sx(a, 64) >> sh) if (ins >> 30) & 1 else a >> sh
            elif f3 == 6: w = a | o2
            else: w = a & o2
        elif op in (0x1b, 0x3b):
            o2 = b if op == 0x3b else ii
            sh = o2 & 31; a32 = a & M32
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
            t = {0: a == b, 1: a != b, 4: sx(a, 64) < sx(b, 64), 5: sx(a, 64) >= sx(b, 64), 6: a < b, 7: a >= b}[f3]
            if t: npc = (pc + imm) & M
        elif op == 0x03:
            ad = (a + ii) & 2047
            size = [1, 2, 4, 8, 1, 2, 4][f3]
            v = int.from_bytes(mem[ad:ad + size], 'little')
            w = sx(v, 8 * size) if f3 < 4 else v
        elif op == 0x23:
            ad = (a + sx((ins >> 25) << 5 | ((ins >> 7) & 31), 12)) & 2047
            size = [1, 2, 4, 8][f3]
            mem[ad:ad + size] = (b & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        elif op == 0x07:                    # FLW / FLD
            ad = (a + ii) & 2047
            v = int.from_bytes(mem[ad:ad + (4 if f3 == 2 else 8)], 'little')
            fw = fm.box(v, 0) if f3 == 2 else v
        elif op == 0x27:                    # FSW / FSD
            ad = (a + sx((ins >> 25) << 5 | ((ins >> 7) & 31), 12)) & 2047
            size = 4 if f3 == 2 else 8
            mem[ad:ad + size] = (f[rs2] & ((1 << (8 * size)) - 1)).to_bytes(size, 'little')
        elif op in (0x43, 0x47, 0x4b, 0x4f):
            fmt = (ins >> 25) & 3; rs3 = ins >> 27
            fa, fb, fc = (fm.unbox(f[r], fmt) for r in (rs1, rs2, rs3))
            fw, fl = fm.fma(fa, fb, fc, fmt, rm, neg_prod=op in (0x4b, 0x4f), neg_c=op in (0x47, 0x4f))
            fw = fm.box(fw, fmt)
        elif op == 0x53:
            fw, w, fl = fp_op(ins, x, f, rm)
        elif op == 0x73 and f3 & 3:         # Zicsr
            csr = ins >> 20
            src = rs1 if f3 & 4 else a
            if csr == 0x001: old = fflags
            elif csr == 0x002: old = frm
            elif csr == 0x003: old = frm << 5 | fflags
            elif csr in (0xc00, 0xc01): old = 0; unknown = True     # cycle / time
            elif csr == 0xc02: old = n - 1                          # instret: instructions before this one
            else: old = 0
            if (f3 & 3) == 1 or rs1 != 0:
                new = src if (f3 & 3) == 1 else (old | src if (f3 & 3) == 2 else old & ~src)
                if csr == 0x001: fflags = new & 0x1f
                elif csr == 0x002: frm = new & 7
                elif csr == 0x003: fflags = new & 0x1f; frm = (new >> 5) & 7
            w = old
        elif op == 0x0f or op == 0x73: pass   # FENCE / ECALL / EBREAK: no-op (no traps)
        else: raise Exception(hex(ins))
        fflags |= fl
        if w is not None and rd:
            x[rd] = w & M; trace.append(('x%d' % rd, None if unknown else x[rd]))
        if fw is not None: f[rd] = fw & M; trace.append(('f%d' % rd, f[rd]))
        pc = npc
    else:
        if not partial: raise Exception('no halt')
    iss.last_pc = pc; iss.fflags = fflags; iss.frm = frm
    words = [int.from_bytes(mem[8 * i:8 * i + 8], 'little') for i in range(256)]
    return x, words, n, trace, f

def muldiv(f3, a, b, word):
    sa, sb = (sx(a, 32), sx(b, 32)) if word else (sx(a, 64), sx(b, 64))
    ua, ub = (a & M32, b & M32) if word else (a, b)
    bits = 32 if word else 64
    if f3 == 0: r = sa * sb
    elif f3 == 1: r = (sa * sb) >> 64
    elif f3 == 2: r = (sa * b) >> 64
    elif f3 == 3: r = (a * b) >> 64
    elif f3 == 4:   # DIV: round toward zero; /0 -> -1; overflow -> dividend
        r = -1 if sb == 0 else (sa if (sa == -(1 << (bits - 1)) and sb == -1) else abs(sa) // abs(sb) * (1 if (sa < 0) == (sb < 0) else -1))
    elif f3 == 5: r = (1 << bits) - 1 if ub == 0 else ua // ub
    elif f3 == 6:
        r = sa if sb == 0 else (0 if (sa == -(1 << (bits - 1)) and sb == -1) else sa - sb * (abs(sa) // abs(sb) * (1 if (sa < 0) == (sb < 0) else -1)))
    else: r = ua if ub == 0 else ua % ub
    return sx(r, 32) & M if word else r & M

def fp_op(ins, x, f, rm):
    """OP-FP -> (fp result or None, int result or None, fflags)"""
    rs1 = (ins >> 15) & 31; rs2 = (ins >> 20) & 31; f3 = (ins >> 12) & 7
    f7 = ins >> 25; fmt = f7 & 3; f5 = f7 >> 2
    a, b = fm.unbox(f[rs1], fmt), fm.unbox(f[rs2], fmt)
    def F(r): return fm.box(r[0], fmt), None, r[1]
    def X(r): return None, r[0], r[1]
    if f5 == 0x00: return F(fm.fma(a, fm.ONE[fmt], b, fmt, rm))
    if f5 == 0x01: return F(fm.fma(a, fm.ONE[fmt], b, fmt, rm, neg_c=True))
    if f5 == 0x02: return F(fm.fma(a, b, 0, fmt, rm, no_c=True))
    if f5 == 0x03: return F(fm.fdiv(a, b, fmt, rm))
    if f5 == 0x0b: return F(fm.fsqrt(a, fmt, rm))
    if f5 == 0x04: return F(fm.fsgnj(a, b, fmt, f3))
    if f5 == 0x05: return F(fm.fminmax(a, b, fmt, f3 == 1))
    if f5 == 0x08:                          # FCVT.S.D (fmt 0, rs2 1) / FCVT.D.S (fmt 1, rs2 0)
        src = rs2 & 1
        return F(fm.f2f(fm.unbox(f[rs1], src), src, fmt, rm))
    if f5 == 0x14: return X(fm.fcmp(a, b, fmt, f3))
    if f5 == 0x18: return X(fm.f2i(a, fmt, rm, rs2 & 3))
    if f5 == 0x1a: return F(fm.i2f(x[rs1], fmt, rm, rs2 & 3))
    if f5 == 0x1c:
        if f3 == 1: return X(fm.fclass(a, fmt))
        return None, (sx(f[rs1], 32) & M if fmt == 0 else f[rs1]), 0   # FMV.X.W / FMV.X.D
    if f5 == 0x1e: return (fm.box(x[rs1] & M32, 0) if fmt == 0 else x[rs1]), None, 0
    raise Exception(hex(ins))

def rand_prog(seed, nblocks=120):
    rnd = random.Random(seed)
    regs = [1, 2, 3, 4, 5, 6, 7]
    BASE = 10                               # x10 = 0x400, data base (never written)
    blocks = [[I(0x400, 0, 0, BASE, 0x13)]]
    for r in regs:                          # 64-bit random-ish initial values
        blocks.append([U(rnd.getrandbits(20), r, 0x37), I(rnd.getrandbits(12), r, 0, r, 0x13),
                       I(rnd.randrange(64), r, 1, r, 0x13), I(rnd.getrandbits(12), r, 4, r, 0x13)])
    rr = lambda: rnd.choice(regs + [0])
    body = []
    for k in range(nblocks):
        t = rnd.random()
        if t < 0.25:                        # OP
            f3 = rnd.randrange(8); f7 = 0x20 if f3 in (0, 5) and rnd.random() < .5 else 0
            body.append(('r', [R(f7, rr(), rr(), f3, rr(), 0x33)]))
        elif t < 0.37:                      # OP-32
            f3 = rnd.choice([0, 1, 5]); f7 = 0x20 if f3 in (0, 5) and rnd.random() < .5 else 0
            body.append(('r', [R(f7, rr(), rr(), f3, rr(), 0x3b)]))
        elif t < 0.47:                      # OP-IMM (64-bit shamt)
            f3 = rnd.randrange(8)
            if f3 == 1: imm = rnd.randrange(64)
            elif f3 == 5: imm = rnd.randrange(64) | (0x400 if rnd.random() < .5 else 0)
            else: imm = rnd.getrandbits(12)
            body.append(('r', [I(imm, rr(), f3, rr(), 0x13)]))
        elif t < 0.53:                      # OP-IMM-32
            f3 = rnd.choice([0, 1, 5])
            imm = rnd.getrandbits(12) if f3 == 0 else rnd.randrange(32) | (0x400 if f3 == 5 and rnd.random() < .5 else 0)
            body.append(('r', [I(imm, rr(), f3, rr(), 0x1b)]))
        elif t < 0.57: body.append(('r', [U(rnd.getrandbits(20), rr(), rnd.choice([0x37, 0x17]))]))
        elif t < 0.70:                      # loads (LB LH LW LD LBU LHU LWU)
            f3 = rnd.choice([0, 1, 2, 3, 4, 5, 6]); al = [1, 2, 4, 8, 1, 2, 4][f3]
            body.append(('r', [I(rnd.randrange(0, 256, al), BASE, f3, rr(), 0x03)]))
            if rnd.random() < .5:
                body[-1][1].append(R(0, rr(), rnd.choice(regs), 0, rr(), 0x33))
        elif t < 0.71:                      # stores (SB SH SW SD)
            f3 = rnd.choice([0, 1, 2, 3]); al = [1, 2, 4, 8][f3]
            body.append(('r', [S(rnd.randrange(0, 256, al), rr(), BASE, f3)]))
        elif t < 0.75:
            # SQ wrap-around forwarding: an older pointer-chasing chain blocks commit, k filler stores
            # move the SQ tail, then 2-3 stores to the same dword (likely straddling the SQ wrap)
            # and an overlapping load that must forward from the youngest matching store
            ra = rnd.choice(regs)
            blk = [I(rnd.randrange(0, 128, 8), BASE, 3, ra, 0x03)]
            for _ in range(rnd.randint(2, 3)):
                blk += [I(0x78, ra, 7, ra, 0x13), R(0, BASE, ra, 0, ra, 0x33), I(0, ra, 3, ra, 0x03)]
            X = rnd.randrange(128, 256, 8)
            for _ in range(rnd.randint(0, 10)):
                blk.append(S(rnd.randrange(0, 120, 8), rr(), BASE, 3))
            for _ in range(rnd.randint(2, 3)):
                sf3 = rnd.choice([0, 1, 2, 3])
                blk.append(S(X + rnd.randrange(0, 8, [1, 2, 4, 8][sf3]), rr(), BASE, sf3))
            lf3 = rnd.choice([0, 1, 2, 3, 4, 5, 6])
            blk.append(I(X + rnd.randrange(0, 8, [1, 2, 4, 8, 1, 2, 4][lf3]), BASE, lf3, rr(), 0x03))
            body.append(('r', blk))
        elif t < 0.78:                      # store-to-load forwarding: 1-2 early stores, then an overlapping load
            o = rnd.randrange(0, 256, 8)
            blk = []
            for _ in range(rnd.choice([1, 2, 2, 3])):
                sf3 = rnd.choice([0, 1, 2, 3])
                blk.append(S(o + rnd.randrange(0, 8, [1, 2, 4, 8][sf3]), rr(), BASE, sf3))
            lf3 = rnd.choice([0, 1, 2, 3, 4, 5, 6])
            blk.append(I(o + rnd.randrange(0, 8, [1, 2, 4, 8, 1, 2, 4][lf3]), BASE, lf3, rr(), 0x03))
            body.append(('r', blk))
        elif t < 0.85:                      # memory-dependence pattern: late store, early younger load
            o = rnd.randrange(0, 256, 8)
            ra, rb, rc = rnd.choice(regs), rr(), rnd.choice(regs)
            sf3 = rnd.choice([0, 1, 2, 3]); lf3 = rnd.choice([0, 1, 2, 3, 4, 5, 6])
            so = o + rnd.randrange(0, 8, [1, 2, 4, 8][sf3]); lo = o + rnd.randrange(0, 8, [1, 2, 4, 8, 1, 2, 4][lf3])
            body.append(('r', [I(rnd.randrange(0, 256, 8), BASE, 3, ra, 0x03),   # ld  ra
                               R(0, rb, ra, 0, ra, 0x33),                         # add ra, ra, rb (late data)
                               S(so, ra, BASE, sf3),                              # store (data late)
                               I(lo, BASE, lf3, rc, 0x03)]))                      # younger overlapping load
        elif t < 0.93: body.append(('br', rnd.choice([0, 1, 4, 5, 6, 7]), rr(), rr(), rnd.randint(1, 4)))
        elif t < 0.97: body.append(('jal', rr(), rnd.randint(1, 3)))
        else:
            r = rr()
            body.append(('r', [U(0, 11, 0x17), I(12, 11, 0, r, 0x67), I(0x7ff, 0, 0, 1, 0x13)]))
    pre = sum(len(b) for b in blocks)
    while pre + sum(len(b[1]) if b[0] == 'r' else 1 for b in body) > 255:   # fit the 256-word imem
        body.pop()
    sizes = [len(b[1]) if b[0] == 'r' else 1 for b in body]
    starts = []; a = pre
    for s in sizes: starts.append(a); a += s
    starts.append(a)
    prog = [w for b in blocks for w in b]
    for i, b in enumerate(body):
        if b[0] == 'r': prog += b[1]
        elif b[0] == 'br':
            tgt = starts[min(i + b[4], len(body))]; prog.append(B((tgt - starts[i]) * 4, b[3], b[2], b[1]))
        else:
            tgt = starts[min(i + b[2], len(body))]; prog.append(J((tgt - starts[i]) * 4, b[1]))
    prog.append(HALT)
    return prog

# ---------------------------------------------------------------------------
# loop-heavy program: outer loop (x9 counter) + calls to a leaf function (x1 link)
# exercises BTB learning, backward branches, RAS (call/ret) and steady-state IPC
# ---------------------------------------------------------------------------
def loop_prog(seed, iters=24, nbody=40):
    rnd = random.Random(seed)
    regs = [2, 3, 4, 6, 7, 8]
    BASE = 10
    rr = lambda: rnd.choice(regs + [0])
    pre = [I(0x400, 0, 0, BASE, 0x13), I(iters, 0, 0, 9, 0x13)]
    for r in regs:
        pre += [U(rnd.getrandbits(20), r, 0x37), I(rnd.getrandbits(12), r, 0, r, 0x13)]
    body = []   # list of ('r', [insns]) / ('br', f3, rs1, rs2, skip) / ('call',) / ('switch', ...)
    n_sw = 0
    for k in range(nbody):
        t = rnd.random()
        if t < 0.35:
            f3 = rnd.randrange(8); f7 = 0x20 if f3 in (0, 5) and rnd.random() < .5 else 0
            body.append(('r', [R(f7, rr(), rr(), f3, rr(), rnd.choice([0x33, 0x3b]) if f3 in (0, 1, 5) else 0x33)]))
        elif t < 0.50:
            f3 = rnd.randrange(8)
            imm = rnd.randrange(64) if f3 in (1, 5) else rnd.getrandbits(12)
            body.append(('r', [I(imm, rr(), f3, rr(), 0x13)]))
        elif t < 0.65:
            f3 = rnd.choice([0, 1, 2, 3, 4, 5, 6]); al = [1, 2, 4, 8, 1, 2, 4][f3]
            body.append(('r', [I(rnd.randrange(0, 128, al), BASE, f3, rr(), 0x03)]))
        elif t < 0.75:
            f3 = rnd.choice([0, 1, 2, 3]); al = [1, 2, 4, 8][f3]
            body.append(('r', [S(rnd.randrange(0, 128, al), rr(), BASE, f3)]))
        elif t < 0.82:
            body.append(('br', rnd.choice([0, 1, 4, 5, 6, 7]), rr(), rr(), rnd.randint(1, 3)))
        elif t < 0.90:                      # periodic branch on the loop counter (history-predictable)
            r = rnd.choice(regs)
            body.append(('r', [I(rnd.choice([1, 2, 3, 5, 7]), 9, 7, r, 0x13)]))   # andi r, x9, m
            body.append(('br', rnd.choice([0, 1]), r, 0, rnd.randint(1, 2)))     # beq/bne r, x0
        elif t < 0.95 and n_sw < 4:
            # switch: jump table indexed by the loop counter -> indirect JALR with 4 targets
            cases = [[R(0, rr(), rr(), rnd.randrange(8), rnd.choice(regs), 0x33) for _ in range(rnd.randint(1, 2))]
                     for _ in range(4)]
            body.append(('switch', n_sw, rnd.choice([3, 3, 1]), cases))
            n_sw += 1
        else:
            body.append(('call',))
    # layout: pre | loop: body | addi x9,-1 ; bne x9,x0,loop | halt | func: ... ret
    TB = 32  # jump tables at x10 + 128 + 32*site (loop-mode loads/stores use offsets < 128)
    swsize = lambda b: 5 + sum(len(c) + 1 for c in b[3]) - 1
    pre_sw = 2 * 4 * n_sw     # table init: addi t, x0, case_addr ; sd t, off(x10)
    sizes = [len(b[1]) if b[0] == 'r' else (swsize(b) if b[0] == 'switch' else 1) for b in body]
    starts = []; a = len(pre) + pre_sw
    for sz in sizes: starts.append(a); a += sz
    end_body = a
    tail = [I(-1 & 0xfff, 9, 0, 9, 0x13), None, HALT]
    func_start = end_body + len(tail)
    func = [R(0, rr(), rr(), rnd.randrange(8), rnd.choice(regs), 0x33) for _ in range(3)] + [I(0, 1, 0, 0, 0x67)]
    prog = list(pre)
    sw_code = {}
    loop_prog.abs_fix = {}
    for i, b in enumerate(body):
        if b[0] == 'switch':
            site, mask, cases = b[1], b[2], b[3]
            st = starts[i]
            tmp = 11
            code = [I(mask, 9, 7, tmp, 0x13),             # andi x11, x9, mask
                    I(3, tmp, 1, tmp, 0x13),              # slli x11, x11, 3
                    R(0, BASE, tmp, 0, tmp, 0x33),        # add  x11, x11, x10
                    I(128 + TB * site, tmp, 3, tmp, 0x03),  # ld x11, tbl(x11)
                    I(0, tmp, 0, 0, 0x67)]                # jalr x0, 0(x11)
            addrs = []
            join = st + swsize(b)
            for ci, c in enumerate(cases):
                addrs.append(4 * (st + len(code)))
                code += c
                if ci < 3:
                    code.append(J((join - (st + len(code))) * 4, 0))   # jal x0, join
            assert len(code) == swsize(b)
            sw_code[i] = code
            for k in range(4):
                loop_prog.abs_fix[len(prog)] = addrs[k] // 4
                prog += [I(addrs[k], 0, 0, 11, 0x13), S(128 + TB * site + 8 * k, 11, BASE, 3)]
    for i, b in enumerate(body):
        if b[0] == 'r': prog += b[1]
        elif b[0] == 'switch': prog += sw_code[i]
        elif b[0] == 'br':
            tgt = starts[i + b[4]] if i + b[4] < len(body) else end_body
            prog.append(B((tgt - starts[i]) * 4, b[3], b[2], b[1]))
        else:
            prog.append(J((func_start - starts[i]) * 4, 1))      # jal x1, func
    tail[1] = B((len(pre) + pre_sw - (end_body + 1)) * 4, 0, 9, 1)  # bne x9, x0, loop
    prog += tail + func
    return prog

# ---------------------------------------------------------------------------
# FP / M program (MODE=fp): F/D arithmetic with random rounding modes, conversions, compares,
# NaN-boxing (S and D values mixed in the same registers), FP loads/stores, MUL/DIV/REM corner
# cases, and branches on FP compare results. Data memory holds special FP values.
# ---------------------------------------------------------------------------
def R4(rs3, fmt, rs2, rs1, rm, rd, op): return (rs3 << 27 | fmt << 25 | rs2 << 20 | rs1 << 15 | rm << 12 | rd << 7 | op) & M32

SPEC_D = [0, 1 << 63, 0x7ff0000000000000, 0xfff0000000000000, 0x7ff8000000000000, 0x7ff0000000000001,
          0xfff4000000000123, 1, 0x000fffffffffffff, 0x0010000000000000, 0x7fefffffffffffff, 0x3ff0000000000000,
          0xbff0000000000000, 0x4000000000000000, 0x3fe0000000000000, 0x3ff8000000000000, 0x3ff0000000000001,
          0x400921fb54442d18, 0x43e0000000000000, 0xc3e0000000000000, 0x43f0000000000000, 0x41e0000000000000,
          0xc1e0000000000000, 0x41efffffffe00000, 0x3fefffffffffffff, 0x8000000000000001, 0x3cb0000000000000,
          0x7fe0000000000000, 0x0008000000000000, 0xc3dfffffffffffff, 0x3fe0000000000001, 0x4330000000000000]
SPEC_S = [0, 0x80000000, 0x7f800000, 0xff800000, 0x7fc00000, 0x7f800001, 0xffa00123, 1, 0x007fffff, 0x00800000,
          0x7f7fffff, 0x3f800000, 0xbf800000, 0x40000000, 0x3f000000, 0x3fc00000, 0x3f800001, 0x40490fdb,
          0x5f000000, 0xdf000000, 0x5f800000, 0x4f000000, 0xcf000000, 0x4f7fffff, 0x3f7fffff, 0x80000001,
          0x33800000, 0x7f000000, 0x00400000, 0xcf000001, 0x3f000001, 0x4b000000]

def fp_data(seed, spec=0.12):
    rnd = random.Random(1000003 * seed + 7)
    d = [rnd.getrandbits(64) for _ in range(256)]
    for i in range(128, 160):               # x10 + 0..255: double operands
        t = rnd.random()
        if t < spec: d[i] = rnd.choice(SPEC_D)
        elif t < 0.95:                      # moderate doubles (exact cancellation, rounding ties ...)
            d[i] = rnd.getrandbits(1) << 63 | (1023 + rnd.randint(-12, 12)) << 52 | (rnd.getrandbits(52) & rnd.choice([M, ~0xfff & M, 0xfffff << 32]))
        else: d[i] = rnd.getrandbits(64)
    for i in range(160, 192):               # x10 + 256..511: single operands (NaN-boxed)
        t = rnd.random()
        if t < spec: d[i] = 0xffffffff00000000 | rnd.choice(SPEC_S)
        elif t < 0.95 or spec == 0:
            d[i] = 0xffffffff00000000 | rnd.getrandbits(1) << 31 | (127 + rnd.randint(-10, 10)) << 23 | (rnd.getrandbits(23) & rnd.choice([0x7fffff, 0x7ff000]))
        else: d[i] = rnd.getrandbits(64)
    return d

# Zicsr block: reads / writes of fflags, frm (only valid modes 0..4 are written), fcsr, and the
# counters. cycle / time values are not reproducible by the ISS, so they are cleared right away.
def csr_block(rnd, t):
    CSR = lambda csr, src, f3, rd: (csr << 20 | src << 15 | f3 << 12 | rd << 7 | 0x73) & M32
    k = rnd.randrange(8); rd = rnd.choice([0, t, t])
    if k == 0: return [CSR(rnd.choice([1, 2, 3]), 0, rnd.choice([2, 3, 6, 7]), t)]                 # read
    if k == 1: return [CSR(1, rnd.randrange(32), rnd.choice([5, 6, 7]), rd)]                     # fflags imm
    if k == 2: return [I(rnd.randrange(64), 0, 0, t, 0x13), CSR(1, t, rnd.choice([1, 2, 3]), rd)]
    if k == 3: return [CSR(2, rnd.randrange(5), 5, rd)]                                         # frm <- 0..4
    if k == 4: return [I(rnd.randrange(5), 0, 0, t, 0x13), CSR(2, t, 1, rd)]
    if k == 5: return [I(rnd.randrange(5) << 5 | rnd.randrange(32), 0, 0, t, 0x13), CSR(3, t, 1, rd)]
    if k == 6: return [CSR(0xc02, 0, 2, t)]                                                      # instret
    return [CSR(rnd.choice([0xc00, 0xc01]), 0, 2, t), I(0, t, 7, t, 0x13)]                     # cycle / time

def fp_prog(seed, csr=False):
    rnd = random.Random(seed)
    BASE = 10
    iregs = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    fregs = list(range(16))
    ffmt = {r: r & 1 for r in fregs}        # format last written to each FP register (generator view)
    pre = [I(0x400, 0, 0, BASE, 0x13)]
    for r in iregs[:6]:
        pre += [U(rnd.getrandbits(20), r, 0x37), I(rnd.getrandbits(12), r, 0, r, 0x13), I(rnd.randrange(64), r, 1, r, 0x13)]
    pre += [I(-1 & 0xfff, 0, 0, 7, 0x13), I(1, 0, 0, 8, 0x13), I(63, 8, 1, 8, 0x13), I(rnd.randrange(-9, 10) & 0xfff, 0, 0, 9, 0x13)]
    ldoff = lambda fmt: 8 * rnd.randrange(32) + (0 if fmt else 256)   # D / S operand areas
    for r in fregs:
        pre.append(I(ldoff(ffmt[r]), BASE, 3 if ffmt[r] else 2, r, 0x07))
    rr = lambda: rnd.choice(iregs + [0])
    rmc = lambda: rnd.choice([0, 0, 1, 2, 3, 4, 7, 7])
    def fsrc(fmt):
        same = [r for r in fregs if ffmt[r] == fmt]
        return rnd.choice(same) if same and rnd.random() < 0.96 else rnd.choice(fregs)
    def fdst(fmt):
        r = rnd.choice(fregs); ffmt[r] = fmt; return r
    def fpop(kind):
        fmt = rnd.getrandbits(1)
        if kind == 'arith':
            f5 = rnd.choice([0, 1, 2]); a, b = fsrc(fmt), fsrc(fmt)
            return [R(f5 << 2 | fmt, b, a, rmc(), fdst(fmt), 0x53)]
        if kind == 'fma':
            a, b, c = fsrc(fmt), fsrc(fmt), fsrc(fmt)
            return [R4(c, fmt, b, a, rmc(), fdst(fmt), rnd.choice([0x43, 0x47, 0x4b, 0x4f]))]
        if kind == 'div':
            a, b = fsrc(fmt), fsrc(fmt)
            if rnd.random() < 0.4: return [R(0x0b << 2 | fmt, 0, a, rmc(), fdst(fmt), 0x53)]
            return [R(0x03 << 2 | fmt, b, a, rmc(), fdst(fmt), 0x53)]
        if kind == 'sgnj':
            a, b = fsrc(fmt), fsrc(fmt)
            if rnd.random() < 0.5: return [R(0x04 << 2 | fmt, b, a, rnd.randrange(3), fdst(fmt), 0x53)]
            return [R(0x05 << 2 | fmt, b, a, rnd.randrange(2), fdst(fmt), 0x53)]
        if kind == 'cmp':
            a, b = fsrc(fmt), fsrc(fmt)
            if rnd.random() < 0.3: return [R(0x1c << 2 | fmt, 0, a, 1, rr(), 0x53)]          # FCLASS
            return [R(0x14 << 2 | fmt, b, a, rnd.randrange(3), rr(), 0x53)]
        if kind == 'cvt':
            t = rnd.random()
            if t < 0.35: return [R(0x18 << 2 | fmt, rnd.randrange(4), fsrc(fmt), rmc(), rr(), 0x53)]   # f -> int
            if t < 0.7:  return [R(0x1a << 2 | fmt, rnd.randrange(4), rr(), rmc(), fdst(fmt), 0x53)]   # int -> f
            src = 1 - fmt
            return [R(0x08 << 2 | fmt, src, fsrc(src), rmc(), fdst(fmt), 0x53)]                       # S <-> D
        if kind == 'mv':
            if rnd.random() < 0.5: return [R(0x1c << 2 | fmt, 0, fsrc(fmt), 0, rr(), 0x53)]
            return [R(0x1e << 2 | fmt, 0, rr(), 0, fdst(fmt), 0x53)]
        if kind == 'mem':
            o = 8 * rnd.randrange(64)
            if rnd.random() < 0.5: return [I(ldoff(fmt) + (4 * (rnd.random() < 0.1) if not fmt else 0), BASE, 3 if fmt else 2, fdst(fmt), 0x07)]
            blk = [S(o, fsrc(fmt), BASE, 3 if fmt else 2)]
            if rnd.random() < 0.5:          # forwarding from an FP store to an int / FP load
                if rnd.random() < 0.5:      # aligned accesses only
                    lo = rnd.choice([0, 4]) if fmt else 0
                    blk.append(I(o + lo, BASE, rnd.choice([2, 6] if (lo or not fmt) else [2, 3, 6]), rr(), 0x03))
                else: f2 = rnd.getrandbits(1); blk.append(I(o, BASE, 3 if f2 else 2, fdst(f2), 0x07))
            return blk
        raise Exception(kind)
    body = []
    while True:
        t = rnd.random()
        if t < 0.13: body.append(('r', fpop('arith')))
        elif t < 0.22: body.append(('r', fpop('fma')))
        elif t < 0.28: body.append(('r', fpop('div')))
        elif t < 0.34: body.append(('r', fpop('sgnj')))
        elif t < 0.40: body.append(('r', fpop('cmp')))
        elif t < 0.49: body.append(('r', fpop('cvt')))
        elif t < 0.53: body.append(('r', fpop('mv')))
        elif t < 0.61: body.append(('r', fpop('mem')))
        elif t < 0.73:                      # M extension
            word = rnd.random() < 0.35
            f3 = rnd.choice([0, 4, 5, 6, 7]) if word else rnd.randrange(8)
            body.append(('r', [R(1, rr(), rr(), f3, rr(), 0x3b if word else 0x33)]))
        elif t < 0.79:
            f3 = rnd.randrange(8); f7 = 0x20 if f3 in (0, 5) and rnd.random() < .5 else 0
            body.append(('r', [R(f7, rr(), rr(), f3, rr(), 0x33)]))
        elif t < 0.85:                      # dependent FP chain
            fmt = rnd.getrandbits(1); r = fsrc(fmt); blk = []
            for _ in range(rnd.randint(2, 4)):
                k = rnd.random()
                if k < 0.4: blk.append(R(rnd.choice([0, 1, 2]) << 2 | fmt, fsrc(fmt), r, rmc(), r, 0x53))
                elif k < 0.7: blk.append(R4(fsrc(fmt), fmt, r, r, rmc(), r, 0x43))
                elif k < 0.8: blk.append(R(0x03 << 2 | fmt, fsrc(fmt), r, rmc(), r, 0x53))
                else: blk.append(R(0x04 << 2 | fmt, fsrc(fmt), r, 2, r, 0x53))
            ffmt[r] = fmt
            body.append(('r', blk))
        elif t < 0.91:                      # branch on an FP compare
            fmt = rnd.getrandbits(1); ra = rnd.choice(iregs)
            body.append(('r', [R(0x14 << 2 | fmt, fsrc(fmt), fsrc(fmt), rnd.randrange(3), ra, 0x53)]))
            body.append(('br', rnd.choice([0, 1]), ra, 0, rnd.randint(1, 3)))
        elif t < 0.96: body.append(('br', rnd.choice([0, 1, 4, 5, 6, 7]), rr(), rr(), rnd.randint(1, 3)))
        else: body.append(('jal', rr(), rnd.randint(1, 2)))
        if csr and rnd.random() < 0.10:
            body.append(('r', csr_block(rnd, rnd.choice(iregs))))
        if rnd.random() < 0.15:             # reload an FP register (keeps NaNs from taking over)
            fmt = rnd.getrandbits(1)
            body.append(('r', [I(ldoff(fmt), BASE, 3 if fmt else 2, fdst(fmt), 0x07)]))
        if len(pre) + sum(len(b[1]) if b[0] == 'r' else 1 for b in body) > 250: break
    while len(pre) + sum(len(b[1]) if b[0] == 'r' else 1 for b in body) > 255: body.pop()
    sizes = [len(b[1]) if b[0] == 'r' else 1 for b in body]
    starts = []; a = len(pre)
    for sz in sizes: starts.append(a); a += sz
    starts.append(a)
    prog = list(pre)
    for i, b in enumerate(body):
        if b[0] == 'r': prog += b[1]
        elif b[0] == 'br':
            tgt = starts[min(i + b[4], len(body))]; prog.append(B((tgt - starts[i]) * 4, b[3], b[2], b[1]))
        else:
            tgt = starts[min(i + b[2], len(body))]; prog.append(J((tgt - starts[i]) * 4, b[1]))
    prog.append(HALT)
    return prog

# ---------------------------------------------------------------------------
# FP loop program (MODE=fploop): steady-state FP throughput. Each iteration loads one double and
# one single from an array indexed by the loop counter, runs multiply-add accumulation chains,
# independent FP ops, a few FDIV/FSQRT, FP->int conversions, compare-and-branch, MUL/DIV, and
# stores results back to the array (store-to-load forwarding in later iterations).
# f0..f7 hold doubles, f8..f15 singles; accumulators only add products of freshly loaded values,
# so values stay finite.
# ---------------------------------------------------------------------------
def fploop_prog(seed, iters=24, nbody=34):
    rnd = random.Random(seed)
    BASE, T = 10, 11
    pre = [I(0x400, 0, 0, BASE, 0x13), I(iters, 0, 0, 9, 0x13)]
    for r in range(16):
        fmt = int(r < 8)
        pre.append(I(8 * rnd.randrange(32) + (0 if fmt else 256), BASE, 3 if fmt else 2, r, 0x07))
    for r in (1, 2, 3, 4):
        pre += [U(rnd.getrandbits(20), r, 0x37), I(rnd.getrandbits(12), r, 0, r, 0x13)]
    head = [I(31, 9, 7, T, 0x13), I(3, T, 1, T, 0x13), R(0, BASE, T, 0, T, 0x33),   # x11 = &a[x9 & 31]
            I(0, T, 3, 6, 0x07), I(256, T, 2, 14, 0x07)]                             # fld f6 ; flw f14
    fr = lambda fmt: rnd.choice(range(8) if fmt else range(8, 16))
    rmc = lambda: rnd.choice([0, 0, 0, 1, 2, 3, 4, 7])
    body = []
    for k in range(nbody):
        t = rnd.random(); fmt = int(rnd.random() < 0.6)
        ld = 6 if fmt else 14
        acc = rnd.choice([0, 1, 2] if fmt else [8, 9, 10])
        if t < 0.25:                        # acc += ld * x     (latency-bound chain)
            body.append(('r', [R4(acc, fmt, fr(fmt), ld, rmc(), acc, 0x43)]))
        elif t < 0.40:                      # independent arithmetic into a temp
            tmp = rnd.choice([3, 4, 5, 7] if fmt else [11, 12, 13, 15])
            body.append(('r', [R(rnd.choice([0, 1, 2]) << 2 | fmt, fr(fmt), ld, rmc(), tmp, 0x53)]))
        elif t < 0.48:                      # tmp = acc op ld ; fmin/fmax/fsgnj
            tmp = rnd.choice([3, 4, 5, 7] if fmt else [11, 12, 13, 15])
            f5 = rnd.choice([0x04, 0x05])
            body.append(('r', [R(f5 << 2 | fmt, ld, acc, rnd.randrange(2), tmp, 0x53)]))
        elif t < 0.53:                      # tmp = sqrt(|ld|) or ld / acc
            tmp = rnd.choice([3, 4, 5, 7] if fmt else [11, 12, 13, 15])
            if rnd.random() < 0.5: body.append(('r', [R(0x04 << 2 | fmt, ld, ld, 2, tmp, 0x53), R(0x0b << 2 | fmt, 0, tmp, rmc(), tmp, 0x53)]))
            else: body.append(('r', [R(0x03 << 2 | fmt, acc, ld, rmc(), tmp, 0x53)]))
        elif t < 0.60:                      # int sum += (int) tmp
            r = rnd.choice([1, 2, 3, 4])
            body.append(('r', [R(0x18 << 2 | fmt, rnd.randrange(4), fr(fmt), 1, 5, 0x53), R(0, 5, r, 0, r, 0x33)]))
        elif t < 0.67:                      # compare and branch
            body.append(('r', [R(0x14 << 2 | fmt, fr(fmt), ld, rnd.randrange(3), 5, 0x53)]))
            body.append(('br', rnd.choice([0, 1]), 5, 0, rnd.randint(1, 2)))
        elif t < 0.75:                      # store a value back into the array
            body.append(('r', [S(0 if fmt else 256, fr(fmt), T, 3 if fmt else 2)]))
        elif t < 0.82:                      # int <-> FP conversions
            tmp = rnd.choice([3, 4, 5, 7] if fmt else [11, 12, 13, 15])
            body.append(('r', [R(0x1a << 2 | fmt, rnd.randrange(4), rnd.choice([1, 2, 3, 4]), rmc(), tmp, 0x53)]))
        elif t < 0.90:
            f3 = rnd.choice([0, 0, 1, 3, 4, 6]); r = rnd.choice([1, 2, 3, 4])
            body.append(('r', [R(1, rnd.choice([1, 2, 3, 4, 9]), r, f3, r, 0x33)]))
        else:
            body.append(('r', [R(rnd.choice([0, 1]) << 2 | fmt, fr(fmt), fr(fmt), rmc(), fr(fmt), 0x53)]))
    sizes = [len(b[1]) if b[0] == 'r' else 1 for b in body]
    starts = []; a = len(pre) + len(head)
    for sz in sizes: starts.append(a); a += sz
    end_body = a
    prog = pre + head
    for i, b in enumerate(body):
        if b[0] == 'r': prog += b[1]
        else:
            tgt = starts[i + b[4]] if i + b[4] < len(body) else end_body
            prog.append(B((tgt - starts[i]) * 4, b[3], b[2], b[1]))
    prog += [I(-1 & 0xfff, 9, 0, 9, 0x13), B((len(pre) - (end_body + 1)) * 4, 0, 9, 1), HALT]
    return prog

# ---------------------------------------------------------------------------
# RVC program (MODE=rvc): an outer loop whose body is mostly made of instructions that have
# compressed forms (x8..x15 / sp-relative accesses, c.beqz/c.bnez, c.j, c.jr, c.jalr) mixed with
# 32-bit ones, so that instructions start at any halfword and 32-bit instructions straddle fetch
# blocks. Integer + D only, so it can be cross-checked against Unicorn.
#   x2 = x10 = 0x400 (data), x9 = loop counter, x1 = link
# ---------------------------------------------------------------------------
def rvc_prog(seed, iters=12, nbody=60):
    rnd = random.Random(seed)
    cr = [8, 11, 12, 13, 14, 15]            # compressible registers (x9, x10 reserved)
    ar = cr + [3, 4, 5, 6, 7]
    pre = [I(0x400, 0, 0, 10, 0x13), I(0x400, 0, 0, 2, 0x13), I(iters, 0, 0, 9, 0x13)]
    for r in ar:
        pre += [U(rnd.getrandbits(20), r, 0x37), I(rnd.getrandbits(12), r, 0, r, 0x13)]
    for r in range(8, 16):
        pre.append(I(8 * rnd.randrange(32), 10, 3, r, 0x07))
    body = []
    for k in range(nbody):
        t = rnd.random(); c = rnd.choice(cr)
        if t < 0.30:
            body.append(('r', [rnd.choice([
                I(rnd.randint(-32, 31) or 1, c, 0, c, 0x13), I(rnd.randint(-32, 31), 0, 0, c, 0x13),
                U(rnd.choice([1, 2, 31, 0xfffff, 0xfffe0]), c, 0x37), I(rnd.randrange(1, 64), c, 1, c, 0x13),
                I(rnd.randrange(1, 64), c, 5, c, 0x13), I(0x400 | rnd.randrange(1, 64), c, 5, c, 0x13),
                I(rnd.randint(-32, 31), c, 7, c, 0x13), R(0, rnd.choice(ar), 0, 0, c, 0x33),
                R(0, rnd.choice(ar), c, 0, c, 0x33), I(rnd.randint(-32, 31), c, 0, c, 0x1b),
                rnd.choice([R(0x20, rnd.choice(cr), c, 0, c, 0x33), R(0, rnd.choice(cr), c, rnd.choice([4, 6, 7]), c, 0x33)]),
                R(rnd.choice([0x20, 0]), rnd.choice(cr), c, 0, c, 0x3b),
                I(4 * rnd.randrange(1, 64), 2, 0, c, 0x13)])]))
        elif t < 0.42:                      # 32-bit-only instructions in between
            body.append(('r', [rnd.choice([
                R(0, rnd.choice(ar), rnd.choice(ar), rnd.randrange(8), rnd.choice(ar), 0x33),
                I(rnd.getrandbits(12), rnd.choice(ar), 0, rnd.choice(ar), 0x13),
                R(1, rnd.choice(ar), rnd.choice(ar), rnd.choice([0, 1, 4, 6]), rnd.choice(ar), 0x33),
                R(0x01, rnd.randrange(8, 16), rnd.randrange(8, 16), 0, rnd.randrange(8, 16), 0x53),
                R(0x09, rnd.randrange(8, 16), rnd.randrange(8, 16), 0, rnd.randrange(8, 16), 0x53)])]))
        elif t < 0.62:                      # loads / stores (x10- and sp-relative)
            sz = rnd.choice([2, 3, 3]); o = 8 * rnd.randrange(16) + (4 * rnd.getrandbits(1) if sz == 2 else 0)
            base = rnd.choice([10, 2])
            r = c if base == 10 else rnd.choice(ar)
            body.append(('r', [rnd.choice([I(o, base, sz, r, 0x03), S(o, r, base, sz),
                                           I(o & ~7, base, 3, rnd.randrange(8, 16), 0x07),
                                           S(o & ~7, rnd.randrange(8, 16), base, 3) | 0x04])]))
        elif t < 0.70:                      # sp adjust and restore
            v = 16 * rnd.randint(1, 8)
            body.append(('r', [I(v, 2, 0, 2, 0x13), I(8 * rnd.randrange(8), 2, 3, c, 0x03), I(-v, 2, 0, 2, 0x13)]))
        elif t < 0.82: body.append(('br', rnd.choice([0, 1]), c, 0, rnd.randint(1, 3)))   # c.beqz / c.bnez
        elif t < 0.86: body.append(('br', rnd.choice([4, 5, 6, 7]), rnd.choice(ar), rnd.choice(ar), rnd.randint(1, 3)))
        elif t < 0.90: body.append(('jal', 0, rnd.randint(1, 3)))                        # c.j
        elif t < 0.95: body.append(('call',))
        else: body.append(('icall', c))                                                  # c.jalr
    sizes = [len(b[1]) if b[0] == 'r' else (2 if b[0] == 'icall' else 1) for b in body]
    starts = []; a = len(pre)
    for sz in sizes: starts.append(a); a += sz
    end_body = a
    tail = [I(-1 & 0xfff, 9, 0, 9, 0x13), None, HALT]
    func_start = end_body + len(tail)
    func = [R(0, rnd.choice(ar), rnd.choice(cr), 0, rnd.choice(cr), 0x33), I(rnd.randint(-32, 31), 8, 0, 8, 0x13),
            I(0, 1, 0, 0, 0x67)]                                       # ... c.jr ra
    prog = list(pre)
    rvc_prog.abs_fix = {}
    for i, b in enumerate(body):
        if b[0] == 'r': prog += b[1]
        elif b[0] == 'br':
            tgt = starts[i + b[4]] if i + b[4] < len(body) else end_body
            prog.append(B((tgt - starts[i]) * 4, b[3], b[2], b[1]))
        elif b[0] == 'jal':
            tgt = starts[i + b[2]] if i + b[2] < len(body) else end_body
            prog.append(J((tgt - starts[i]) * 4, 0))
        elif b[0] == 'call': prog.append(J((func_start - starts[i]) * 4, 1))
        else:
            rvc_prog.abs_fix[len(prog)] = func_start
            prog += [I(4 * func_start, 0, 0, b[1], 0x13), I(0, b[1], 0, 1, 0x67)]
    tail[1] = B((len(pre) - (end_body + 1)) * 4, 0, 9, 1)
    prog += tail + func
    return prog

def build(seed, mode):
    """-> (program bytes, data memory words). mode: '' | loop | fp | fpcsr | fploop | rvc,
       options: '+c' re-layout with RVC instructions"""
    base, *opts = (mode or '').split('+')
    abs_fix = {}
    if base == 'loop': prog = loop_prog(seed); abs_fix = loop_prog.abs_fix
    elif base == 'fp': prog = fp_prog(seed)
    elif base == 'fpcsr': prog = fp_prog(seed, csr=True)
    elif base == 'fploop': prog = fploop_prog(seed)
    elif base == 'rvc': prog = rvc_prog(seed); abs_fix = rvc_prog.abs_fix
    else: prog = rand_prog(seed)
    rnd = random.Random(1000003 * seed)
    dinit = [rnd.getrandbits(64) for _ in range(256)]
    if base in ('fp', 'fpcsr', 'fploop', 'rvc'): dinit = fp_data(seed, 0 if base in ('fploop', 'rvc') else 0.12)
    if 'c' in opts or base == 'rvc':
        keep = set()
        for i, w in enumerate(prog):        # auipc-relative sequences keep their 4-byte layout
            if (w & 0x7f) == 0x17: keep |= {i, i + 1, i + 2}
        code = rvc.compress_prog(prog, random.Random(seed * 7919 + 1), 0.85 if base == 'rvc' else 0.7, keep, abs_fix)
    else:
        code = b''.join(w.to_bytes(4, 'little') for w in prog)
    assert len(code) <= 1024
    return code, dinit

if __name__ == '__main__':
    seed = int(sys.argv[1]); mode = sys.argv[2] if len(sys.argv) > 2 else ''
    code, dinit = build(seed, mode)
    code += b'\x13\x00\x00\x00' * ((len(code) % 4) // 2)       # pad to whole words (nop)
    open('prog.hex', 'w').write('\n'.join('%08x' % int.from_bytes(code[i:i + 4], 'little') for i in range(0, len(code), 4)) + '\n')
    open('dmem.hex', 'w').write('\n'.join('%016x' % v for v in dinit) + '\n')
    x, mem, n, trace, f = iss(code, dmem_init=dinit)
    open('iss_count.txt', 'w').write('%d\n' % n)
    open('iss_trace.txt', 'w').write(''.join('%s ?\n' % t[0] if t[1] is None else '%s %016x\n' % t for t in trace))
    with open('iss_out.txt', 'w') as fo:
        for i in range(1, 32): fo.write('x%d %016x\n' % (i, x[i]))
        for i in range(32): fo.write('f%d %016x\n' % (i, f[i]))
        for i in range(256): fo.write('m%d %016x\n' % (i, mem[i]))
        fo.write('fflags %02x\nfrm %x\n' % (iss.fflags, iss.frm))
