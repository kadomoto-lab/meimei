# FPU unit-test vectors from the reference model (fpmodel.py)
#   usage: fpu_vec.py N seed > vectors.txt
#   line: op fmt rm ityp a b c x expected flags   (op = fop_t index, values in hex, 64-bit registers)
import sys, random
sys.path.insert(0, '..')
import fpmodel as fm
from gen import SPEC_D, SPEC_S
M64 = (1 << 64) - 1
OPS = ['ADD', 'SUB', 'MUL', 'MADD', 'MSUB', 'NMSUB', 'NMADD', 'SGNJ', 'SGNJN', 'SGNJX', 'MIN', 'MAX',
       'FEQ', 'FLT', 'FLE', 'CLASS', 'MVXF', 'F2I', 'F2F', 'MVFX', 'I2F', 'DIV', 'SQRT']
N = int(sys.argv[1]); rnd = random.Random(int(sys.argv[2]))

def val(fmt):
    t = rnd.random()
    if fmt == 1:
        if t < 0.25: return rnd.choice(SPEC_D)
        if t < 0.75: return rnd.getrandbits(1) << 63 | (1023 + rnd.randint(-30, 30)) << 52 | rnd.getrandbits(52) & rnd.choice([M64, ~0xffffff & M64, 0xfff])
        if t < 0.85: return rnd.getrandbits(1) << 63 | rnd.choice([rnd.randint(0, 60), rnd.randint(1990, 2046)]) << 52 | rnd.getrandbits(52)
        return rnd.getrandbits(64)
    if t < 0.25: v = rnd.choice(SPEC_S)
    elif t < 0.75: v = rnd.getrandbits(1) << 31 | (127 + rnd.randint(-20, 20)) << 23 | rnd.getrandbits(23) & rnd.choice([0x7fffff, 0x7ff000, 0xf])
    elif t < 0.85: v = rnd.getrandbits(1) << 31 | rnd.choice([rnd.randint(0, 30), rnd.randint(225, 254)]) << 23 | rnd.getrandbits(23)
    else: v = rnd.getrandbits(32)
    return v | 0xffffffff00000000 if rnd.random() < 0.95 else rnd.getrandbits(64)

def ref(op, fmt, rm, it, a, b, c, x):
    """-> (register value, fflags)"""
    ua, ub, uc = fm.unbox(a, fmt), fm.unbox(b, fmt), fm.unbox(c, fmt)
    bx = lambda r: (fm.box(r[0], fmt), r[1])
    o = OPS[op]
    if o == 'ADD': return bx(fm.fma(ua, fm.ONE[fmt], ub, fmt, rm))
    if o == 'SUB': return bx(fm.fma(ua, fm.ONE[fmt], ub, fmt, rm, neg_c=True))
    if o == 'MUL': return bx(fm.fma(ua, ub, 0, fmt, rm, no_c=True))
    if o in ('MADD', 'MSUB', 'NMSUB', 'NMADD'):
        return bx(fm.fma(ua, ub, uc, fmt, rm, neg_prod=o in ('NMSUB', 'NMADD'), neg_c=o in ('MSUB', 'NMADD')))
    if o.startswith('SGNJ'): return bx(fm.fsgnj(ua, ub, fmt, ['SGNJ', 'SGNJN', 'SGNJX'].index(o)))
    if o in ('MIN', 'MAX'): return bx(fm.fminmax(ua, ub, fmt, o == 'MAX'))
    if o in ('FEQ', 'FLT', 'FLE'): return fm.fcmp(ua, ub, fmt, {'FEQ': 2, 'FLT': 1, 'FLE': 0}[o])
    if o == 'CLASS': return fm.fclass(ua, fmt)
    if o == 'MVXF': return (a if fmt else ((a & 0xffffffff) | (0xffffffff00000000 if a >> 31 & 1 else 0))), 0
    if o == 'F2I': return fm.f2i(ua, fmt, rm, it)
    if o == 'F2F':
        src = 1 - fmt; r = fm.f2f(fm.unbox(a, src), src, fmt, rm); return fm.box(r[0], fmt), r[1]
    if o == 'MVFX': return (x if fmt else fm.box(x & 0xffffffff, 0)), 0
    if o == 'I2F': return bx(fm.i2f(x, fmt, rm, it))
    if o == 'DIV': return bx(fm.fdiv(ua, ub, fmt, rm))
    return bx(fm.fsqrt(ua, fmt, rm))

