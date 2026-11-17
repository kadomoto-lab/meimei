# RVC (RV64C) expansion to the equivalent 32-bit instruction, and the inverse used by the
# program generator to compress instructions. expand() is the ISS decoder (cross-checked against
# Unicorn); compress() is checked by asserting expand(compress(x)) == x.
M32 = 0xffffffff

def _b(v, hi, lo): return (v >> lo) & ((1 << (hi - lo + 1)) - 1)
def _sx(v, b): v &= (1 << b) - 1; return v - (1 << b) if v >> (b - 1) else v
def _R(f7, rs2, rs1, f3, rd, op): return (f7 << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op) & M32
def _I(imm, rs1, f3, rd, op): return ((imm & 0xfff) << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op) & M32
def _S(imm, rs2, rs1, f3, op): imm &= 0xfff; return ((imm >> 5) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | (imm & 31) << 7 | op) & M32
def _B(imm, rs2, rs1, f3):
    imm &= 0x1fff
    return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3f) << 25 | rs2 << 20 | rs1 << 15 | f3 << 12 | ((imm >> 1) & 0xf) << 8 | ((imm >> 11) & 1) << 7 | 0x63) & M32
def _J(imm, rd):
    imm &= 0x1fffff
    return (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3ff) << 21 | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xff) << 12 | rd << 7 | 0x6f) & M32

ILLEGAL = 0


