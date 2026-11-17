# Bit-exact IEEE-754 reference model for the RISC-V F/D extensions (RV64), used by the ISS.
# Every operation is computed exactly with Python integers and rounded once (no host floats),
# so the model is independent of the RTL datapath.
# Each operation returns (result, fflags); fflags bits: NV 0x10, DZ 0x08, OF 0x04, UF 0x02, NX 0x01.
# Underflow: tininess is detected after rounding (RISC-V), UF is raised only when inexact.
M64 = (1 << 64) - 1
FMT = {0: (8, 23), 1: (11, 52)}            # fmt 0 = S, 1 = D : (exponent bits, fraction bits)
RNE, RTZ, RDN, RUP, RMM = 0, 1, 2, 3, 4
NV, DZ, OF, UF, NX = 0x10, 0x08, 0x04, 0x02, 0x01
CNAN = {0: 0x7fc00000, 1: 0x7ff8000000000000}
ONE = {0: 0x3f800000, 1: 0x3ff0000000000000}
BOX = 0xffffffff00000000


NOBOX = False      # cross-check against QEMU 5.0 (Unicorn), which predates NaN-boxing


def unbox(x, fmt):
    """register value -> encoding of the operand (S: NaN-boxing check)"""
    if fmt == 1: return x & M64
    if NOBOX: return x & 0xffffffff
    return x & 0xffffffff if (x >> 32) == 0xffffffff else CNAN[0]


def box(v, fmt): return v if fmt == 1 else (v & 0xffffffff if NOBOX else v | BOX)


def unpack(v, fmt):
    """-> (kind, sign, M, E): value = M * 2^E for kind 'num'; kind in num/zero/inf/qnan/snan"""
    ew, mw = FMT[fmt]
    s = v >> (ew + mw) & 1
    e = v >> mw & ((1 << ew) - 1)
    f = v & ((1 << mw) - 1)
    bias = (1 << (ew - 1)) - 1
    if e == (1 << ew) - 1:
        if f == 0: return ('inf', s, 0, 0)
        return ('qnan' if f >> (mw - 1) else 'snan', s, 0, 0)
    if e == 0:
        if f == 0: return ('zero', s, 0, 0)
        return ('num', s, f, 1 - bias - mw)
    return ('num', s, f | (1 << mw), e - bias - mw)


def isnan(k): return k[0] in ('qnan', 'snan')
def issnan(k): return k[0] == 'snan'


def pack_inf(s, fmt): ew, mw = FMT[fmt]; return s << (ew + mw) | ((1 << ew) - 1) << mw
def pack_zero(s, fmt): ew, mw = FMT[fmt]; return s << (ew + mw)


def _round_int(kept, rem, half, sticky, s, rm):
    """round kept + rem/2^k (+ sticky eps) to an integer, half = 2^(k-1) -> (int, inexact)"""
    gt = rem > half or (rem == half and sticky)
    eq = rem == half and not sticky
    nz = rem != 0 or sticky
    if rm == RNE: up = gt or (eq and (kept & 1))
    elif rm == RTZ: up = False
    elif rm == RDN: up = s and nz
    elif rm == RUP: up = (not s) and nz
    else: up = gt or eq
    return kept + int(up), nz


def round_pack(s, M, E, fmt, rm, sticky=False):
    """round sign * (M + sticky*eps) * 2^E (M > 0) to fmt -> (encoding, flags)"""
    ew, mw = FMT[fmt]
    P = mw + 1
    bias = (1 << (ew - 1)) - 1
    emax = (1 << ew) - 1
    if M.bit_length() < P + 3:              # guarantee round and sticky positions inside M
        k = P + 3 - M.bit_length()
        M <<= k; E -= k
    n = M.bit_length()
    biased = E + n - 1 + bias
    # tininess after rounding: round to P bits with an unbounded exponent range
    sh = n - P
    kn, _ = _round_int(M >> sh, M & ((1 << sh) - 1), 1 << (sh - 1), sticky, s, rm)
    tiny = biased + (1 if kn >> P else 0) < 1
    # actual rounding (denormalized below the normal range)
    shift = sh if biased >= 1 else sh + (1 - biased)
    if shift > n + 2: shift = n + 2       # everything below the rounding position
    kept, inexact = _round_int(M >> shift, M & ((1 << shift) - 1), 1 << (shift - 1), sticky, s, rm)
    if biased >= 1: packed = (biased << mw) + kept - (1 << mw)
    else: packed = kept
    fl = NX if inexact else 0
    if tiny and inexact: fl |= UF
    if packed >> mw >= emax:               # overflow
        fl = OF | NX
        if rm == RTZ or (rm == RDN and not s) or (rm == RUP and s):
            packed = (emax - 1) << mw | ((1 << mw) - 1)
        else:
            packed = emax << mw
    return s << (ew + mw) | packed, fl