for _ in range(N):
    op = rnd.randrange(len(OPS)); fmt = rnd.getrandbits(1); rm = rnd.randrange(5); it = rnd.randrange(4)
    a, b, c = val(fmt), val(fmt), val(fmt)
    if OPS[op] == 'F2F': a = val(1 - fmt)
    if OPS[op] == 'SQRT' and rnd.random() < 0.7: a &= ~(1 << (63 if fmt else 31))
    if OPS[op] in ('MIN', 'MAX', 'FEQ', 'FLT', 'FLE') and rnd.random() < 0.2: b = a ^ (rnd.getrandbits(1) << (63 if fmt else 31))
    if OPS[op] in ('MUL', 'MADD', 'MSUB', 'NMSUB', 'NMADD') and rnd.random() < 0.3:   # subnormal x normal
        # (an unnormalized product; for FMA, an addend whose LSB is 1..5 bits below the product LSB)
        mw, ew = (52, 11) if fmt else (23, 8)
        bias = (1 << (ew - 1)) - 1
        ma = (rnd.randint(1, 7) if rnd.random() < 0.5 else rnd.getrandbits(rnd.randint(1, mw))) or 1
        ebf = rnd.randint(mw + 6, (1 << ew) - 2) if rnd.random() < 0.3 else rnd.randint(bias + mw + 6, (1 << ew) - 2)
        mb = (rnd.getrandbits(rnd.randint(0, mw)) >> rnd.randint(0, mw)) if rnd.random() < 0.5 else rnd.getrandbits(mw)
        ecf = ebf - mw - rnd.randint(1, 5) + 1 - bias      # c LSB = product LSB - (1..5)
        sub, big = ma, ebf << mw | mb
        a, b = (sub, big) if rnd.getrandbits(1) else (big, sub)
        a ^= rnd.getrandbits(1) << (mw + ew); b ^= rnd.getrandbits(1) << (mw + ew)
        if OPS[op] != 'MUL' and 1 <= ecf <= (1 << ew) - 2 and rnd.random() < 0.7:
            c = fm.box(rnd.getrandbits(1) << (mw + ew) | ecf << mw | rnd.getrandbits(mw), fmt)
        a, b = fm.box(a, fmt), fm.box(b, fmt)
    if OPS[op] in ('MADD', 'MSUB', 'NMSUB', 'NMADD') and rnd.random() < 0.3:   # near-cancellation
        p = fm.fma(fm.unbox(a, fmt), fm.unbox(b, fmt), 0, fmt, rnd.randrange(5), no_c=True)[0] ^ rnd.getrandbits(2)
        c = fm.box(p ^ (1 << (63 if fmt else 31)) * rnd.getrandbits(1), fmt)
    if OPS[op] == 'F2F' and fmt == 0 and rnd.random() < 0.4:     # double -> single subnormal / near 2^emin
        m = rnd.choice([rnd.getrandbits(52), (1 << 52) - 1 - rnd.getrandbits(rnd.randint(0, 30))])
        a = rnd.getrandbits(1) << 63 | rnd.randint(1023 - 153, 1023 - 124) << 52 | m
    if OPS[op] == 'DIV' and rnd.random() < 0.4:                     # quotient around the subnormal range
        mw, ew = (52, 11) if fmt else (23, 8)
        bias = (1 << (ew - 1)) - 1
        k = rnd.randint(-2, mw + 3)                                  # result biased exponent about -k
        ea = rnd.randint(1, bias - 2); eb = ea + bias + k
        if eb > (1 << ew) - 2: eb, ea = (1 << ew) - 2, (1 << ew) - 2 - bias - k
        mf = lambda: rnd.choice([rnd.getrandbits(mw), (1 << mw) - 1 - rnd.getrandbits(rnd.randint(0, mw // 2)), 0])
        a = fm.box(rnd.getrandbits(1) << (mw + ew) | ea << mw | mf(), fmt)
        b = fm.box(rnd.getrandbits(1) << (mw + ew) | eb << mw | mf(), fmt)
    if OPS[op] == 'F2I' and rnd.random() < 0.5:
        a = fm.box(fm.i2f(rnd.choice([1 << 31, (1 << 31) - 1, 1 << 63, (1 << 32) - 1, 1 << 32, rnd.getrandbits(rnd.randint(1, 64))]) ^ (rnd.getrandbits(1) << 63), fmt, rnd.randrange(5), 2)[0], fmt)
        if rnd.random() < 0.5: a = fm.box(fm.round_pack(rnd.getrandbits(1), rnd.randint(1, 64), -rnd.randint(0, 3), fmt, 0)[0], fmt)
    x = rnd.choice([0, 1, M64, 1 << 63, (1 << 63) - 1, 0xffffffff, 0x80000000, rnd.getrandbits(64), rnd.getrandbits(rnd.randint(1, 64))])
    print('%x %x %x %x %x %x %x %x %x %x' % ((op, fmt, rm, it, a, b, c, x) + ref(op, fmt, rm, it, a, b, c, x)))