def expand(h):
    """16-bit RVC -> 32-bit instruction (0 for illegal / unsupported encodings)"""
    op, f3 = h & 3, _b(h, 15, 13)
    rd, rs2 = _b(h, 11, 7), _b(h, 6, 2)
    rdp, rs1p, rs2p = 8 + _b(h, 4, 2), 8 + _b(h, 9, 7), 8 + _b(h, 4, 2)
    imm6 = _sx(_b(h, 12, 12) << 5 | _b(h, 6, 2), 6)
    if op == 0:
        if f3 == 0:                                         # C.ADDI4SPN
            nz = _b(h, 12, 11) << 4 | _b(h, 10, 7) << 6 | _b(h, 6, 6) << 2 | _b(h, 5, 5) << 3
            return _I(nz, 2, 0, rdp, 0x13) if nz else ILLEGAL
        uw = _b(h, 12, 10) << 3 | _b(h, 6, 6) << 2 | _b(h, 5, 5) << 6       # LW / SW
        ud = _b(h, 12, 10) << 3 | _b(h, 6, 5) << 6                         # LD / SD / FLD / FSD
        if f3 == 1: return _I(ud, rs1p, 3, rdp, 0x07)        # C.FLD
        if f3 == 2: return _I(uw, rs1p, 2, rdp, 0x03)        # C.LW
        if f3 == 3: return _I(ud, rs1p, 3, rdp, 0x03)        # C.LD
        if f3 == 5: return _S(ud, rs2p, rs1p, 3, 0x27)       # C.FSD
        if f3 == 6: return _S(uw, rs2p, rs1p, 2, 0x23)       # C.SW
        if f3 == 7: return _S(ud, rs2p, rs1p, 3, 0x23)       # C.SD
        return ILLEGAL
    if op == 1:
        if f3 == 0: return _I(imm6, rd, 0, rd, 0x13)         # C.ADDI / C.NOP
        if f3 == 1: return _I(imm6, rd, 0, rd, 0x1b) if rd else ILLEGAL   # C.ADDIW
        if f3 == 2: return _I(imm6, 0, 0, rd, 0x13)          # C.LI
        if f3 == 3:
            if rd == 2:                                     # C.ADDI16SP
                nz = _sx(_b(h, 12, 12) << 9 | _b(h, 6, 6) << 4 | _b(h, 5, 5) << 6 | _b(h, 4, 3) << 7 | _b(h, 2, 2) << 5, 10)
                return _I(nz, 2, 0, 2, 0x13) if nz else ILLEGAL
            if imm6 == 0: return ILLEGAL
            return ((imm6 & 0xfffff) << 12 | rd << 7 | 0x37) & M32   # C.LUI
        if f3 == 4:
            f2 = _b(h, 11, 10)
            sh = _b(h, 12, 12) << 5 | _b(h, 6, 2)
            if f2 == 0: return _I(sh, rs1p, 5, rs1p, 0x13)          # C.SRLI
            if f2 == 1: return _I(0x400 | sh, rs1p, 5, rs1p, 0x13)  # C.SRAI
            if f2 == 2: return _I(imm6, rs1p, 7, rs1p, 0x13)        # C.ANDI
            f = _b(h, 6, 5)
            if _b(h, 12, 12) == 0:
                return [_R(0x20, rs2p, rs1p, 0, rs1p, 0x33), _R(0, rs2p, rs1p, 4, rs1p, 0x33),
                        _R(0, rs2p, rs1p, 6, rs1p, 0x33), _R(0, rs2p, rs1p, 7, rs1p, 0x33)][f]
            if f == 0: return _R(0x20, rs2p, rs1p, 0, rs1p, 0x3b)   # C.SUBW
            if f == 1: return _R(0, rs2p, rs1p, 0, rs1p, 0x3b)      # C.ADDW
            return ILLEGAL
        if f3 == 5:                                         # C.J
            off = _sx(_b(h, 12, 12) << 11 | _b(h, 11, 11) << 4 | _b(h, 10, 9) << 8 | _b(h, 8, 8) << 10 |
                      _b(h, 7, 7) << 6 | _b(h, 6, 6) << 7 | _b(h, 5, 3) << 1 | _b(h, 2, 2) << 5, 12)
            return _J(off, 0)
        off = _sx(_b(h, 12, 12) << 8 | _b(h, 11, 10) << 3 | _b(h, 6, 5) << 6 | _b(h, 4, 3) << 1 | _b(h, 2, 2) << 5, 9)
        return _B(off, 0, rs1p, 0 if f3 == 6 else 1)          # C.BEQZ / C.BNEZ
    if op == 2:
        sh = _b(h, 12, 12) << 5 | _b(h, 6, 2)
        if f3 == 0: return _I(sh, rd, 1, rd, 0x13)           # C.SLLI
        ldsp = _b(h, 12, 12) << 5 | _b(h, 6, 5) << 3 | _b(h, 4, 2) << 6
        lwsp = _b(h, 12, 12) << 5 | _b(h, 6, 4) << 2 | _b(h, 3, 2) << 6
        if f3 == 1: return _I(ldsp, 2, 3, rd, 0x07)          # C.FLDSP
        if f3 == 2: return _I(lwsp, 2, 2, rd, 0x03) if rd else ILLEGAL   # C.LWSP
        if f3 == 3: return _I(ldsp, 2, 3, rd, 0x03) if rd else ILLEGAL   # C.LDSP
        if f3 == 4:
            if _b(h, 12, 12) == 0:
                if rs2 == 0: return _I(0, rd, 0, 0, 0x67) if rd else ILLEGAL   # C.JR
                return _R(0, rs2, 0, 0, rd, 0x33)            # C.MV
            if rs2 == 0:
                return _I(0, rd, 0, 1, 0x67) if rd else 0x00100073           # C.JALR / C.EBREAK
            return _R(0, rs2, rd, 0, rd, 0x33)               # C.ADD
        sdsp = _b(h, 12, 10) << 3 | _b(h, 9, 7) << 6
        swsp = _b(h, 12, 9) << 2 | _b(h, 8, 7) << 6
        if f3 == 5: return _S(sdsp, rs2, 2, 3, 0x27)         # C.FSDSP
        if f3 == 6: return _S(swsp, rs2, 2, 2, 0x23)         # C.SWSP
        return _S(sdsp, rs2, 2, 3, 0x23)                     # C.SDSP
    return ILLEGAL


def _cb(f3, op, bits):    # bits: dict {bit position in halfword: value}
    h = f3 << 13 | op
    for pos, v in bits: h |= v << pos
    return h


