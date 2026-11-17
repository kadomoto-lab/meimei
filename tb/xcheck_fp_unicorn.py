# Per-instruction cross-check of the FP reference model (fpmodel.py) against Unicorn (QEMU softfloat).
#   usage: xcheck_fp_unicorn.py [N tests] [seed]
# Unicorn 2.x is based on QEMU 5.0, which predates NaN-boxing, F v2.2 FMIN/FMAX on sNaN and
# NV for inf * 0 + qNaN in FMA (all three are excluded / worked around), so single-precision results are
# compared on their low 32 bits only; double and integer results are compared in full.
import sys, random
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV64
from unicorn.riscv_const import UC_RISCV_REG_X5, UC_RISCV_REG_X6, UC_RISCV_REG_X7, UC_RISCV_REG_F1, UC_RISCV_REG_F2, \
    UC_RISCV_REG_F3, UC_RISCV_REG_F4, UC_RISCV_REG_MSTATUS, UC_RISCV_REG_PC, UC_RISCV_REG_FFLAGS, UC_RISCV_REG_FRM
import fpmodel as fm
from gen import R, R4, SPEC_D, SPEC_S, muldiv

N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 1)
uc = Uc(UC_ARCH_RISCV, UC_MODE_RISCV64)
uc.mem_map(0, 0x1000)
uc.reg_write(UC_RISCV_REG_MSTATUS, uc.reg_read(UC_RISCV_REG_MSTATUS) | (1 << 13))
M64 = (1 << 64) - 1


def operand(fmt):
    t = rnd.random()
    if fmt == 1:
        if t < 0.3: return rnd.choice(SPEC_D)
        if t < 0.8: return rnd.getrandbits(1) << 63 | (1023 + rnd.randint(-30, 30)) << 52 | rnd.getrandbits(52) & rnd.choice([M64, ~0xffffff & M64])
        if t < 0.9: return rnd.getrandbits(1) << 63 | rnd.randint(0, 60) << 52 | rnd.getrandbits(52)       # tiny / subnormal results
        return rnd.getrandbits(64)
    if t < 0.3: return rnd.choice(SPEC_S)
    if t < 0.8: return rnd.getrandbits(1) << 31 | (127 + rnd.randint(-20, 20)) << 23 | rnd.getrandbits(23) & rnd.choice([0x7fffff, 0x7ff000])
    if t < 0.9: return rnd.getrandbits(1) << 31 | rnd.randint(0, 30) << 23 | rnd.getrandbits(23)
    return rnd.getrandbits(32)


def int_operand():
    return rnd.choice([0, 1, M64, 1 << 63, (1 << 63) - 1, 1 << 31, (1 << 31) - 1, 0xffffffff, 0xffffffff80000000,
                       rnd.getrandbits(64), rnd.getrandbits(32), rnd.getrandbits(rnd.randint(1, 64)),
                       (-rnd.getrandbits(rnd.randint(1, 63))) & M64])