def exact_zero_sign(sa, sb, rm):
    return sa if sa == sb else int(rm == RDN)


# ---------------------------------------------------------------------------------------------
def fma(a, b, c, fmt, rm, neg_prod=False, neg_c=False, no_c=False):
    ka, kb, kc = unpack(a, fmt), unpack(b, fmt), unpack(c, fmt)
    pinf = ka[0] == 'inf' or kb[0] == 'inf'
    pzero = ka[0] == 'zero' or kb[0] == 'zero'
    snan = issnan(ka) or issnan(kb) or (not no_c and issnan(kc))
    if pinf and pzero: return CNAN[fmt], NV          # also when c is a quiet NaN
    if isnan(ka) or isnan(kb) or (not no_c and isnan(kc)): return CNAN[fmt], NV if snan else 0
    sp = ka[1] ^ kb[1] ^ int(neg_prod)
    sc = kc[1] ^ int(neg_c)
    if pinf:
        if not no_c and kc[0] == 'inf' and sc != sp: return CNAN[fmt], NV
        return pack_inf(sp, fmt), 0
    if not no_c and kc[0] == 'inf': return pack_inf(sc, fmt), 0
    if pzero:
        if no_c: return pack_zero(sp, fmt), 0
        if kc[0] == 'zero': return pack_zero(exact_zero_sign(sp, sc, rm), fmt), 0
        return round_pack(sc, kc[2], kc[3], fmt, rm)
    Mp, Ep = ka[2] * kb[2], ka[3] + kb[3]
    if no_c or kc[0] == 'zero': return round_pack(sp, Mp, Ep, fmt, rm)
    Mc, Ec = kc[2], kc[3]
    e0 = min(Ep, Ec)
    S = (-1 if sp else 1) * (Mp << (Ep - e0)) + (-1 if sc else 1) * (Mc << (Ec - e0))
    if S == 0: return pack_zero(int(rm == RDN), fmt), 0
    return round_pack(int(S < 0), abs(S), e0, fmt, rm)


def fdiv(a, b, fmt, rm):
    ka, kb = unpack(a, fmt), unpack(b, fmt)
    if isnan(ka) or isnan(kb): return CNAN[fmt], NV if (issnan(ka) or issnan(kb)) else 0
    s = ka[1] ^ kb[1]
    if ka[0] == 'inf':
        return (CNAN[fmt], NV) if kb[0] == 'inf' else (pack_inf(s, fmt), 0)
    if kb[0] == 'inf': return pack_zero(s, fmt), 0
    if kb[0] == 'zero':
        return (CNAN[fmt], NV) if ka[0] == 'zero' else (pack_inf(s, fmt), DZ)
    if ka[0] == 'zero': return pack_zero(s, fmt), 0
    K = 3 * (FMT[fmt][1] + 1) + 8
    q, r = divmod(ka[2] << K, kb[2])
    return round_pack(s, q, ka[3] - kb[3] - K, fmt, rm, sticky=r != 0)