def compress(w, off=None):
    """32-bit instruction -> 16-bit encoding, or None. Branches / JAL use the final byte offset `off`."""
    op = w & 0x7f; rd = _b(w, 11, 7); f3 = _b(w, 14, 12); rs1 = _b(w, 19, 15); rs2 = _b(w, 24, 20); f7 = w >> 25
    ii = _sx(w >> 20, 12)
    p = lambda r: 8 <= r <= 15
    c = None
    def fit(v, bits): return -(1 << (bits - 1)) <= v < (1 << (bits - 1))
    if op == 0x13 and f3 == 0:
        if rd and rd == rs1 and ii and fit(ii, 6): c = 1 | (ii >> 5 & 1) << 12 | rd << 7 | (ii & 31) << 2
        elif rd and rs1 == 0 and fit(ii, 6): c = 1 | 2 << 13 | (ii >> 5 & 1) << 12 | rd << 7 | (ii & 31) << 2
        elif rd == 2 and rs1 == 2 and ii and ii % 16 == 0 and fit(ii, 10):
            v = ii & 0x3ff
            c = 1 | 3 << 13 | (v >> 9 & 1) << 12 | 2 << 7 | (v >> 4 & 1) << 6 | (v >> 6 & 1) << 5 | (v >> 7 & 3) << 3 | (v >> 5 & 1) << 2
        elif p(rd) and rs1 == 2 and ii > 0 and ii % 4 == 0 and ii < 1024:
            c = 0 | (ii >> 4 & 3) << 11 | (ii >> 6 & 15) << 7 | (ii >> 2 & 1) << 6 | (ii >> 3 & 1) << 5 | (rd - 8) << 2
    elif op == 0x1b and f3 == 0 and rd and rd == rs1 and fit(ii, 6):
        c = 1 | 1 << 13 | (ii >> 5 & 1) << 12 | rd << 7 | (ii & 31) << 2
    elif op == 0x37 and rd not in (0, 2):
        imm = _sx(w >> 12, 20)
        if imm and fit(imm, 6): c = 1 | 3 << 13 | (imm >> 5 & 1) << 12 | rd << 7 | (imm & 31) << 2
    elif op == 0x13 and f3 == 1 and rd and rd == rs1 and f7 >> 1 == 0 and (w >> 20) & 63:
        sh = (w >> 20) & 63; c = 2 | (sh >> 5) << 12 | rd << 7 | (sh & 31) << 2
    elif op == 0x13 and f3 == 5 and p(rd) and rd == rs1 and (w >> 20) & 63 and (w >> 26) in (0, 0x10):
        sh = (w >> 20) & 63; c = 1 | 4 << 13 | (sh >> 5) << 12 | (1 if w >> 30 & 1 else 0) << 10 | (rd - 8) << 7 | (sh & 31) << 2
    elif op == 0x13 and f3 == 7 and p(rd) and rd == rs1 and fit(ii, 6):
        c = 1 | 4 << 13 | (ii >> 5 & 1) << 12 | 2 << 10 | (rd - 8) << 7 | (ii & 31) << 2
    elif op == 0x33 and f3 == 0 and f7 == 0 and rd and rs2:
        if rs1 == 0: c = 2 | 4 << 13 | rd << 7 | rs2 << 2                      # C.MV
        elif rs1 == rd: c = 2 | 4 << 13 | 1 << 12 | rd << 7 | rs2 << 2          # C.ADD
    if c is None and op in (0x33, 0x3b) and p(rd) and rd == rs1 and p(rs2):
        sel = {(0x33, 0, 0x20): (0, 0), (0x33, 4, 0): (0, 1), (0x33, 6, 0): (0, 2), (0x33, 7, 0): (0, 3),
               (0x3b, 0, 0x20): (1, 0), (0x3b, 0, 0): (1, 1)}.get((op, f3, f7))
        if sel: c = 1 | 4 << 13 | sel[0] << 12 | 3 << 10 | (rd - 8) << 7 | sel[1] << 5 | (rs2 - 8) << 2
    if c is None and op in (0x03, 0x07, 0x23, 0x27):
        load = op in (0x03, 0x07); fp = op in (0x07, 0x27)
        imm = ii if load else _sx((w >> 25) << 5 | rd, 12)
        r = rd if load else rs2
        dw = f3 == 3; ok_w = f3 == 2 and not fp
        if dw or ok_w:
            if rs1 == 2 and (r or not load or fp):
                if dw and 0 <= imm < 512 and imm % 8 == 0:
                    if load: c = 2 | (1 if fp else 3) << 13 | (imm >> 5 & 1) << 12 | r << 7 | (imm >> 3 & 3) << 5 | (imm >> 6 & 7) << 2
                    else: c = 2 | (5 if fp else 7) << 13 | (imm >> 3 & 7) << 10 | (imm >> 6 & 7) << 7 | r << 2
                elif ok_w and 0 <= imm < 256 and imm % 4 == 0:
                    if load: c = 2 | 2 << 13 | (imm >> 5 & 1) << 12 | r << 7 | (imm >> 2 & 7) << 4 | (imm >> 6 & 3) << 2
                    else: c = 2 | 6 << 13 | (imm >> 2 & 15) << 9 | (imm >> 6 & 3) << 7 | r << 2
            elif p(rs1) and p(r):
                if dw and 0 <= imm < 256 and imm % 8 == 0:
                    f = (1 if fp else 3) if load else (5 if fp else 7)
                    c = f << 13 | (imm >> 3 & 7) << 10 | (rs1 - 8) << 7 | (imm >> 6 & 3) << 5 | (r - 8) << 2
                elif ok_w and 0 <= imm < 128 and imm % 4 == 0:
                    c = (2 if load else 6) << 13 | (imm >> 3 & 7) << 10 | (rs1 - 8) << 7 | (imm >> 2 & 1) << 6 | (imm >> 6 & 1) << 5 | (r - 8) << 2
    if c is None and op == 0x67 and ii == 0 and rs1 and rd in (0, 1):
        c = 2 | 4 << 13 | (rd << 12) | rs1 << 7                               # C.JR / C.JALR
    if c is None and op == 0x6f and rd == 0 and off is not None and fit(off, 12):
        v = off & 0xfff
        c = 1 | 5 << 13 | (v >> 11 & 1) << 12 | (v >> 4 & 1) << 11 | (v >> 8 & 3) << 9 | (v >> 10 & 1) << 8 | \
            (v >> 6 & 1) << 7 | (v >> 7 & 1) << 6 | (v >> 1 & 7) << 3 | (v >> 5 & 1) << 2
    if c is None and op == 0x63 and f3 in (0, 1) and rs2 == 0 and p(rs1) and off is not None and fit(off, 9):
        v = off & 0x1ff
        c = 1 | (6 + f3) << 13 | (v >> 8 & 1) << 12 | (v >> 3 & 3) << 10 | (rs1 - 8) << 7 | (v >> 6 & 3) << 5 | (v >> 1 & 3) << 3 | (v >> 5 & 1) << 2
    return c