ops = ['md', 'md', 'add', 'sub', 'mul', 'div', 'sqrt', 'fma', 'sgnj', 'minmax', 'cmp', 'class', 'f2i', 'i2f', 'f2f', 'mvx']
bad = 0
for t in range(N):
    op = rnd.choice(ops); fmt = rnd.getrandbits(1); rm = rnd.choice([0, 1, 2, 3, 4])
    frm = rnd.choice([0, 1, 2, 3, 4]); dyn = rnd.random() < 0.3   # rm = 7: use frm
    erm = frm if dyn else rm
    a, b, c = operand(fmt), operand(fmt), operand(fmt)
    xi = int_operand()
    fd_res = xd_res = None; flags = 0
    if op == 'md':
        word = rnd.getrandbits(1); f3 = rnd.randrange(8) if not word else rnd.choice([0, 4, 5, 6, 7])
        ins = R(1, 6, 7, f3, 5, 0x3b if word else 0x33); xb = int_operand(); xd_res = muldiv(f3, xb, xi, word)
        uc.reg_write(UC_RISCV_REG_X7, xb)
    elif op == 'add': ins = R(0 << 2 | fmt, 2, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.fma(a, fm.ONE[fmt], b, fmt, erm)
    elif op == 'sub': ins = R(1 << 2 | fmt, 2, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.fma(a, fm.ONE[fmt], b, fmt, erm, neg_c=True)
    elif op == 'mul': ins = R(2 << 2 | fmt, 2, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.fma(a, b, 0, fmt, erm, no_c=True)
    elif op == 'div': ins = R(3 << 2 | fmt, 2, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.fdiv(a, b, fmt, erm)
    elif op == 'sqrt':
        if rnd.random() < 0.7: a &= ~(1 << (63 if fmt else 31))
        ins = R(0x0b << 2 | fmt, 0, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.fsqrt(a, fmt, erm)
    elif op == 'fma':
        k = rnd.randrange(4); opc = [0x43, 0x47, 0x4b, 0x4f][k]
        if rnd.random() < 0.3:                      # near-cancellation: c ~ -(a*b)
            c = fm.fma(a, b, 0, fmt, rnd.randrange(5), no_c=True)[0] ^ ((1 << (63 if fmt else 31)) if k in (0, 3) else 0)
            c ^= rnd.getrandbits(3)
        ins = R4(4, fmt, 2, 1, 7 if dyn else rm, 3, opc); fd_res, flags = fm.fma(a, b, c, fmt, erm, neg_prod=k >= 2, neg_c=k in (1, 3))
    elif op == 'sgnj':
        m = rnd.randrange(3); ins = R(0x04 << 2 | fmt, 2, 1, m, 3, 0x53); fd_res, flags = fm.fsgnj(a, b, fmt, m)
    elif op == 'minmax':
        if rnd.random() < 0.2: b = a ^ (1 << (63 if fmt else 31))
        m = rnd.randrange(2); ins = R(0x05 << 2 | fmt, 2, 1, m, 3, 0x53); fd_res, flags = fm.fminmax(a, b, fmt, m == 1)
    elif op == 'cmp':
        if rnd.random() < 0.2: b = a
        m = rnd.randrange(3); ins = R(0x14 << 2 | fmt, 2, 1, m, 5, 0x53); xd_res, flags = fm.fcmp(a, b, fmt, m)
    elif op == 'class': ins = R(0x1c << 2 | fmt, 0, 1, 1, 5, 0x53); xd_res, flags = fm.fclass(a, fmt)
    elif op == 'f2i':
        it = rnd.randrange(4)
        if rnd.random() < 0.5:                      # values near the integer range limits / small values
            v = rnd.choice([0, 1, 2, 3, 31, 32, 62, 63, 64]) + (rnd.choice([0.0, 0.5, -0.5, 0.25]))
            a = fm.round_pack(rnd.getrandbits(1), int(abs(v) * 4) or 1, -2, fmt, 0)[0] if v else 0
            a = fm.i2f(rnd.choice([1 << 31, (1 << 31) - 1, 1 << 63, (1 << 32) - 1, 0x80000001, rnd.getrandbits(40)]) ^ (rnd.getrandbits(1) << 63), fmt, rm, 2)[0] if rnd.random() < 0.5 else a
        ins = R(0x18 << 2 | fmt, it, 1, 7 if dyn else rm, 5, 0x53); xd_res, flags = fm.f2i(a, fmt, erm, it)
    elif op == 'i2f':
        it = rnd.randrange(4); ins = R(0x1a << 2 | fmt, it, 6, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.i2f(xi, fmt, erm, it)
    elif op == 'f2f':
        src = 1 - fmt; a = operand(src)
        ins = R(0x08 << 2 | fmt, src, 1, 7 if dyn else rm, 3, 0x53); fd_res, flags = fm.f2f(a, src, fmt, erm)
    else:
        ins = R(0x1c << 2 | fmt, 0, 1, 0, 5, 0x53); xd_res = ((a ^ 0xffffffff80000000) - 0xffffffff80000000) & M64 if not fmt and a >> 31 else a
        if fmt == 0: xd_res = a | (0xffffffff00000000 if a >> 31 else 0)
    uc.mem_write(0, ins.to_bytes(4, 'little'))
    box = lambda v: v if fmt else (v | 0xffffffff00000000)
    uc.reg_write(UC_RISCV_REG_F1, a if op == 'f2f' and fmt == 0 else (a | 0xffffffff00000000 if op == 'f2f' else box(a)))
    uc.reg_write(UC_RISCV_REG_F2, box(b)); uc.reg_write(UC_RISCV_REG_F4, box(c))
    uc.reg_write(UC_RISCV_REG_X6, xi)
    uc.reg_write(UC_RISCV_REG_FFLAGS, 0); uc.reg_write(UC_RISCV_REG_FRM, frm)
    uc.emu_start(0, 4, count=1)
    gotfl = uc.reg_read(UC_RISCV_REG_FFLAGS)
    if fd_res is not None:
        got = uc.reg_read(UC_RISCV_REG_F3); exp = fd_res
        if fmt == 0: got &= 0xffffffff
    else:
        got = uc.reg_read(UC_RISCV_REG_X5); exp = xd_res
    snan = lambda v: (fm.unpack(v, fmt)[0] == 'snan')
    if op == 'minmax' and (snan(a) or snan(b)):
        continue    # QEMU 5.0 implements the pre-2.2 minNum (sNaN -> NaN); the model follows F v2.2
    kk = [fm.unpack(v, fmt)[0] for v in (a, b, c)]
    if op == 'fma' and {kk[0], kk[1]} == {'inf', 'zero'} and kk[2] == 'qnan':
        continue    # spec: inf * 0 + qNaN raises NV; QEMU 5.0 does not
    if op == 'md': flags = gotfl          # integer ops: no flags
    if got != exp or gotfl != flags:
        bad += 1
        if bad <= 20:
            print('MISMATCH %-6s fmt %d rm %d a %x b %x c %x x %x : model %x/%02x unicorn %x/%02x' % (op, fmt, erm, a, b, c, xi, exp, flags, got, gotfl))
print('%d/%d FP ops: model == Unicorn (results and fflags)' % (N - bad, N))