def isqrt(n):
    x = 1 << ((n.bit_length() + 1) // 2)
    while True:
        y = (x + n // x) // 2
        if y >= x: return x
        x = y


def fsqrt(a, fmt, rm):
    ka = unpack(a, fmt)
    if isnan(ka): return CNAN[fmt], NV if issnan(ka) else 0
    if ka[0] == 'zero': return a, 0
    if ka[1]: return CNAN[fmt], NV
    if ka[0] == 'inf': return a, 0
    M, E = ka[2], ka[3]
    if E & 1: M <<= 1; E -= 1
    K = 2 * (FMT[fmt][1] + 1) + 8
    R = M << (2 * K)
    r = isqrt(R)
    return round_pack(0, r, E // 2 - K, fmt, rm, sticky=r * r != R)


def fsgnj(a, b, fmt, mode):
    ew, mw = FMT[fmt]; sb_ = ew + mw
    sa, sb = a >> sb_ & 1, b >> sb_ & 1
    s = sb if mode == 0 else (sb ^ 1 if mode == 1 else sa ^ sb)
    return (a & ~(1 << sb_)) | s << sb_, 0


def to_frac(k):
    from fractions import Fraction
    if k[0] == 'zero': return Fraction(0)
    if k[0] == 'inf': return Fraction(-1 if k[1] else 1) * (1 << 5000)
    v = Fraction(k[2]) * (Fraction(2) ** k[3])
    return -v if k[1] else v


def fminmax(a, b, fmt, is_max):
    ka, kb = unpack(a, fmt), unpack(b, fmt)
    fl = NV if (issnan(ka) or issnan(kb)) else 0
    if isnan(ka) and isnan(kb): return CNAN[fmt], fl
    if isnan(ka): return b, fl
    if isnan(kb): return a, fl
    if ka[0] == 'zero' and kb[0] == 'zero':
        sa = ka[1]
        if is_max: return (a if sa == 0 else b), 0
        return (a if sa == 1 else b), 0
    altb = to_frac(ka) < to_frac(kb)
    if is_max: return (b if altb else a), 0
    return (a if altb else b), 0


def fcmp(a, b, fmt, op):      # op 2: FEQ (quiet), 1: FLT, 0: FLE (signaling)
    ka, kb = unpack(a, fmt), unpack(b, fmt)
    if isnan(ka) or isnan(kb):
        return 0, NV if (op != 2 or issnan(ka) or issnan(kb)) else 0
    fa, fb = to_frac(ka), to_frac(kb)
    return (int(fa == fb) if op == 2 else (int(fa < fb) if op == 1 else int(fa <= fb))), 0


def fclass(a, fmt):
    k = unpack(a, fmt)
    ew, mw = FMT[fmt]
    sub = k[0] == 'num' and (a >> mw & ((1 << ew) - 1)) == 0
    s = k[1]
    if k[0] == 'inf': return 1 << (0 if s else 7), 0
    if k[0] == 'zero': return 1 << (3 if s else 4), 0
    if k[0] == 'snan': return 1 << 8, 0
    if k[0] == 'qnan': return 1 << 9, 0
    if sub: return 1 << (2 if s else 5), 0
    return 1 << (1 if s else 6), 0


def f2f(a, fmt_from, fmt_to, rm):
    k = unpack(a, fmt_from)
    if isnan(k): return CNAN[fmt_to], NV if issnan(k) else 0
    if k[0] == 'inf': return pack_inf(k[1], fmt_to), 0
    if k[0] == 'zero': return pack_zero(k[1], fmt_to), 0
    return round_pack(k[1], k[2], k[3], fmt_to, rm)


def f2i(a, fmt, rm, ityp):    # ityp 0: W, 1: WU, 2: L, 3: LU ; returns the 64-bit rd value
    k = unpack(a, fmt)
    bits = 32 if ityp < 2 else 64
    signed = ityp in (0, 2)
    imax = (1 << (bits - 1)) - 1 if signed else (1 << bits) - 1
    imin = -(1 << (bits - 1)) if signed else 0
    fl = 0
    if isnan(k): v, fl = imax, NV
    elif k[0] == 'inf': v, fl = (imin if k[1] else imax), NV
    elif k[0] == 'zero': v = 0
    else:
        M, E = k[2], k[3]
        s = k[1]
        if E >= 0: q, inexact = M << E, False
        else: q, inexact = _round_int(M >> -E, M & ((1 << -E) - 1), 1 << (-E - 1), False, s, rm)
        v = -q if s else q
        if v < imin or v > imax: v, fl = max(imin, min(imax, v)), NV
        elif inexact: fl = NX
    v &= (1 << bits) - 1
    if bits == 32 and v >> 31: v |= 0xffffffff00000000   # *.W / *.WU results are sign-extended
    return v, fl


def i2f(x, fmt, rm, ityp):
    x &= M64
    if ityp == 0: v = x & 0xffffffff; v = v - (1 << 32) if v >> 31 else v
    elif ityp == 1: v = x & 0xffffffff
    elif ityp == 2: v = x - (1 << 64) if x >> 63 else x
    else: v = x
    if v == 0: return pack_zero(0, fmt), 0
    return round_pack(int(v < 0), abs(v), 0, fmt, rm)