def _reenc(w, off):
    """re-encode a 32-bit branch / JAL with a new byte offset"""
    op = w & 0x7f
    if op == 0x6f: return _J(off, _b(w, 11, 7))
    return _B(off, _b(w, 24, 20), _b(w, 19, 15), _b(w, 14, 12))


def _target(w, i):
    """instruction index targeted by the 32-bit branch / JAL at index i (4-byte layout)"""
    if (w & 0x7f) == 0x6f:
        imm = _sx(_b(w, 31, 31) << 20 | _b(w, 19, 12) << 12 | _b(w, 20, 20) << 11 | _b(w, 30, 21) << 1, 21)
    else:
        imm = _sx(_b(w, 31, 31) << 12 | _b(w, 7, 7) << 11 | _b(w, 30, 25) << 5 | _b(w, 11, 8) << 1, 13)
    return i + imm // 4


def compress_prog(words, rnd, prob=0.7, keep=(), abs_fix=()):
    """re-layout a 4-byte-per-instruction program with RVC instructions -> bytes.
       keep: indices that stay 32-bit; abs_fix: {index: target index} of ADDI rd, x0, <byte address>"""
    abs_fix = dict(abs_fix)
    keep = set(keep) | set(abs_fix)
    n = len(words)
    tgt = {}
    for i, w in enumerate(words):
        if (w & 0x7f) in (0x63, 0x6f) and w != 0x6f: tgt[i] = _target(w, i)
    want = [i not in keep and rnd.random() < prob for i in range(n)]
    small = [want[i] and (i in tgt or compress(words[i]) is not None) for i in range(n)]
    while True:
        addr = [0] * (n + 1)
        for i in range(n): addr[i + 1] = addr[i] + (2 if small[i] else 4)
        changed = False
        for i in tgt:
            if small[i] and compress(words[i], addr[tgt[i]] - addr[i]) is None:
                small[i] = False; changed = True
        if not changed: break
    out = bytearray()
    for i, w in enumerate(words):
        if i in tgt: w = _reenc(w, addr[tgt[i]] - addr[i])
        if i in abs_fix: w = (w & 0xfffff) | (addr[abs_fix[i]] & 0xfff) << 20
        if small[i]:
            h = compress(w, addr[tgt[i]] - addr[i] if i in tgt else None)
            assert expand(h) == w, (hex(w), hex(h), hex(expand(h)))
            out += h.to_bytes(2, 'little')
        else:
            out += w.to_bytes(4, 'little')
    return bytes(out)
