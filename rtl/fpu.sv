// IEEE-754 binary32 / binary64 floating-point units for the RISC-V F and D extensions.
// Units and latencies:
//   fp_fma_unit : FADD/FSUB (FALU, 2 cycles), FMUL/FMADD/FMSUB/FNMSUB/FNMADD (FMUL, 3 cycles)
//   fp_misc     : FSGNJ*/FMIN/FMAX (FALU) and, with HAS_CVT, FEQ/FLT/FLE/FCLASS/FMV.X/FCVT f->i, f->f
//   fp_i2f      : FMV.W.X/FMV.D.X/FCVT f<-i (I2F, on an integer ALU)
//   fp_divsqrt  : FDIV/FSQRT, iterative (U quotient/root bits per cycle)
// The arithmetic is combinational; the pipelines in mm_core delay the result to the unit latency.
// Single-precision operands are NaN-boxed: an operand whose upper 32 bits are not all ones is
// the canonical NaN, and single-precision results are written with the upper 32 bits set.
// Every unit also returns the IEEE exception flags {NV, DZ, OF, UF, NX} (fflags bit order);
// underflow uses tininess after rounding and is raised only when the result is inexact.
// The dynamic rounding mode (rm = 7) is resolved from frm before the operation reaches the unit.

// ---------------------------------------------------------------------------------------------
// unpack: value = m * 2^e with m normalized (m[MW] = 1) also for subnormal inputs
// ---------------------------------------------------------------------------------------------
module fp_unpack
    import mm_pkg::*;
#(parameter int EW = 11, parameter int MW = 52) (
    input  logic [EW+MW:0]     x,
    output logic               sign, zero, inf, nan, snan,
    output logic signed [15:0] e,
    output logic [MW:0]        m
);
    localparam int BIAS = (1 << (EW - 1)) - 1;
    logic [EW-1:0] ef;
    logic [MW-1:0] f;
    assign sign = x[EW+MW];
    assign ef   = x[EW+MW-1:MW];
    assign f    = x[MW-1:0];
    assign zero = (ef == '0) && (f == '0);
    assign inf  = (ef == '1) && (f == '0);
    assign nan  = (ef == '1) && (f != '0);
    assign snan = nan && !f[MW-1];
    localparam int LW = $clog2(MW + 1);
    logic [LW-1:0] lz;
    mm_lzc #(.W(MW)) u_lz (.x(f), .cnt(lz));
    always_comb begin
        int hi, sh;
        hi = 0;
        for (int i = 0; i < MW; i++) if (f[i]) hi = i;
        // shift that brings the leading one of a subnormal to the hidden bit (f = 0: MW, as the loop gives)
        sh = FP_LZC_TREE ? ((f == '0) ? MW : int'(lz) + 1) : MW - hi;
        if (ef == '0) begin
            m = {1'b0, f} << sh;
            e = 16'(1 - BIAS - MW - sh);
        end else begin
            m = {1'b1, f};
            e = 16'(int'(ef) - BIAS - MW);
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------
// round: sign * sig * 2^(exp - (W-1)) -> EW/MW format. sig != 0; sig[0] may be a sticky (jam) bit,
// so the rounding position must be at bit 1 or above (W >= MW + 3 and enough leading bits).
// ---------------------------------------------------------------------------------------------
// normalization part of fp_round: leading-zero count, left shift, biased exponent of the leading one
module fp_round_norm
    import mm_pkg::*;
#(parameter int EW = 11, parameter int MW = 52, parameter int W = 64) (
    input  logic signed [15:0] exp,     // weight of sig[W-1]
    input  logic [W-1:0]       sig,
    output logic [W-1:0]       nrm,
    output logic signed [15:0] be
);
    localparam int BIAS = (1 << (EW - 1)) - 1;
    logic [$clog2(W + 1)-1:0] lzt;
    mm_lzc #(.W(W)) u_lz (.x(sig), .cnt(lzt));
    always_comb begin
        int lz;
        lz = 0;
        if (FP_LZC_TREE) lz = (sig == '0) ? 0 : int'(lzt);
        else for (int i = 0; i < W; i++) if (sig[i]) lz = W - 1 - i;
        nrm = sig << lz;
        be  = 16'(int'(exp) - lz + BIAS);
    end
endmodule

// rounding part of fp_round: denormalization, rounding to P bits, overflow / underflow flags
module fp_round_fin #(parameter int EW = 11, parameter int MW = 52, parameter int W = 64) (
    input  logic               sign,
    input  logic [W-1:0]       nrm,     // normalized (nrm[W-1] = 1) unless zero
    input  logic signed [15:0] be,      // biased exponent of nrm[W-1]
    input  logic [2:0]         rm,
    output logic [EW+MW:0]     res,
    output logic [4:0]         flags
);
    localparam int P    = MW + 1;
    localparam int EMAX = (1 << EW) - 1;
    always_comb begin
        int sh;
        logic [W-1:0] sft;
        logic [P-1:0] mant;
        logic rb, st, inc;
        logic [EW-1:0] ef;
        logic [EW+MW-1:0] pk;
        logic rbn, stn, incn, tiny, inexact, ovf;
        if (be >= 1) begin sh = 0;      ef = EW'(be); end
        else         begin sh = 1 - be; ef = '0;      end   // subnormal: denormalize
        if (sh >= W) sft = W'(nrm != '0);
        else         sft = (nrm >> sh) | W'((nrm & ~({W{1'b1}} << sh)) != '0);
        mant = sft[W-1 -: P];
        rb   = sft[W-1-P];
        st   = |sft[W-2-P:0];
        unique case (rm)
            3'd0:    inc = rb && (st || mant[0]);    // RNE
            3'd1:    inc = 1'b0;                     // RTZ
            3'd2:    inc = (rb || st) && sign;       // RDN
            3'd3:    inc = (rb || st) && !sign;      // RUP
            default: inc = rb;                       // RMM
        endcase
        pk = {ef, mant[P-2:0]} + (EW+MW)'(inc);     // a carry out of the fraction bumps the exponent
        // tininess after rounding: would rounding to P bits (unbounded exponent) reach 2^emin?
        rbn = nrm[W-1-P];
        stn = |nrm[W-2-P:0];
        unique case (rm)
            3'd0:    incn = rbn && (stn || nrm[W-P]);
            3'd1:    incn = 1'b0;
            3'd2:    incn = (rbn || stn) && sign;
            3'd3:    incn = (rbn || stn) && !sign;
            default: incn = rbn;
        endcase
        tiny    = (be < 0) || (be == 0 && !(incn && (&nrm[W-1 -: P])));
        inexact = rb || st;
        ovf     = (be >= EMAX) || (pk[EW+MW-1 -: EW] == '1);
        flags   = ovf ? 5'b00101 : {3'b000, tiny && inexact, inexact};
        if (be >= EMAX) begin                        // overflow before rounding
            if (rm == 3'd1 || (rm == 3'd2 && !sign) || (rm == 3'd3 && sign))
                res = {sign, EW'(EMAX - 1), {MW{1'b1}}};
            else
                res = {sign, EW'(EMAX), {MW{1'b0}}};
        end else begin
            res = {sign, pk};                        // rounding overflow gives the infinity encoding
        end
    end
endmodule

// rounding part for a significand normalized with an exponent limit: nrm[W-1] = 1 and
// be >= 1 (normal), or nrm[W-1] = 0 with nrm[W-1] weighing 2^emin (subnormal, be ignored)
module fp_round_fin_lim #(parameter int EW = 11, parameter int MW = 52, parameter int W = 64) (
    input  logic               sign,
    input  logic [W-1:0]       nrm,     // only nrm[W-1:W-2-P] are used
    input  logic               stk,     // |nrm[W-3-P:0], computed by the previous stage
    input  logic signed [15:0] be,      // biased exponent of nrm[W-1] (normal)
    input  logic [2:0]         rm,
    output logic [EW+MW:0]     res,
    output logic [4:0]         flags
);
    localparam int P    = MW + 1;
    localparam int EMAX = (1 << EW) - 1;
    always_comb begin
        logic [P-1:0] mant;
        logic rb, st, inc, sub;
        logic [EW-1:0] ef;
        logic [EW+MW-1:0] pk;
        logic rbn, stn, incn, tiny, inexact, ovf;
        sub  = !nrm[W-1];
        ef   = sub ? '0 : EW'(be);
        mant = nrm[W-1 -: P];
        rb   = nrm[W-1-P];
        st   = nrm[W-2-P] || stk;
        unique case (rm)
            3'd0:    inc = rb && (st || mant[0]);    // RNE
            3'd1:    inc = 1'b0;                     // RTZ
            3'd2:    inc = (rb || st) && sign;       // RDN
            3'd3:    inc = (rb || st) && !sign;      // RUP
            default: inc = rb;                       // RMM
        endcase
        pk = {ef, mant[P-2:0]} + (EW+MW)'(inc);
        // tininess after rounding: a subnormal whose value normalized by one more bit (nrm << 1) would
        // round up to 2^emin is not tiny
        rbn = nrm[W-2-P];
        stn = stk;
        unique case (rm)
            3'd0:    incn = rbn && (stn || nrm[W-1-P]);
            3'd1:    incn = 1'b0;
            3'd2:    incn = (rbn || stn) && sign;
            3'd3:    incn = (rbn || stn) && !sign;
            default: incn = rbn;
        endcase
        tiny    = sub && !(nrm[W-2] && incn && (&nrm[W-2 -: P]));
        inexact = rb || st;
        // rounding overflow: the exponent field becomes all ones only from EMAX - 1 with an all-ones
        // fraction that is incremented (same as pk's exponent field == '1, without its carry chain)
        ovf     = !sub && (be >= EMAX || (be == EMAX - 1 && (&mant[P-2:0]) && inc));
        flags   = ovf ? 5'b00101 : {3'b000, tiny && inexact, inexact};
        if (!sub && be >= EMAX) begin
            if (rm == 3'd1 || (rm == 3'd2 && !sign) || (rm == 3'd3 && sign))
                res = {sign, EW'(EMAX - 1), {MW{1'b1}}};
            else
                res = {sign, EW'(EMAX), {MW{1'b0}}};
        end else begin
            res = {sign, pk};
        end
    end
endmodule

// denormalization in front of fp_round_fin_lim: a normalized significand (nrm[W-1] = 1) with be < 1 is shifted
// right by 1 - be with a sticky bit, so that nrm[W-1] weighs 2^emin; fp_round_fin_lim then rounds it without a shift
module fp_round_den #(parameter int EW = 11, parameter int MW = 52, parameter int W = 64) (
    input  logic [W-1:0]       nrm,
    input  logic signed [15:0] be,
    output logic [W-1:0]       dnr,
    output logic               stk      // |dnr[W-3-P:0]
);
    localparam int P = MW + 1;
    always_comb begin
        int sh;
        sh = (be >= 1) ? 0 : 1 - be;
        if (sh >= W) dnr = W'(nrm != '0);
        else         dnr = (nrm >> sh) | W'((nrm & ~({W{1'b1}} << sh)) != '0);
        stk = |dnr[W-3-P:0];
    end
endmodule

module fp_round #(parameter int EW = 11, parameter int MW = 52, parameter int W = 64) (
    input  logic               sign,
    input  logic signed [15:0] exp,     // weight of sig[W-1]
    input  logic [W-1:0]       sig,
    input  logic [2:0]         rm,
    output logic [EW+MW:0]     res,
    output logic [4:0]         flags
);
    logic [W-1:0] nrm;
    logic signed [15:0] be;
    fp_round_norm #(EW, MW, W) u_n (.exp, .sig, .nrm, .be);
    fp_round_fin  #(EW, MW, W) u_f (.sign, .nrm, .be, .rm, .res, .flags);
endmodule

// ---------------------------------------------------------------------------------------------
// fused multiply-add: (-1)^neg_p * a * b + (-1)^neg_c * c   (no_c: a * b only), one rounding
// The exact sum is formed in an F-bit field whose bit 0 is a sticky bit: a term that does not fit
// is shifted right with the shifted-out bits ORed into bit 0. F = 2P + 8 keeps the rounding
// position above bit 1 whenever a term has been shifted.
// ---------------------------------------------------------------------------------------------
module fp_fma #(parameter int EW = 11, parameter int MW = 52) (
    input  logic [EW+MW:0] a, b, c,
    input  logic           neg_p, neg_c, no_c,
    input  logic [2:0]     rm,
    output logic [EW+MW:0] res,
    output logic [4:0]     flags
);
    localparam int P = MW + 1;
    localparam int F = 2 * P + 8;
    localparam logic [EW+MW:0] CNAN = {1'b0, {EW{1'b1}}, 1'b1, {(MW-1){1'b0}}};
    localparam logic [EW+MW-1:0] INF = {{EW{1'b1}}, {MW{1'b0}}};

    logic sa, za, ia, na, sna, sb, zb, ib, nb, snb, sc, zc, ic, nc, snc;
    logic signed [15:0] ea, eb, ec;
    logic [MW:0] ma, mb, mc;
    fp_unpack #(EW, MW) ua (.x(a), .sign(sa), .zero(za), .inf(ia), .nan(na), .snan(sna), .e(ea), .m(ma));
    fp_unpack #(EW, MW) ub (.x(b), .sign(sb), .zero(zb), .inf(ib), .nan(nb), .snan(snb), .e(eb), .m(mb));
    fp_unpack #(EW, MW) uc (.x(c), .sign(sc), .zero(zc), .inf(ic), .nan(nc), .snan(snc), .e(ec), .m(mc));

    function automatic logic [F-1:0] place(logic [F-1:0] m, int pos);   // LSB of m to bit pos
        logic [F-1:0] t;
        int k;
        if (pos >= 1) return m << pos;
        t = m << 1;
        k = 1 - pos;
        if (k >= F) return F'(t != '0);
        return (t >> k) | F'((t & ~({F{1'b1}} << k)) != '0);
    endfunction

    logic sp, scc, pv, cv;
    logic [2*P-1:0] mp;
    logic [F-1:0] xp, xc, mag;
    logic sgn;
    logic signed [15:0] top;
    always_comb begin
        int tp, tc, t;
        sp  = sa ^ sb ^ neg_p;
        scc = sc ^ neg_c;
        pv  = !(za || zb);
        cv  = !no_c && !zc;
        mp  = ma * mb;
        tp  = int'(ea) + int'(eb) + 2 * P;      // product < 2^tp
        tc  = int'(ec) + P;                     // addend  < 2^tc
        t   = ((pv && (!cv || tp >= tc)) ? tp : tc) + 1;
        xp  = pv ? place(F'(mp), int'(ea) + int'(eb) - (t - F)) : '0;
        xc  = cv ? place(F'(mc), int'(ec) - (t - F)) : '0;
        if (sp == scc)    begin mag = xp + xc; sgn = sp;  end
        else if (xp >= xc) begin mag = xp - xc; sgn = sp;  end
        else              begin mag = xc - xp; sgn = scc; end
        top = 16'(t - 1);
    end

    logic [EW+MW:0] rounded;
    logic [4:0]     rflags;
    fp_round #(EW, MW, F) u_rnd (.sign(sgn), .exp(top), .sig(mag), .rm, .res(rounded), .flags(rflags));

    always_comb begin
        logic pinf, pzero, snan;
        pinf  = ia || ib;
        pzero = za || zb;
        snan  = sna || snb || (!no_c && snc);
        flags = '0;
        if (pinf && pzero)                         begin res = CNAN; flags = 5'h10; end   // even if c is a qNaN
        else if (na || nb || (!no_c && nc))        begin res = CNAN; flags = snan ? 5'h10 : '0; end
        else if (pinf && !no_c && ic && sp != scc) begin res = CNAN; flags = 5'h10; end
        else if (pinf)                                  res = {sp, INF};
        else if (!no_c && ic)                           res = {scc, INF};
        else if (!pv && !cv)                            res = {no_c ? sp : (sp == scc ? sp : rm == 3'd2), {(EW+MW){1'b0}}};
        else if (mag == '0)                             res = {rm == 3'd2, {(EW+MW){1'b0}}};
        else                                       begin res = rounded; flags = rflags; end
    end
endmodule

// ---------------------------------------------------------------------------------------------
// FMA unit: S and D datapaths, NaN-boxing, operation decode
// ---------------------------------------------------------------------------------------------
module fp_fma_unit
    import mm_pkg::*;
(
    input  fop_t        fop,
    input  logic        fmt,      // 0: S, 1: D
    input  logic [2:0]  rm,
    input  logic [63:0] a, b, c,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    logic [31:0] as, bs, cs, xs, ys, zs, rs;
    logic [4:0]  fs, fd;
    logic [63:0] xd, yd, zd, rd;
    logic np, nc, noc;
    assign as = (a[63:32] == '1) ? a[31:0] : 32'h7fc00000;
    assign bs = (b[63:32] == '1) ? b[31:0] : 32'h7fc00000;
    assign cs = (c[63:32] == '1) ? c[31:0] : 32'h7fc00000;
    always_comb begin
        xs = as; ys = bs; zs = cs; xd = a; yd = b; zd = c;
        np = 1'b0; nc = 1'b0; noc = 1'b0;
        unique case (fop)
            FOP_ADD, FOP_SUB: begin   // a * 1.0 + (+-b)
                ys = 32'h3f800000; zs = bs; yd = 64'h3ff0000000000000; zd = b;
                nc = (fop == FOP_SUB);
            end
            FOP_MUL:   noc = 1'b1;
            FOP_MSUB:  nc = 1'b1;
            FOP_NMSUB: np = 1'b1;
            FOP_NMADD: begin np = 1'b1; nc = 1'b1; end
            default: ;
        endcase
    end
    fp_fma #(8, 23)  u_s (.a(xs), .b(ys), .c(zs), .neg_p(np), .neg_c(nc), .no_c(noc), .rm, .res(rs), .flags(fs));
    fp_fma #(11, 52) u_d (.a(xd), .b(yd), .c(zd), .neg_p(np), .neg_c(nc), .no_c(noc), .rm, .res(rd), .flags(fd));
    assign res   = fmt ? rd : {32'hffffffff, rs};
    assign flags = fmt ? fd : fs;
endmodule

// ---------------------------------------------------------------------------------------------
// pipelined fused multiply-add (FMUL/FMADD... latency 3, FADD/FSUB latency 2)
//   A (EX1): unpack + product (registered for a 3-cycle op)
//   B      : alignment + addition (EX2 of a 3-cycle op; EX1 of a 2-cycle op, which skips the
//            multiplier: b = 1.0, so the product is the shifted a)
//   C      : normalization, rounding and special cases (EX3 / EX2), result valid in that cycle
// B and C are shared: two ops using them in the same cycle would also write the unit's single
// write port in the same cycle, which the issue queue never allows. Same arithmetic as fp_fma.
// ---------------------------------------------------------------------------------------------
module fp_fma_pipe #(parameter int EW = 11, parameter int MW = 52, parameter bit S4 = 1'b0, parameter bit AL = 1'b0,
                     parameter bit CS = 1'b0, parameter bit LS = 1'b0, parameter bit RX = 1'b0,
                     parameter bit RS = 1'b0) (
    input  logic           clk,
    input  logic           fma_start,   // EX1 holds a 3-cycle op
    input  logic           add_mode,    // EX1 holds a 2-cycle op (b must be 1.0)
    input  logic [EW+MW:0] a, b, c,
    input  logic [EW+MW:0] cadd,        // FADD/FSUB addend straight from the operand (not through the op's
    input  logic [EW+MW:0] a_raw, c_raw, // FADD/FSUB datapath operands: a / cadd before the NaN-boxing check
                                        // (an unboxed operand is a NaN, so the datapath result is unused)
    input  logic           sub_add,     // operand selection: FADD has its own operand path), FSUB
    input  logic           neg_p, neg_c, no_c,
    input  logic [2:0]     rm,
    output logic [EW+MW:0] res,
    output logic [4:0]     flags
);
    localparam int P = MW + 1;
    localparam int F = 2 * P + 8;
    localparam logic [EW+MW:0] CNAN = {1'b0, {EW{1'b1}}, 1'b1, {(MW-1){1'b0}}};
    localparam logic [EW+MW-1:0] INF = {{EW{1'b1}}, {MW{1'b0}}};
    // rows left after 3:2 carry-save levels (CS)
    function automatic int nxt(int n); return (n / 3) * 2 + (n % 3); endfunction
    function automatic int rows(int n, int l); for (int i = 0; i < l; i++) n = nxt(n); return n; endfunction
    function automatic int lev2(int n); int l; l = 0; while (n > 2) begin n = nxt(n); l++; end return l; endfunction

    typedef struct packed {
        logic               sp, scc, pv, cv, no_c;
        logic [2:0]         rm;
        logic               ia, ib, ic, za, zb, na, nb, nc, sna, snb, snc;
        logic signed [15:0] ea, eb, ec;
        logic [2*P-1:0]     mp;
        logic [MW:0]        mc;
    } sa_t;
    typedef struct packed {
        logic               sp, scc, pv, cv, no_c;
        logic [2:0]         rm;
        logic               ia, ib, ic, za, zb, na, nb, nc, sna, snb, snc;
        logic               sgn;
        logic signed [15:0] top;
        logic [F-1:0]       mag;
    } sb_t;

    // ---------------- A ----------------
    logic sa, za, ia, na, sna, sb, zb, ib, nb, snb, sc, zc, ic, nc, snc;
    logic signed [15:0] ea, eb, ec;
    logic [MW:0] ma, mb, mc;
    fp_unpack #(EW, MW) ua (.x(a), .sign(sa), .zero(za), .inf(ia), .nan(na), .snan(sna), .e(ea), .m(ma));
    fp_unpack #(EW, MW) ub (.x(b), .sign(sb), .zero(zb), .inf(ib), .nan(nb), .snan(snb), .e(eb), .m(mb));
    fp_unpack #(EW, MW) uc (.x(c), .sign(sc), .zero(zc), .inf(ic), .nan(nc), .snan(snc), .e(ec), .m(mc));

    // FADD path: operands are not normalized (a subnormal is m * 2^emin exactly; with the
    // alignment by exponent the sum is the same), which saves the leading-zero count + shift
    localparam int BIAS = (1 << (EW - 1)) - 1;
    logic signed [15:0] ea_r, eb_r, ec_r;
    logic [MW:0] ma_r, mb_r, mc_r;
    always_comb begin
        ma_r = {a[EW+MW-1:MW] != '0, a[MW-1:0]};
        mb_r = {b[EW+MW-1:MW] != '0, b[MW-1:0]};
        mc_r = {c[EW+MW-1:MW] != '0, c[MW-1:0]};
        ea_r = 16'((a[EW+MW-1:MW] == '0) ? 1 : int'(a[EW+MW-1:MW])) - 16'(BIAS + MW);
        eb_r = 16'((b[EW+MW-1:MW] == '0) ? 1 : int'(b[EW+MW-1:MW])) - 16'(BIAS + MW);
        ec_r = 16'((c[EW+MW-1:MW] == '0) ? 1 : int'(c[EW+MW-1:MW])) - 16'(BIAS + MW);
    end
    sa_t a_fma, a_add, a_q, a_b;
    logic a_sel;                        // B takes the registered 3-cycle op this cycle
    always_comb begin
        a_fma.sp   = sa ^ sb ^ neg_p;
        a_fma.scc  = sc ^ neg_c;
        a_fma.pv   = !(za || zb);
        a_fma.cv   = !no_c && !zc;
        a_fma.no_c = no_c;
        a_fma.rm   = rm;
        {a_fma.ia, a_fma.ib, a_fma.ic, a_fma.za, a_fma.zb} = {ia, ib, ic, za, zb};
        {a_fma.na, a_fma.nb, a_fma.nc, a_fma.sna, a_fma.snb, a_fma.snc} = {na, nb, nc, sna, snb, snc};
        a_fma.ea = ea; a_fma.eb = eb; a_fma.ec = ec;
        a_fma.mc = mc;
        a_fma.mp = (CS && AL) ? '0 : ma * mb;    // CS: the product is formed in carry-save rows
        a_add    = a_fma;
        a_add.mp = (2*P)'(ma_r) << MW;  // a * 1.0 without the multiplier
        a_add.ea = ea_r;
        a_add.ec = ec_r;
        a_add.mc = mc_r;
    end
    always_ff @(posedge clk) begin
        a_q   <= a_fma;
        a_sel <= fma_start;
    end
    assign a_b = a_q;

    // ---------------- B ----------------
    // The larger term goes to a fixed position (product LSB at F-2P-1, addend LSB at F-P-1), the
    // other one is shifted by the exponent difference d (one 16-bit subtraction). |xp - xc| is
    // formed from the two differences computed in parallel.
    localparam int SW = $clog2(F);
    function automatic logic [F-1:0] place(logic [F-1:0] m, logic signed [15:0] pos);  // LSB of m to bit pos (< F)
        logic [F-1:0] t;
        logic signed [15:0] k;
        if (pos >= 1) return m << pos[SW-1:0];
        t = m << 1;
        k = 16'sd1 - pos;
        if (k >= F) return F'(t != '0);
        return (t >> k[SW-1:0]) | F'((t & ~({F{1'b1}} << k[SW-1:0])) != '0);
    endfunction
    sb_t b_out, b_q;
    always_comb begin
        logic signed [15:0] tp, tc, d, posp, posc;
        logic [F-1:0] xp, xc;
        logic [F-1:0] spc;
        logic [F:0] dpc, dcp;
        logic big_p;
        b_out.sp = a_b.sp; b_out.scc = a_b.scc; b_out.pv = a_b.pv; b_out.cv = a_b.cv;
        b_out.no_c = a_b.no_c; b_out.rm = a_b.rm;
        {b_out.ia, b_out.ib, b_out.ic, b_out.za, b_out.zb} = {a_b.ia, a_b.ib, a_b.ic, a_b.za, a_b.zb};
        {b_out.na, b_out.nb, b_out.nc, b_out.sna, b_out.snb, b_out.snc} = {a_b.na, a_b.nb, a_b.nc, a_b.sna, a_b.snb, a_b.snc};
        tp    = a_b.ea + a_b.eb + 16'(2 * P);          // product < 2^tp
        tc    = a_b.ec + 16'(P);                       // addend  < 2^tc
        d     = tp - tc;
        big_p = a_b.pv && (!a_b.cv || d >= 0);
        posp  = big_p ? 16'(F - 2 * P - 1) : 16'(F - 2 * P - 1) + d;
        posc  = big_p ? 16'(F - P - 1) - d : 16'(F - P - 1);
        xp    = a_b.pv ? place(F'(a_b.mp), posp) : '0;
        xc    = a_b.cv ? place(F'(a_b.mc), posc) : '0;
        // the three results are computed in parallel (if synthesis shares one adder between them,
        // two 2P-bit carry chains end up in series)
        spc   = xp + xc;
        dpc   = {1'b0, xp} - {1'b0, xc};
        dcp   = {1'b0, xc} - {1'b0, xp};
        // AND-OR select (a ?: select lets synthesis share the adders, see above)
        b_out.mag = (spc & {F{a_b.sp == a_b.scc}}) | (dpc[F-1:0] & {F{a_b.sp != a_b.scc && !dpc[F]}}) |
                    (dcp[F-1:0] & {F{a_b.sp != a_b.scc && dpc[F]}});
        b_out.sgn = (a_b.sp == a_b.scc || !dpc[F]) ? a_b.sp : a_b.scc;
        b_out.top = big_p ? tp : tc;
    end

    // FADD/FSUB alignment + addition on a P+3-bit datapath (guard, round, sticky; an adder
    // separate from the FMA's): the result is placed at the top of the F-bit field for stage C
    localparam int N = P + 3;
    // x >> k with the shifted-out bits ORed into bit 0 (k < 0: unused result)
    function automatic logic [N-1:0] shr_sticky(logic [N-1:0] x, logic signed [15:0] k);
        if (k >= N) return N'(x != '0);
        return (x >> k[$clog2(N):0]) | N'((x & ~({N{1'b1}} << k[$clog2(N):0])) != '0);
    endfunction
    sb_t b_add;
    always_comb begin
        logic signed [15:0] d, d2;
        logic [N-1:0] xa, xc, xs, xb, xcs, xas;
        logic [N:0] sum, dbs, dsb;
        logic a_big, sb_, ss_;
        logic signed [15:0] eb;
        int k;
        b_add = '0;
        b_add.sp = a_add.sp; b_add.scc = a_add.scc; b_add.pv = a_add.pv; b_add.cv = a_add.cv;
        b_add.no_c = a_add.no_c; b_add.rm = a_add.rm;
        {b_add.ia, b_add.ib, b_add.ic, b_add.za, b_add.zb} = {a_add.ia, a_add.ib, a_add.ic, a_add.za, a_add.zb};
        {b_add.na, b_add.nb, b_add.nc, b_add.sna, b_add.snb, b_add.snc} = {a_add.na, a_add.nb, a_add.nc, a_add.sna, a_add.snb, a_add.snc};
        begin
            logic [MW:0] mca;
            logic signed [15:0] eca;
            logic spa, sca;
            logic [MW:0] maa;
            logic signed [15:0] eaa;
            logic [EW:0] ea1, ec1;
            maa = {a_raw[EW+MW-1:MW] != '0, a_raw[MW-1:0]};
            eaa = 16'((a_raw[EW+MW-1:MW] == '0) ? 1 : int'(a_raw[EW+MW-1:MW])) - 16'(BIAS + MW);
            mca = {c_raw[EW+MW-1:MW] != '0, c_raw[MW-1:0]};
            eca = 16'((c_raw[EW+MW-1:MW] == '0) ? 1 : int'(c_raw[EW+MW-1:MW])) - 16'(BIAS + MW);
            // RX: a subnormal f * 2^(1-bias) is taken as 2f * 2^(0-bias), so the exponent difference is that
            // of the raw fields (one narrow subtract with no zero test in front; the doubling is off that path)
            if (RX) begin
                maa = (a_raw[EW+MW-1:MW] == '0) ? {a_raw[MW-1:0], 1'b0} : {1'b1, a_raw[MW-1:0]};
                mca = (c_raw[EW+MW-1:MW] == '0) ? {c_raw[MW-1:0], 1'b0} : {1'b1, c_raw[MW-1:0]};
                eaa = 16'(int'(a_raw[EW+MW-1:MW])) - 16'(BIAS + MW);
                eca = 16'(int'(c_raw[EW+MW-1:MW])) - 16'(BIAS + MW);
            end
            ea1   = {1'b0, a_raw[EW+MW-1:MW]};
            ec1   = {1'b0, c_raw[EW+MW-1:MW]};
            spa = a_raw[EW+MW];                   // a * 1.0
            sca = c_raw[EW+MW] ^ sub_add;
            xa    = {maa, 3'b000};
            xc    = {mca, 3'b000};
            // both alignments are formed in parallel with the exponent compare and selected afterwards
            d     = RX ? 16'(signed'(ea1 - ec1)) : eaa - eca;
            d2    = RX ? 16'(signed'(ec1 - ea1)) : eca - eaa;
            a_big = !d[15];
            eb    = a_big ? eaa : eca;
            xb    = a_big ? xa : xc;              // term with the larger exponent
            xcs   = shr_sticky(xc, d);
            xas   = shr_sticky(xa, d2);
            xs    = a_big ? xcs : xas;
            sb_   = a_big ? spa : sca;            // signs of the larger / smaller term
            ss_   = a_big ? sca : spa;
        end
        sum   = {1'b0, xb} + {1'b0, xs};
        dbs   = {1'b0, xb} - {1'b0, xs};
        dsb   = {1'b0, xs} - {1'b0, xb};
        b_add.mag = {((sum & {(N+1){sb_ == ss_}}) | (dbs & {(N+1){sb_ != ss_ && !dbs[N]}}) |
                      (dsb & {(N+1){sb_ != ss_ && dbs[N]}})), (F-N-1)'(0)};
        b_add.sgn = (sb_ == ss_ || !dbs[N]) ? sb_ : ss_;
        b_add.top = eb + 16'(P);                   // weight of mag[F-1]
    end
    // special cases (NaN, infinity, exact zero) of the op in s, else the rounded value
    function automatic logic [EW+MW+5:0] finish(sb_t q, logic mz, logic [EW+MW:0] rounded, logic [4:0] rflags);
        logic pinf, pzero, snan;
        logic [EW+MW:0] r;
        logic [4:0] f;
        pinf  = q.ia || q.ib;
        pzero = q.za || q.zb;
        snan  = q.sna || q.snb || (!q.no_c && q.snc);
        f = '0;
        if (pinf && pzero)                                 begin r = CNAN; f = 5'h10; end
        else if (q.na || q.nb || (!q.no_c && q.nc))        begin r = CNAN; f = snan ? 5'h10 : '0; end
        else if (pinf && !q.no_c && q.ic && q.sp != q.scc) begin r = CNAN; f = 5'h10; end
        else if (pinf)                                          r = {q.sp, INF};
        else if (!q.no_c && q.ic)                               r = {q.scc, INF};
        else if (!q.pv && !q.cv)                                r = {q.no_c ? q.sp : (q.sp == q.scc ? q.sp : q.rm == 3'd2), {(EW+MW){1'b0}}};
        else if (mz)                                            r = {q.rm == 3'd2, {(EW+MW){1'b0}}};
        else                                               begin r = rounded; f = rflags; end
        return {r, f};
    endfunction

    if (!S4) begin : g_c3
        // ---------------- C (shared by both ops) ----------------
        always_ff @(posedge clk) b_q <= a_sel ? b_out : b_add;
        logic [EW+MW:0] rounded;
        logic [4:0]     rflags;
        fp_round #(EW, MW, F) u_rnd (.sign(b_q.sgn), .exp(b_q.top), .sig(b_q.mag), .rm(b_q.rm), .res(rounded), .flags(rflags));
        assign {res, flags} = finish(b_q, b_q.mag == '0, rounded, rflags);
    end else begin : g_c4
        // 4-stage FMA (normalization and rounding are separate stages):
        //   C1 (EX3): leading-zero count + left shift, C2 (EX4): denormalization, rounding, special cases
        // FADD/FSUB (latency 2) round in their own narrow path in EX2
        localparam int NA = P + 4;
        sb_t add_q;
        logic add_v;
        logic [NA-1:0]      add_lm, add_lmq;     // LS: one-hot left-shift limit of the FADD sum (from EX1)
        logic signed [15:0] add_tb, add_tbq;     //     biased exponent of mag[F-1]
        always_comb begin
            logic signed [15:0] kmax;
            add_tb = b_add.top + 16'(BIAS);
            kmax   = add_tb - 16'sd1;                // >= 1: the larger operand's LSB weight is >= 2^(emin-MW)
            add_lm = '0;
            if (kmax < NA) add_lm[NA - 1 - kmax] = 1'b1;
        end
        always_ff @(posedge clk) begin
            add_q <= b_add;
            add_v <= add_mode;
            add_lmq <= add_lm;
            add_tbq <= add_tb;
        end
        logic [EW+MW:0] r_fma, r_add;
        logic [4:0]     f_fma, f_add;
        logic [EW+MW+5:0] o_fma, o_add;
        if (!AL) begin : g_bplace
            // B: the larger term at a fixed position, the other shifted by the exponent difference
            always_ff @(posedge clk) b_q <= b_out;
            // C1
            typedef struct packed {
                sb_t                s;     // mag unused
                logic               mz;
                logic [F-1:0]       nrm;
                logic signed [15:0] be;
            } sc_t;
            sc_t c1, c_q;
            logic [F-1:0]       nrm1;
            logic signed [15:0] be1;
            fp_round_norm #(EW, MW, F) u_nrm (.exp(b_q.top), .sig(b_q.mag), .nrm(nrm1), .be(be1));
            always_comb begin
                c1     = '0;
                c1.s   = b_q;
                c1.s.mag = '0;
                c1.mz  = b_q.mag == '0;
                c1.nrm = nrm1;
                c1.be  = be1;
            end
            always_ff @(posedge clk) c_q <= c1;
            // C2
            fp_round_fin #(EW, MW, F) u_fin (.sign(c_q.s.sgn), .nrm(c_q.nrm), .be(c_q.be), .rm(c_q.s.rm), .res(r_fma), .flags(f_fma));
            assign o_fma = finish(c_q.s, c_q.mz, r_fma, f_fma);
        end else begin : g_balign
            // AL: the addend is aligned in A, in parallel with the multiplier; B only adds.
            // Field of W = 3P + 3 bits: the product at [2P+1:2] (bit k weighs 2^(ea+eb+k-2)), the addend
            // starts at [3P+2:2P+3] and is shifted right by s = 2P + 1 - (ec - ea - eb); bits shifted out
            // become a sticky bit at bit 0. If the addend is larger than that (s < 0) or the product is 0,
            // the addend stays at the top and the product only contributes a sticky bit (the field is then
            // weighted from the addend). The sum has W + 1 bits.
            // CS: the significands are not normalized (a subnormal is m * 2^emin), and the
            // product stays in carry-save form until B: A = Booth radix-4 partial products + 5 levels of 3:2
            // compression, B = the remaining levels + one level with the aligned addend + the adds. The
            // product LSB is then at bit 3 (W = 3P + 4): an unnormalized product
            // (subnormal x normal, top >= LSB + P - 1) minus a smaller addend can leave the result's
            // guard bit 2 positions below the product LSB, so the addend keeps those bits exactly.
            localparam int G  = CS ? 3 : 2;      // bit of the product LSB
            localparam int W  = 3 * P + 1 + G;
            localparam int FA = W + 1;
            typedef struct packed {
                logic               dom;     // addend dominates: product -> sticky
                logic [W-1:0]       cal;     // aligned addend
                logic               cst;     // sticky of the addend bits shifted out
                logic signed [15:0] top;     // weight of bit W of the sum
            } al_t;
            al_t al, al_q;
            always_comb begin
                logic signed [15:0] d, sh, eab, ecc;
                logic [W-1:0] ctop;
                ctop = CS ? {mc_r, (2 * P + 1 + G)'(0)} : {a_fma.mc, (2 * P + 1 + G)'(0)};
                eab  = CS ? ea_r + eb_r : a_fma.ea + a_fma.eb;
                ecc  = CS ? ec_r : a_fma.ec;
                d    = ecc - eab;
                sh   = 16'(2 * P + 1) - d;
                al   = '0;
                al.dom = a_fma.cv && (!a_fma.pv || sh < 0);
                if (a_fma.cv) begin
                    if (al.dom)       al.cal = ctop;
                    else if (sh >= W) al.cst = 1'b1;
                    else begin
                        al.cal = ctop >> sh;
                        al.cst = (ctop & ~({W{1'b1}} << sh)) != '0;
                    end
                end
                al.top = al.dom ? ecc + 16'(W - (2 * P + 1 + G)) : eab + 16'(W - G);
            end
            always_ff @(posedge clk) al_q <= al;

            // product: A gives either the binary product (a_b.mp) or carry-save rows (pr_q, CS)
            localparam int WR = W + 1 - G;       // row width: the rows are added modulo 2^(W+1) in the field
            localparam int NB = (P + 2) / 2;     // Booth digits of the P-bit unsigned multiplier
            localparam int R0 = NB + 2;          // + negation row + sign-extension constant
            localparam int LA = 5;               // 3:2 levels in A
            localparam int RA = rows(R0, LA);
            localparam int LB = lev2(RA);
            logic [RA-1:0][WR-1:0] pr_q;
            logic [1:0][WR-1:0]    pr_b;
            if (CS) begin : g_cs
                logic [R0-1:0][WR-1:0] pp;
                always_comb begin
                    logic [2*NB:0] be;
                    logic [P:0]    x, r;
                    logic [WR-1:0] k, nr;
                    logic [2:0]    dg;
                    logic          neg;
                    be = {(2*NB+1)'(mb_r), 1'b0};
                    k  = '0;
                    nr = '0;
                    for (int i = 0; i < NB; i++) begin
                        dg  = be[2*i +: 3];
                        neg = dg[2] && !(dg[1] && dg[0]);
                        unique case (dg)
                            3'b001, 3'b010, 3'b101, 3'b110: x = {1'b0, ma_r};
                            3'b011, 3'b100:                 x = {ma_r, 1'b0};
                            default:                        x = '0;
                        endcase
                        r     = neg ? ~x : x;                      // value: r - 2^(P+1) * neg (P+2-bit signed)
                        pp[i] = WR'({neg ? 1'b0 : 1'b1, r}) << (2 * i);
                        nr[2*i] = neg;
                        k     = k - (WR'(1) << (P + 1 + 2 * i));
                    end
                    pp[NB]     = nr;
                    pp[NB + 1] = k;
                end
                // A: LA levels
                logic [LA:0][R0-1:0][WR-1:0] la;
                assign la[0] = pp;
                for (genvar l = 0; l < LA; l++) begin : g_la
                    mm_csa_rows #(rows(R0, l), WR) u_c (.in(la[l][rows(R0, l)-1:0]), .out(la[l+1][rows(R0, l+1)-1:0]));
                end
                always_ff @(posedge clk) pr_q <= la[LA][RA-1:0];
                // B: the remaining levels down to two rows
                logic [LB:0][RA-1:0][WR-1:0] lb;
                assign lb[0] = pr_q;
                for (genvar l = 0; l < LB; l++) begin : g_lb
                    mm_csa_rows #(rows(RA, l), WR) u_c (.in(lb[l][rows(RA, l)-1:0]), .out(lb[l+1][rows(RA, l+1)-1:0]));
                end
                assign pr_b = lb[LB][1:0];
            end else begin : g_nocs
                assign pr_q = '0;
                assign pr_b = '0;
            end

            // B: product +- aligned addend (the sum and both differences in parallel, AND-OR select)
            typedef struct packed {
                sb_t            s;           // flags, sgn, top (mag unused)
                logic [FA-1:0]  mag;
                logic [FA-1:0]  lmask;       // LS: a one at bit FA-1-kmax (the left-shift limit)
                logic           kneg;        // LS: kmax < 0 (the value is below 2^(emin-P-1): sticky only)
                logic signed [15:0] tb;      // LS: biased exponent of bit FA-1
            } sn_t;
            sn_t bn, bn_q;
            always_comb begin
                logic [W-1:0] x, y;
                logic [W:0]   sum, dxy, dyx;
                logic         sub;
                y = al_q.cal | W'(al_q.cst);
                if (CS) begin
                    // x = xs + xc (mod 2^(W+1)); one 3:2 level with y (or ~y, or ~xs, ~xc) before each add
                    logic [W:0] xs, xc, ye, s0, c0, s1, c1, s2, c2;
                    xs = !a_b.pv ? '0 : al_q.dom ? (W+1)'(1'b1) : (W+1)'(pr_b[0]) << G;
                    xc = (!a_b.pv || al_q.dom) ? '0 : (W+1)'(pr_b[1]) << G;
                    ye = {1'b0, y};
                    s0 = xs ^ xc ^ ye;   c0 = ((xs & xc) | (xs & ye) | (xc & ye)) << 1;
                    s1 = xs ^ xc ^ ~ye;  c1 = (((xs & xc) | (xs & ~ye) | (xc & ~ye)) << 1) | (W+1)'(1);
                    s2 = ~xs ^ ~xc ^ ye; c2 = (((~xs & ~xc) | (~xs & ye) | (~xc & ye)) << 1) | (W+1)'(1);
                    sum = s0 + c0;
                    dxy = s1 + c1;                  // x - y = x + ~y + 1
                    dyx = s2 + c2 + (W+1)'(1);      // y - x = y + ~xs + ~xc + 2
                end else begin
                    x = !a_b.pv ? '0 : al_q.dom ? W'(a_b.mp != '0) : W'(a_b.mp) << 2;
                    sum = {1'b0, x} + {1'b0, y};
                    dxy = {1'b0, x} - {1'b0, y};
                    dyx = {1'b0, y} - {1'b0, x};
                end
                sub = a_b.sp != a_b.scc;
                bn.s = '0;
                bn.s.sp = a_b.sp; bn.s.scc = a_b.scc; bn.s.pv = a_b.pv; bn.s.cv = a_b.cv;
                bn.s.no_c = a_b.no_c; bn.s.rm = a_b.rm;
                {bn.s.ia, bn.s.ib, bn.s.ic, bn.s.za, bn.s.zb} = {a_b.ia, a_b.ib, a_b.ic, a_b.za, a_b.zb};
                {bn.s.na, bn.s.nb, bn.s.nc, bn.s.sna, bn.s.snb, bn.s.snc} = {a_b.na, a_b.nb, a_b.nc, a_b.sna, a_b.snb, a_b.snc};
                bn.mag = (sum & {(W+1){!sub}}) | (dxy & {(W+1){sub && !dxy[W]}}) | (dyx & {(W+1){sub && dxy[W]}});
                bn.s.sgn = (!sub || !dxy[W]) ? a_b.sp : a_b.scc;
                bn.s.top = al_q.top;
                // LS: the shift limit from the exponent, in parallel with the adds
                begin
                    logic signed [15:0] kmax;
                    bn.tb    = al_q.top + 16'(BIAS);
                    kmax     = bn.tb - 16'sd1;
                    bn.kneg  = kmax < 0;
                    bn.lmask = '0;
                    if (LS && kmax >= 0 && kmax < FA) bn.lmask[FA - 1 - kmax] = 1'b1;
                end
            end
            always_ff @(posedge clk) bn_q <= bn;
            // C1
            typedef struct packed {
                sb_t                s;
                logic               mz;
                logic [FA-1:0]      nrm;
                logic               stk;     // LS: |nrm[FA-3-P:0] (sticky below the round bit position)
                logic signed [15:0] be;
            } sc_t;
            sc_t c1, c_q;
            logic [FA-1:0]      nrm1;
            logic signed [15:0] be1;
            if (LS) begin : g_lsh
                // LS: the left shift stops at the subnormal boundary: k = min(lz, kmax) with
                // kmax = biased exponent of the field top - 1, as the leading-zero count of the sum ORed with a
                // one at bit FA-1-kmax (decoded in B). With W - G = 3P + 1, kmax < 0 (field top below 2^emin)
                // only when the whole value is below 2^(emin-P-1) (a product of tiny operands; an addend keeps
                // the top higher), so it leaves just a sticky bit. The sticky bit for C2 is also formed here.
                logic [$clog2(FA+1)-1:0] lz;
                mm_lzc #(FA) u_lzc (.x(bn_q.mag | bn_q.lmask), .cnt(lz));
                always_comb begin
                    if (bn_q.kneg) begin
                        nrm1 = FA'(bn_q.mag != '0);
                        be1  = 16'sd1;
                    end else begin
                        nrm1 = bn_q.mag << lz;
                        be1  = bn_q.tb - 16'(lz);
                    end
                end
            end else begin : g_nolsh
                fp_round_norm #(EW, MW, FA) u_nrm (.exp(bn_q.s.top), .sig(bn_q.mag), .nrm(nrm1), .be(be1));
            end
            always_comb begin
                c1     = '0;
                c1.s   = bn_q.s;
                c1.mz  = bn_q.mag == '0;
                c1.nrm = nrm1;
                c1.stk = |nrm1[FA-3-P:0];
                c1.be  = be1;
            end
            always_ff @(posedge clk) c_q <= c1;
            // C2
            if (LS) begin : g_finl
                fp_round_fin_lim #(EW, MW, FA) u_fin (.sign(c_q.s.sgn), .nrm(c_q.nrm), .stk(c_q.stk), .be(c_q.be), .rm(c_q.s.rm),
                                                      .res(r_fma), .flags(f_fma));
            end else begin : g_fin
                fp_round_fin #(EW, MW, FA) u_fin (.sign(c_q.s.sgn), .nrm(c_q.nrm), .be(c_q.be), .rm(c_q.s.rm), .res(r_fma), .flags(f_fma));
            end
            assign o_fma = finish(c_q.s, c_q.mz, r_fma, f_fma);
        end
        // FADD rounding on the P+3+1 significant bits at the top of the field
        if (LS && RS) begin : g_rsel
            // RS: the window is {carry, P-bit significand, guard, round, sticky} with the larger term's
            // leading one below the carry. With an exponent difference >= 2 at most one leading bit cancels
            // (shift 0..2); a longer shift needs a difference <= 1, where the smaller term moved by at most one
            // bit and the sticky bit is 0, so the shifted sum fits the significand. The three short shifts
            // are rounded in parallel with the leading-zero count (which also covers the subnormal limit)
            logic [NA-1:0]           aw, ax, an;
            logic [EW+MW:0]          r0, r1, r2, rx;
            logic [4:0]              f0, f1, f2;
            logic [$clog2(NA+1)-1:0] lz;
            logic signed [15:0]      abe;
            logic                    s0, s1, s2;
            assign aw = add_q.mag[F-1 -: NA];
            assign ax = aw | add_lmq;
            fp_round_fin_lim #(EW, MW, NA) u_r0 (.sign(add_q.sgn), .nrm(aw), .stk(|aw[NA-3-P:0]), .be(add_tbq),
                                                 .rm(add_q.rm), .res(r0), .flags(f0));
            fp_round_fin_lim #(EW, MW, NA) u_r1 (.sign(add_q.sgn), .nrm(aw << 1), .stk(|aw[NA-4-P:0]), .be(add_tbq - 16'sd1),
                                                 .rm(add_q.rm), .res(r1), .flags(f1));
            fp_round_fin_lim #(EW, MW, NA) u_r2 (.sign(add_q.sgn), .nrm(aw << 2), .stk(1'b0), .be(add_tbq - 16'sd2),
                                                 .rm(add_q.rm), .res(r2), .flags(f2));
            mm_lzc #(NA) u_lzc (.x(ax), .cnt(lz));
            assign an  = aw << lz;
            assign abe = add_tbq - 16'(lz);
            assign rx  = {add_q.sgn, an[NA-1] ? abe[EW-1:0] : EW'(0), an[NA-2 -: MW]};
            assign s0  = ax[NA-1];
            assign s1  = !ax[NA-1] && ax[NA-2];
            assign s2  = !ax[NA-1] && !ax[NA-2] && ax[NA-3];
            assign r_add = (r0 & {(EW+MW+1){s0}}) | (r1 & {(EW+MW+1){s1}}) | (r2 & {(EW+MW+1){s2}}) |
                           (rx & {(EW+MW+1){!(s0 || s1 || s2)}});
            assign f_add = (f0 & {5{s0}}) | (f1 & {5{s1}}) | (f2 & {5{s2}});
`ifndef SYNTHESIS
            // a shift of 3 or more must be exact
            always_ff @(posedge clk)
                if (add_v && !(s0 || s1 || s2) && aw != '0 && an[NA-2-MW:0] != '0)
                    $error("FADD_RSEL: inexact sum with a shift of %0d", lz);
`endif
        end else if (LS) begin : g_radl
            // the same exponent-limited normalization as the FMA (the subnormal is
            // produced directly): tree LZC of the sum ORed with the limit, left shift, rounding
            logic [$clog2(NA+1)-1:0] lz;
            logic [NA-1:0]           an;
            logic signed [15:0]      abe;
            mm_lzc #(NA) u_lzc (.x(add_q.mag[F-1 -: NA] | add_lmq), .cnt(lz));
            assign an  = add_q.mag[F-1 -: NA] << lz;
            assign abe = add_tbq - 16'(lz);
            fp_round_fin_lim #(EW, MW, NA) u_rad (.sign(add_q.sgn), .nrm(an), .stk(|an[NA-3-P:0]), .be(abe), .rm(add_q.rm),
                                                  .res(r_add), .flags(f_add));
        end else begin : g_rad
            fp_round #(EW, MW, NA) u_rad (.sign(add_q.sgn), .exp(add_q.top), .sig(add_q.mag[F-1 -: NA]), .rm(add_q.rm),
                                          .res(r_add), .flags(f_add));
        end
        assign o_add = finish(add_q, add_q.mag[F-1 -: NA] == '0, r_add, f_add);
        // an FADD in EX2 and an FMA in EX4 never meet: they would write the unit's port in the same cycle
        assign {res, flags} = add_v ? o_add : o_fma;
    end
endmodule

// S / D pipelined FMA with the operand set-up of fp_fma_unit. The result is valid in EX2 for
// FADD/FSUB (add_mode in EX1) and in EX3 (EX4 with FMA4) for FMUL / FMADD / FMSUB / FNMSUB / FNMADD
// (fma_start).
module fp_fma_unit_pipe
    import mm_pkg::*;
(
    input  logic        clk,
    input  logic        fma_start,
    input  logic        add_mode,
    input  fop_t        fop,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [63:0] a, b, c,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    logic [31:0] as, bs, cs, xs, ys, zs, rs;
    logic [4:0]  fs, fd;
    logic [63:0] xd, yd, zd, rd;
    logic np, nc, noc;
    assign as = (a[63:32] == '1) ? a[31:0] : 32'h7fc00000;
    assign bs = (b[63:32] == '1) ? b[31:0] : 32'h7fc00000;
    assign cs = (c[63:32] == '1) ? c[31:0] : 32'h7fc00000;
    always_comb begin
        xs = as; ys = bs; zs = cs; xd = a; yd = b; zd = c;
        np = 1'b0; nc = 1'b0; noc = 1'b0;
        unique case (fop)
            FOP_ADD, FOP_SUB: begin   // a * 1.0 + (+-b)
                ys = 32'h3f800000; zs = bs; yd = 64'h3ff0000000000000; zd = b;
                nc = (fop == FOP_SUB);
            end
            FOP_MUL:   noc = 1'b1;
            FOP_MSUB:  nc = 1'b1;
            FOP_NMSUB: np = 1'b1;
            FOP_NMADD: begin np = 1'b1; nc = 1'b1; end
            default: ;
        endcase
    end
    fp_fma_pipe #(8, 23, FMA4, FMA_ALIGN_A, FMA_CSA, FMA_LSH, FADD_RAWEXP, FADD_RSEL)  u_s (.clk, .fma_start, .add_mode, .a(xs), .b(ys), .c(zs), .cadd(bs),
                               .a_raw(FADD_RAW ? a[31:0] : as), .c_raw(FADD_RAW ? b[31:0] : bs), .sub_add(fop == FOP_SUB), .neg_p(np), .neg_c(nc), .no_c(noc),
                               .rm, .res(rs), .flags(fs));
    fp_fma_pipe #(11, 52, FMA4, FMA_ALIGN_A, FMA_CSA, FMA_LSH, FADD_RAWEXP, FADD_RSEL) u_d (.clk, .fma_start, .add_mode, .a(xd), .b(yd), .c(zd), .cadd(b),
                               .a_raw(a), .c_raw(b), .sub_add(fop == FOP_SUB), .neg_p(np), .neg_c(nc), .no_c(noc),
                               .rm, .res(rd), .flags(fd));
    // format of the op whose result is valid this cycle: FADD one cycle after add_mode, FMA two
    // (FMA4: three) cycles after fma_start
    localparam int FD = FMA4 ? 3 : 2;
    logic [FD:1] fv;
    logic [FD:1] ff;
    logic        av, af;
    always_ff @(posedge clk) begin
        fv <= {fv[FD-1:1], fma_start};
        ff <= {ff[FD-1:1], fmt};
        av <= add_mode;
        af <= fmt;
    end
    logic fmt_o;
    assign fmt_o = av ? af : ff[FD];
    assign res   = fmt_o ? rd : {32'hffffffff, rs};
    assign flags = fmt_o ? fd : fs;
`ifndef SYNTHESIS
    // self-check against the combinational reference (fp_fma_unit), aligned through the same stages
    logic [63:0] ref_r;
    logic [4:0]  ref_f;
    fp_fma_unit u_ref (.fop, .fmt, .rm, .a, .b, .c, .res(ref_r), .flags(ref_f));
    logic [68:0] ref_q [FD:1];
    logic [68:0] ref_a;
    always_ff @(posedge clk) begin
        ref_q[1] <= {ref_r, ref_f};
        for (int k = 2; k <= FD; k++) ref_q[k] <= ref_q[k-1];
        ref_a <= {ref_r, ref_f};
        if (av && {res, flags} !== ref_a)
            $error("fp_fma_pipe (add): got %h/%h, reference %h/%h", res, flags, ref_a[68:5], ref_a[4:0]);
        if (!av && fv[FD] && {res, flags} !== ref_q[FD])
            $error("fp_fma_pipe: got %h/%h, reference %h/%h", res, flags, ref_q[FD][68:5], ref_q[FD][4:0]);
    end
`endif
endmodule

// ---------------------------------------------------------------------------------------------
// sign injection, min/max and (HAS_CVT) compare, classify, FP->int moves and conversions
// ---------------------------------------------------------------------------------------------
// operand unpacking of fp_misc (S and D views of both operands)
module fp_misc_unpack
    import mm_pkg::*;
(
    input  logic [63:0] a, b,
    output fp_mu_t      u
);
    logic [31:0] as, bs;
    assign as = (a[63:32] == '1) ? a[31:0] : 32'h7fc00000;
    assign bs = (b[63:32] == '1) ? b[31:0] : 32'h7fc00000;
    fp_unpack #(8, 23)  usa (.x(as), .sign(u.s_sa), .zero(u.s_za), .inf(u.s_ia), .nan(u.s_na), .snan(u.s_sna), .e(u.s_ea), .m(u.s_ma));
    fp_unpack #(8, 23)  usb (.x(bs), .sign(u.s_sb), .zero(u.s_zb), .inf(u.s_ib), .nan(u.s_nb), .snan(u.s_snb), .e(u.s_eb), .m(u.s_mb));
    fp_unpack #(11, 52) uda (.x(a),  .sign(u.d_sa), .zero(u.d_za), .inf(u.d_ia), .nan(u.d_na), .snan(u.d_sna), .e(u.d_ea), .m(u.d_ma));
    fp_unpack #(11, 52) udb (.x(b),  .sign(u.d_sb), .zero(u.d_zb), .inf(u.d_ib), .nan(u.d_nb), .snan(u.d_snb), .e(u.d_eb), .m(u.d_mb));
endmodule

// fp_misc = fp_misc_unpack + fp_misc_core (the FCVT pipeline registers the unpacked operands)
module fp_misc
    import mm_pkg::*;
#(
    parameter bit HAS_CVT = 1'b1
)
(
    input  fop_t        fop,
    input  logic        fmt,      // operand format (FCVT f->f: destination format)
    input  logic [2:0]  rm,
    input  logic [1:0]  ityp,     // FCVT int type: 0 W, 1 WU, 2 L, 3 LU
    input  logic [63:0] a, b,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    fp_mu_t u;
    fp_misc_unpack u_unp (.a, .b, .u);
    fp_misc_core #(.HAS_CVT(HAS_CVT)) u_core (.fop, .fmt, .rm, .ityp, .a, .b, .u, .res, .flags);
endmodule

module fp_misc_core
    import mm_pkg::*;
#(
    parameter bit HAS_CVT = 1'b1,
    parameter bit HAS_F2X = 1'b1      // FCVT f->i and f->f (0: done by fp_cvt_pipe)
)
(
    input  fop_t        fop,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [1:0]  ityp,
    input  logic [63:0] a, b,
    input  fp_mu_t      u,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    logic [31:0] as, bs;
    assign as = (a[63:32] == '1) ? a[31:0] : 32'h7fc00000;
    assign bs = (b[63:32] == '1) ? b[31:0] : 32'h7fc00000;

    logic s_sa, s_za, s_ia, s_na, s_sna, s_sb, s_zb, s_ib, s_nb, s_snb;
    logic d_sa, d_za, d_ia, d_na, d_sna, d_sb, d_zb, d_ib, d_nb, d_snb;
    logic signed [15:0] s_ea, s_eb, d_ea, d_eb;
    logic [23:0] s_ma, s_mb;
    logic [52:0] d_ma, d_mb;
    assign {s_sa, s_za, s_ia, s_na, s_sna, s_sb, s_zb, s_ib, s_nb, s_snb} =
           {u.s_sa, u.s_za, u.s_ia, u.s_na, u.s_sna, u.s_sb, u.s_zb, u.s_ib, u.s_nb, u.s_snb};
    assign {d_sa, d_za, d_ia, d_na, d_sna, d_sb, d_zb, d_ib, d_nb, d_snb} =
           {u.d_sa, u.d_za, u.d_ia, u.d_na, u.d_sna, u.d_sb, u.d_zb, u.d_ib, u.d_nb, u.d_snb};
    assign {s_ea, s_eb, d_ea, d_eb} = {u.s_ea, u.s_eb, u.d_ea, u.d_eb};
    assign {s_ma, s_mb, d_ma, d_mb} = {u.s_ma, u.s_mb, u.d_ma, u.d_mb};

    // operand view in the selected format (sign / magnitude bits)
    logic        sa, sb, za, zb, na, nb, ia, snaa, snbb;
    logic [62:0] mag_a, mag_b;
    always_comb begin
        if (fmt) begin
            sa = d_sa; sb = d_sb; za = d_za; zb = d_zb; na = d_na; nb = d_nb; ia = d_ia; snaa = d_sna; snbb = d_snb;
            mag_a = a[62:0]; mag_b = b[62:0];
        end else begin
            sa = s_sa; sb = s_sb; za = s_za; zb = s_zb; na = s_na; nb = s_nb; ia = s_ia; snaa = s_sna; snbb = s_snb;
            mag_a = {32'd0, as[30:0]}; mag_b = {32'd0, bs[30:0]};
        end
    end

    // a < b in the total order of non-NaN values with -0 < +0
    logic lt_tot, eq_bits;
    assign lt_tot  = (sa != sb) ? sa : (sa ? (mag_a > mag_b) : (mag_a < mag_b));
    assign eq_bits = (sa == sb) && (mag_a == mag_b);

    // ---------------- f -> int ----------------
    logic [63:0] f2i;
    logic [4:0]  f2i_fl;
    always_comb begin
        logic        sg, zr, nn, inn, big, inc, rb, st;
        logic signed [15:0] e;
        logic [52:0] m;
        logic [106:0] t;
        logic [52:0] q;
        logic [64:0] mag, maxp, maxn;
        logic [63:0] pos_ovf, neg_ovf, r;
        int k;
        if (fmt) begin sg = d_sa; zr = d_za; nn = d_na; inn = d_ia; m = d_ma; e = d_ea; end
        else     begin sg = s_sa; zr = s_za; nn = s_na; inn = s_ia; m = {s_ma, 29'd0}; e = s_ea - 16'sd29; end
        big = (int'(e) + 52 >= 64);                 // |value| >= 2^64
        rb = 1'b0; st = 1'b0;
        if (e >= 0) begin
            mag = big ? '0 : 65'(m) << e;
        end else begin
            k = -int'(e);
            if (k > 54) k = 54;                     // k = 54: q = 0, round bit = 0, sticky = |m
            t  = {m, 54'd0} >> k;
            q  = t[106:54];
            rb = t[53];
            st = |t[52:0];
            unique case (rm)
                3'd0:    inc = rb && (st || q[0]);
                3'd1:    inc = 1'b0;
                3'd2:    inc = (rb || st) && sg;
                3'd3:    inc = (rb || st) && !sg;
                default: inc = rb;
            endcase
            mag = 65'(q) + 65'(inc);
        end
        unique case (ityp)
            2'd0:    begin maxp = 65'h7fffffff;          maxn = 65'h80000000;         pos_ovf = 64'h7fffffff;          neg_ovf = 64'hffffffff80000000; end
            2'd1:    begin maxp = 65'hffffffff;          maxn = '0;                   pos_ovf = 64'hffffffffffffffff;  neg_ovf = '0; end
            2'd2:    begin maxp = 65'h7fffffffffffffff;  maxn = 65'h8000000000000000; pos_ovf = 64'h7fffffffffffffff;  neg_ovf = 64'h8000000000000000; end
            default: begin maxp = 65'hffffffffffffffff;  maxn = '0;                   pos_ovf = 64'hffffffffffffffff;  neg_ovf = '0; end
        endcase
        f2i_fl = '0;
        if (nn)                                  begin r = pos_ovf; f2i_fl = 5'h10; end
        else if (zr)                                   r = '0;
        else if (sg && (inn || big || mag > maxn)) begin r = neg_ovf; f2i_fl = 5'h10; end
        else if (!sg && (inn || big || mag > maxp)) begin r = pos_ovf; f2i_fl = 5'h10; end
        else begin
            r = sg ? -mag[63:0] : mag[63:0];
            f2i_fl = {4'b0000, rb || st};
        end
        f2i = (ityp[1] == 1'b0) ? {{32{r[31]}}, r[31:0]} : r;
    end

    // ---------------- f -> f ----------------
    logic [31:0] d2s;
    logic [63:0] s2d;
    logic [4:0]  d2s_fl, s2d_fl;
    fp_round #(8, 23, 54)  u_d2s (.sign(d_sa), .exp(d_ea + 16'sd52), .sig({d_ma, 1'b0}), .rm, .res(d2s), .flags(d2s_fl));
    fp_round #(11, 52, 55) u_s2d (.sign(s_sa), .exp(s_ea + 16'sd23), .sig({s_ma, 31'd0}), .rm, .res(s2d), .flags(s2d_fl));
    logic [63:0] f2f;
    logic [4:0]  f2f_fl;
    always_comb begin
        f2f_fl = '0;
        if (fmt) begin   // FCVT.D.S
            if (s_na)      begin f2f = 64'h7ff8000000000000; f2f_fl = {s_sna, 4'b0000}; end
            else if (s_ia) f2f = {s_sa, 11'h7ff, 52'd0};
            else if (s_za) f2f = {s_sa, 63'd0};
            else           begin f2f = s2d; f2f_fl = s2d_fl; end
        end else begin   // FCVT.S.D
            if (d_na)      begin f2f = {32'hffffffff, 32'h7fc00000}; f2f_fl = {d_sna, 4'b0000}; end
            else if (d_ia) f2f = {32'hffffffff, d_sa, 8'hff, 23'd0};
            else if (d_za) f2f = {32'hffffffff, d_sa, 31'd0};
            else           begin f2f = {32'hffffffff, d2s}; f2f_fl = d2s_fl; end
        end
    end

    // ---------------- class ----------------
    logic [9:0] cls;
    always_comb begin
        logic sub, qn;
        sub = fmt ? (a[62:52] == '0 && !d_za) : (as[30:23] == '0 && !s_za);
        qn  = fmt ? a[51] : as[22];
        cls = '0;
        if (ia)            cls[sa ? 0 : 7] = 1'b1;
        else if (na)       cls[qn ? 9 : 8] = 1'b1;
        else if (za)       cls[sa ? 3 : 4] = 1'b1;
        else if (sub)      cls[sa ? 2 : 5] = 1'b1;
        else               cls[sa ? 1 : 6] = 1'b1;
    end

    always_comb begin
        logic [63:0] ua, ub, cn;
        logic        s;
        ua = fmt ? a : {32'hffffffff, as};
        ub = fmt ? b : {32'hffffffff, bs};
        cn = fmt ? 64'h7ff8000000000000 : {32'hffffffff, 32'h7fc00000};
        res = '0;
        flags = '0;
        unique case (fop)
            FOP_SGNJ, FOP_SGNJN, FOP_SGNJX: begin
                s = (fop == FOP_SGNJ) ? sb : ((fop == FOP_SGNJN) ? !sb : (sa ^ sb));
                res = fmt ? {s, a[62:0]} : {32'hffffffff, s, as[30:0]};
            end
            FOP_MIN, FOP_MAX: begin
                flags = {snaa || snbb, 4'b0000};
                if (na && nb)  res = cn;
                else if (na)   res = ub;
                else if (nb)   res = ua;
                else           res = ((fop == FOP_MIN) == lt_tot) ? ua : ub;
            end
            default: ;
        endcase
        if (HAS_CVT) begin
            unique case (fop)
                FOP_FEQ:   begin res = 64'(!na && !nb && (eq_bits || (za && zb)));          flags = {snaa || snbb, 4'b0000}; end
                FOP_FLT:   begin res = 64'(!na && !nb && lt_tot && !(za && zb));            flags = {na || nb, 4'b0000}; end
                FOP_FLE:   begin res = 64'(!na && !nb && (lt_tot || eq_bits || (za && zb))); flags = {na || nb, 4'b0000}; end
                FOP_CLASS: res = 64'(cls);
                FOP_MVXF:  res = fmt ? a : {{32{a[31]}}, a[31:0]};
                FOP_F2I:   if (HAS_F2X) begin res = f2i; flags = f2i_fl; end
                FOP_F2F:   if (HAS_F2X) begin res = f2f; flags = f2f_fl; end
                default: ;
            endcase
        end
    end
endmodule

// FCVT pipeline core: EX2 computes compare / classify / moves and the first
// half of the conversions (f->i: shift + rounding increment, f->f: normalization), EX3 the second
// half (f->i: range check, negation; f->f: rounding). res / flags are valid in EX3.
module fp_cvt_pipe
    import mm_pkg::*;
(
    input  logic        clk,
    input  fop_t        fop,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [1:0]  ityp,
    input  logic [63:0] a, b,
    input  fp_mu_t      u,
    input  fp_mu_t      u1,       // the unpacked operands in EX1 (before the caller's register) and
    input  logic        fmt1,     // their format: the f -> int source and shift amounts are set up in EX1
    output logic [63:0] res,
    output logic [4:0]  flags
);
    // ---------------- EX1 (registered like the caller's u) ----------------
    // f -> int: source significand and exponent of the format, right / left shift amounts
    logic        p_sg, p_zr, p_nn, p_inn, p_big, p_neg;
    logic [52:0] p_m;
    logic [5:0]  p_sh;
    always_ff @(posedge clk) begin
        logic signed [15:0] e;
        logic [52:0] m;
        int k;
        if (fmt1) begin p_sg <= u1.d_sa; p_zr <= u1.d_za; p_nn <= u1.d_na; p_inn <= u1.d_ia; m = u1.d_ma; e = u1.d_ea; end
        else      begin p_sg <= u1.s_sa; p_zr <= u1.s_za; p_nn <= u1.s_na; p_inn <= u1.s_ia; m = {u1.s_ma, 29'd0}; e = u1.s_ea - 16'sd29; end
        p_m   <= m;
        p_big <= (int'(e) + 52 >= 64);
        p_neg <= e < 0;
        k = -int'(e);
        if (k > 54) k = 54;
        p_sh  <= (e < 0) ? 6'(k) : 6'(e);     // e >= 0 and not big: e < 12
    end
    // ---------------- EX2 ----------------
    logic [63:0] o_r;
    logic [4:0]  o_f;
    fp_misc_core #(.HAS_CVT(1'b1), .HAS_F2X(1'b0)) u_core (.fop, .fmt, .rm, .ityp, .a, .b, .u, .res(o_r), .flags(o_f));
    // f -> int: magnitude after rounding
    logic        i_sg, i_zr, i_nn, i_inn, i_big, i_inx;
    logic [64:0] i_mag;
    always_comb begin
        logic [52:0] m;
        logic [106:0] t;
        logic [52:0] q;
        logic rb, st, inc;
        {i_sg, i_zr, i_nn, i_inn, i_big} = {p_sg, p_zr, p_nn, p_inn, p_big};
        m = p_m;
        rb = 1'b0; st = 1'b0;
        if (!p_neg) begin
            i_mag = i_big ? '0 : 65'(m) << p_sh;
        end else begin
            t  = {m, 54'd0} >> p_sh;
            q  = t[106:54];
            rb = t[53];
            st = |t[52:0];
            unique case (rm)
                3'd0:    inc = rb && (st || q[0]);
                3'd1:    inc = 1'b0;
                3'd2:    inc = (rb || st) && i_sg;
                3'd3:    inc = (rb || st) && !i_sg;
                default: inc = rb;
            endcase
            i_mag = 65'(q) + 65'(inc);
        end
        i_inx = rb || st;
    end
    // f -> f: normalization
    logic [53:0] d2s_n;  logic signed [15:0] d2s_be;
    logic [54:0] s2d_n;  logic signed [15:0] s2d_be;
    if (FCVT_DEN) begin : g_nrm
        // the unpacked significands are normalized already (zeros are handled in EX3)
        assign d2s_n  = {u.d_ma, 1'b0};
        assign d2s_be = u.d_ea + 16'sd52 + 16'sd127;
        assign s2d_n  = {u.s_ma, 31'd0};
        assign s2d_be = u.s_ea + 16'sd23 + 16'sd1023;
    end else begin : g_nrm
        fp_round_norm #(8, 23, 54)  u_d2s_n (.exp(u.d_ea + 16'sd52), .sig({u.d_ma, 1'b0}), .nrm(d2s_n), .be(d2s_be));
        fp_round_norm #(11, 52, 55) u_s2d_n (.exp(u.s_ea + 16'sd23), .sig({u.s_ma, 31'd0}), .nrm(s2d_n), .be(s2d_be));
    end
    // FCVT_DEN: the denormalization of a single result is done here, EX3 only rounds
    logic [53:0] d2s_dn;  logic d2s_stk;
    fp_round_den #(8, 23, 54) u_d2s_d (.nrm(d2s_n), .be(d2s_be), .dnr(d2s_dn), .stk(d2s_stk));

    // ---------------- EX3 ----------------
    fop_t        q_fop;
    logic        q_fmt;
    logic [2:0]  q_rm;
    logic [1:0]  q_ityp;
    logic [63:0] q_or;
    logic [4:0]  q_of;
    logic        q_sg, q_zr, q_nn, q_inn, q_big, q_inx;
    logic [64:0] q_mag;
    logic [53:0] q_d2s_n; logic signed [15:0] q_d2s_be; logic q_d2s_stk;
    logic [54:0] q_s2d_n; logic signed [15:0] q_s2d_be;
    logic        q_s_sa, q_s_na, q_s_sna, q_s_ia, q_s_za, q_d_sa, q_d_na, q_d_sna, q_d_ia, q_d_za;
    always_ff @(posedge clk) begin
        q_fop <= fop; q_fmt <= fmt; q_rm <= rm; q_ityp <= ityp;
        q_or <= o_r; q_of <= o_f;
        {q_sg, q_zr, q_nn, q_inn, q_big, q_inx} <= {i_sg, i_zr, i_nn, i_inn, i_big, i_inx};
        q_mag <= i_mag;
        q_d2s_n <= FCVT_DEN ? d2s_dn : d2s_n; q_d2s_stk <= d2s_stk;
        q_d2s_be <= d2s_be; q_s2d_n <= s2d_n; q_s2d_be <= s2d_be;
        {q_s_sa, q_s_na, q_s_sna, q_s_ia, q_s_za} <= {u.s_sa, u.s_na, u.s_sna, u.s_ia, u.s_za};
        {q_d_sa, q_d_na, q_d_sna, q_d_ia, q_d_za} <= {u.d_sa, u.d_na, u.d_sna, u.d_ia, u.d_za};
    end
    logic [63:0] f2i;
    logic [4:0]  f2i_fl;
    always_comb begin
        logic [64:0] maxp, maxn;
        logic [63:0] pos_ovf, neg_ovf, r;
        unique case (q_ityp)
            2'd0:    begin maxp = 65'h7fffffff;          maxn = 65'h80000000;         pos_ovf = 64'h7fffffff;          neg_ovf = 64'hffffffff80000000; end
            2'd1:    begin maxp = 65'hffffffff;          maxn = '0;                   pos_ovf = 64'hffffffffffffffff;  neg_ovf = '0; end
            2'd2:    begin maxp = 65'h7fffffffffffffff;  maxn = 65'h8000000000000000; pos_ovf = 64'h7fffffffffffffff;  neg_ovf = 64'h8000000000000000; end
            default: begin maxp = 65'hffffffffffffffff;  maxn = '0;                   pos_ovf = 64'hffffffffffffffff;  neg_ovf = '0; end
        endcase
        f2i_fl = '0;
        if (q_nn)                                        begin r = pos_ovf; f2i_fl = 5'h10; end
        else if (q_zr)                                         r = '0;
        else if (q_sg && (q_inn || q_big || q_mag > maxn))  begin r = neg_ovf; f2i_fl = 5'h10; end
        else if (!q_sg && (q_inn || q_big || q_mag > maxp)) begin r = pos_ovf; f2i_fl = 5'h10; end
        else begin
            r = q_sg ? -q_mag[63:0] : q_mag[63:0];
            f2i_fl = {4'b0000, q_inx};
        end
        f2i = (q_ityp[1] == 1'b0) ? {{32{r[31]}}, r[31:0]} : r;
    end
    logic [31:0] d2s;
    logic [63:0] s2d;
    logic [4:0]  d2s_fl, s2d_fl;
    if (FCVT_DEN) begin : g_den
        // single -> double is exact and never subnormal: pack the normalized significand
        fp_round_fin_lim #(8, 23, 54) u_d2s_f (.sign(q_d_sa), .nrm(q_d2s_n), .stk(q_d2s_stk), .be(q_d2s_be), .rm(q_rm),
                                               .res(d2s), .flags(d2s_fl));
        assign s2d    = {q_s_sa, q_s2d_be[10:0], q_s2d_n[53:2]};
        assign s2d_fl = '0;
`ifndef SYNTHESIS
        // the same results as rounding the normalized significand with the denormalization in fp_round_fin
        logic [53:0] xn;  logic [31:0] xd; logic [63:0] xs; logic [4:0] xfd, xfs;
        always_ff @(posedge clk) xn <= d2s_n;
        fp_round_fin #(8, 23, 54)  x_d2s (.sign(q_d_sa), .nrm(xn), .be(q_d2s_be), .rm(q_rm), .res(xd), .flags(xfd));
        fp_round_fin #(11, 52, 55) x_s2d (.sign(q_s_sa), .nrm(q_s2d_n), .be(q_s2d_be), .rm(q_rm), .res(xs), .flags(xfs));
        always_ff @(posedge clk)
            if (q_fop == FOP_F2F && (q_fmt ? (!q_s_na && !q_s_ia && !q_s_za && (xs !== s2d || xfs !== s2d_fl))
                                           : (!q_d_na && !q_d_ia && !q_d_za && (xd !== d2s || xfd !== d2s_fl))))
                $error("fp_cvt_pipe FCVT_DEN: %h/%h vs %h/%h", q_fmt ? xs : 64'(xd), q_fmt ? xfs : xfd,
                       q_fmt ? s2d : 64'(d2s), q_fmt ? s2d_fl : d2s_fl);
`endif
    end else begin : g_fin
        fp_round_fin #(8, 23, 54)  u_d2s_f (.sign(q_d_sa), .nrm(q_d2s_n), .be(q_d2s_be), .rm(q_rm), .res(d2s), .flags(d2s_fl));
        fp_round_fin #(11, 52, 55) u_s2d_f (.sign(q_s_sa), .nrm(q_s2d_n), .be(q_s2d_be), .rm(q_rm), .res(s2d), .flags(s2d_fl));
    end
    always_comb begin
        res = q_or; flags = q_of;
        if (q_fop == FOP_F2I) begin res = f2i; flags = f2i_fl; end
        if (q_fop == FOP_F2F) begin
            flags = '0;
            if (q_fmt) begin   // FCVT.D.S
                if (q_s_na)      begin res = 64'h7ff8000000000000; flags = {q_s_sna, 4'b0000}; end
                else if (q_s_ia) res = {q_s_sa, 11'h7ff, 52'd0};
                else if (q_s_za) res = {q_s_sa, 63'd0};
                else             begin res = s2d; flags = s2d_fl; end
            end else begin     // FCVT.S.D
                if (q_d_na)      begin res = {32'hffffffff, 32'h7fc00000}; flags = {q_d_sna, 4'b0000}; end
                else if (q_d_ia) res = {32'hffffffff, q_d_sa, 8'hff, 23'd0};
                else if (q_d_za) res = {32'hffffffff, q_d_sa, 31'd0};
                else             begin res = {32'hffffffff, d2s}; flags = d2s_fl; end
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------------------------
// int -> FP: FMV.W.X / FMV.D.X / FCVT.{S,D}.{W,WU,L,LU}
// ---------------------------------------------------------------------------------------------
module fp_i2f
    import mm_pkg::*;
(
    input  fop_t        fop,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [1:0]  ityp,
    input  logic [63:0] x,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    logic [63:0] v, mag;
    logic        sg;
    always_comb begin
        unique case (ityp)
            2'd0:    v = {{32{x[31]}}, x[31:0]};
            2'd1:    v = {32'd0, x[31:0]};
            default: v = x;
        endcase
        sg  = !ityp[0] && v[63];
        mag = sg ? -v : v;
    end
    logic [31:0] rs;
    logic [63:0] rd;
    logic [4:0]  fs, fd;
    fp_round #(8, 23, 65)  u_s (.sign(sg), .exp(16'sd63), .sig({mag, 1'b0}), .rm, .res(rs), .flags(fs));
    fp_round #(11, 52, 65) u_d (.sign(sg), .exp(16'sd63), .sig({mag, 1'b0}), .rm, .res(rd), .flags(fd));
    always_comb begin
        flags = '0;
        if (fop == FOP_MVFX)  res = fmt ? x : {32'hffffffff, x[31:0]};
        else if (mag == '0)   res = fmt ? 64'd0 : {32'hffffffff, 32'd0};
        else begin            res = fmt ? rd : {32'hffffffff, rs}; flags = fmt ? fd : fs; end
    end
endmodule

// two-stage FCVT int->fp / FMV.W.X: EX1 sign, magnitude and normalization,
// EX2 rounding; res / flags are valid in EX2
module fp_i2f_pipe
    import mm_pkg::*;
(
    input  logic        clk,
    input  fop_t        fop,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [1:0]  ityp,
    input  logic [63:0] x,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    logic [63:0] v, mag;
    logic        sg;
    always_comb begin
        unique case (ityp)
            2'd0:    v = {{32{x[31]}}, x[31:0]};
            2'd1:    v = {32'd0, x[31:0]};
            default: v = x;
        endcase
        sg  = !ityp[0] && v[63];
        mag = sg ? -v : v;
    end
    logic [64:0] ns, nd;
    logic signed [15:0] bs, bd;
    fp_round_norm #(8, 23, 65)  u_ns (.exp(16'sd63), .sig({mag, 1'b0}), .nrm(ns), .be(bs));
    fp_round_norm #(11, 52, 65) u_nd (.exp(16'sd63), .sig({mag, 1'b0}), .nrm(nd), .be(bd));
    // EX2
    fop_t q_fop; logic q_fmt, q_sg, q_zero; logic [2:0] q_rm; logic [63:0] q_x;
    logic [64:0] q_ns, q_nd; logic signed [15:0] q_bs, q_bd; logic q_ks, q_kd;
    always_ff @(posedge clk) begin
        q_fop <= fop; q_fmt <= fmt; q_rm <= rm; q_sg <= sg; q_zero <= mag == '0; q_x <= x;
        q_ns <= ns; q_nd <= nd; q_bs <= bs; q_bd <= bd;
        q_ks <= |ns[65-3-24:0]; q_kd <= |nd[65-3-53:0];
    end
    logic [31:0] rs;
    logic [63:0] rd;
    logic [4:0]  fs, fd;
    // an integer is never subnormal or out of range in S / D: the rounding without the denormalizing
    // shift (fp_round_fin_lim) gives the same result, with the sticky bit formed in EX1
    fp_round_fin_lim #(8, 23, 65)  u_s (.sign(q_sg), .nrm(q_ns), .stk(q_ks), .be(q_bs), .rm(q_rm), .res(rs), .flags(fs));
    fp_round_fin_lim #(11, 52, 65) u_d (.sign(q_sg), .nrm(q_nd), .stk(q_kd), .be(q_bd), .rm(q_rm), .res(rd), .flags(fd));
    always_comb begin
        flags = '0;
        if (q_fop == FOP_MVFX)  res = q_fmt ? q_x : {32'hffffffff, q_x[31:0]};
        else if (q_zero)        res = q_fmt ? 64'd0 : {32'hffffffff, 32'd0};
        else begin              res = q_fmt ? rd : {32'hffffffff, rs}; flags = q_fmt ? fd : fs; end
    end
endmodule

// ---------------------------------------------------------------------------------------------
// FDIV / FSQRT: digit recurrence, U bits per cycle, S and D share the D-width datapath
// (S mantissas are left-aligned to 53 bits and fewer iterations are run).
//   FDIV_SRT = 0: restoring. start (1 cycle) -> BUSY (ND/U or NS/U cycles) -> FIN (done, result rounded)
//   FDIV_SRT = 1: radix-2 SRT (Ercegovac & Lang): the remainder w is kept in carry-save form and each digit
//     (-1 / 0 / +1) is selected from a 5-bit estimate of 2w; the estimate of the next step is computed for
//     the three digits in parallel and selected (as in mm_div_srt). The quotient / root is assembled by
//     on-the-fly conversion (S and SM = S - ulp, digits are appended without carries), which also gives
//     the root-dependent addend of square root by concatenation:
//       divide: w0 = x / 2, w' = 2w - q d;   sqrt: S0 = 1, w0 = x - 1, w' = 2w - q (2S + q 2^-(j+1))
//     After the last step a negative remainder selects SM, and the sticky bit is "corrected w != 0".
//     start -> ITER (ND/U or NS/U cycles) -> POST (remainder sign, sticky) -> FIN
// ---------------------------------------------------------------------------------------------
//   OVL = 1 (FDIV_SRT): FIN is separate from the iteration engine (it keeps its own copies of the format, sign,
//     rounding mode and special-case result, written in POST), so the next operation starts while the previous
//     one is in POST (without DEN) or DEN; a special-case operand then goes through POST (one cycle more). post: the engine hands its operation to FIN at the end of this cycle;
//     acc2: a start two cycles from now is taken.
module fp_divsqrt #(parameter int U = 4, parameter bit OVL = 1'b0) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        kill,              // the operation in the iteration engine is killed
    input  logic        is_sqrt,
    input  logic        fmt,
    input  logic [2:0]  rm,
    input  logic [63:0] a, b,
    output logic        busy,              // the iteration engine holds an operation
    output logic        post,
    output logic        acc2,
    output logic        done,
    output logic [63:0] res,
    output logic [4:0]  flags
);
    localparam int ND = ((55 + U - 1) / U) * U;   // quotient / root bits computed for D
    localparam int NS = ((26 + U - 1) / U) * U;   //                                for S
    localparam int RW = ND + 5;                   // partial remainder width

    logic [31:0] as, bs;
    assign as = (a[63:32] == '1) ? a[31:0] : 32'h7fc00000;
    assign bs = (b[63:32] == '1) ? b[31:0] : 32'h7fc00000;
    logic s_sa, s_za, s_ia, s_na, s_sna, s_sb, s_zb, s_ib, s_nb, s_snb;
    logic d_sa, d_za, d_ia, d_na, d_sna, d_sb, d_zb, d_ib, d_nb, d_snb;
    logic signed [15:0] s_ea, s_eb, d_ea, d_eb;
    logic [23:0] s_ma, s_mb;
    logic [52:0] d_ma, d_mb;
    fp_unpack #(8, 23)  usa (.x(as), .sign(s_sa), .zero(s_za), .inf(s_ia), .nan(s_na), .snan(s_sna), .e(s_ea), .m(s_ma));
    fp_unpack #(8, 23)  usb (.x(bs), .sign(s_sb), .zero(s_zb), .inf(s_ib), .nan(s_nb), .snan(s_snb), .e(s_eb), .m(s_mb));
    fp_unpack #(11, 52) uda (.x(a),  .sign(d_sa), .zero(d_za), .inf(d_ia), .nan(d_na), .snan(d_sna), .e(d_ea), .m(d_ma));
    fp_unpack #(11, 52) udb (.x(b),  .sign(d_sb), .zero(d_zb), .inf(d_ib), .nan(d_nb), .snan(d_snb), .e(d_eb), .m(d_mb));

    import mm_pkg::*;
    logic [ND-1:0]   q;
    logic            st_bit;
    logic            sq, fm, sgn, spc, fin, state_idle;
    logic [ND:0]     nD;                // FDIV_SRT: normalized significands and biased exponents (POST)
    logic [NS:0]     nS;
    logic signed [15:0] beD, beS;
    logic [2:0]      rmq;
    logic signed [15:0] rexp;
    logic [63:0]     sres;
    logic [4:0]      sfl;
    localparam bit OV = OVL && FDIV_SRT;
    logic            acc;               // a start is taken in this cycle
    logic            t_fm, t_sgn, t_spc;    // OV: copies for FIN
    logic [2:0]      t_rm;
    logic [63:0]     t_res;
    logic [4:0]      t_fl;
    logic signed [15:0] t_rexp;
    logic            f_fm, f_sgn, f_spc;    // what FIN reads
    logic [2:0]      f_rm;
    logic [63:0]     f_res;
    logic [4:0]      f_fl;
    logic signed [15:0] f_rexp;
    assign f_fm   = OV ? t_fm   : fm;
    assign f_sgn  = OV ? t_sgn  : sgn;
    assign f_spc  = OV ? t_spc  : spc;
    assign f_rm   = OV ? t_rm   : rmq;
    assign f_res  = OV ? t_res  : sres;
    assign f_fl   = OV ? t_fl   : sfl;
    assign f_rexp = OV ? t_rexp : rexp;

    // operands in the selected format, aligned to 53 bits
    logic        sa, sb, za, zb, ia, ib, na, nb, sna, snb;
    logic [52:0] ma, mb;
    logic signed [15:0] ea, eb;
    always_comb begin
        if (fmt) begin
            sa = d_sa; sb = d_sb; za = d_za; zb = d_zb; ia = d_ia; ib = d_ib; na = d_na; nb = d_nb;
            sna = d_sna; snb = d_snb;
            ma = d_ma; mb = d_mb; ea = d_ea; eb = d_eb;
        end else begin
            sa = s_sa; sb = s_sb; za = s_za; zb = s_zb; ia = s_ia; ib = s_ib; na = s_na; nb = s_nb;
            sna = s_sna; snb = s_snb;
            ma = {s_ma, 29'd0}; mb = {s_mb, 29'd0}; ea = s_ea - 16'sd29; eb = s_eb - 16'sd29;
        end
    end

    // special-case results
    logic        is_spc;
    logic [63:0] spc_res;
    logic [4:0]  spc_fl;
    always_comb begin
        logic [63:0] cn, inf_, zero_;
        logic s;
        s     = is_sqrt ? sa : (sa ^ sb);
        cn    = fmt ? 64'h7ff8000000000000 : {32'hffffffff, 32'h7fc00000};
        inf_  = fmt ? {s, 11'h7ff, 52'd0} : {32'hffffffff, s, 8'hff, 23'd0};
        zero_ = fmt ? {s, 63'd0} : {32'hffffffff, s, 31'd0};
        is_spc = 1'b1; spc_res = cn; spc_fl = '0;
        if (is_sqrt) begin
            if (na)          begin spc_res = cn; spc_fl = {sna, 4'b0000}; end
            else if (za)     spc_res = zero_;
            else if (sa)     begin spc_res = cn; spc_fl = 5'h10; end
            else if (ia)     spc_res = inf_;
            else             is_spc = 1'b0;
        end else begin
            if (na || nb)               begin spc_res = cn; spc_fl = {sna || snb, 4'b0000}; end
            else if (ia && ib)          begin spc_res = cn; spc_fl = 5'h10; end
            else if (za && zb)          begin spc_res = cn; spc_fl = 5'h10; end
            else if (ia)                spc_res = inf_;
            else if (zb)                begin spc_res = inf_; spc_fl = 5'h08; end   // divide by zero
            else if (za || ib)          spc_res = zero_;
            else                        is_spc = 1'b0;
        end
    end

    // operand-independent part of the start
    always_ff @(posedge clk) begin
        if (start && acc) begin
            sq   <= is_sqrt;
            fm   <= fmt;
            rmq  <= rm;
            spc  <= is_spc;
            sres <= spc_res;
            sfl  <= spc_fl;
            sgn  <= is_sqrt ? 1'b0 : (sa ^ sb);
            rexp <= is_sqrt ? ((ea[0] ? ea - 16'sd1 : ea) >>> 1) + 16'sd26 : ea - eb;
        end
    end

    if (!FDIV_SRT) begin : g_rst
        typedef enum logic [1:0] {S_IDLE, S_BUSY, S_FIN} st_t;
        st_t state;
        logic [RW-1:0]   rem;
        logic [2*ND-1:0] rad;
        logic [52:0]     dvs;
        logic [6:0]      cnt;

        // U recurrence steps per cycle
        logic [ND-1:0]   q_n;
        logic [RW-1:0]   rem_n;
        logic [2*ND-1:0] rad_n;
        always_comb begin
            logic [RW-1:0] trial;
            q_n = q; rem_n = rem; rad_n = rad;
            for (int u = 0; u < U; u++) begin
                if (!sq) begin
                    if (rem_n >= RW'(dvs)) begin rem_n = rem_n - RW'(dvs); q_n = {q_n[ND-2:0], 1'b1}; end
                    else                          q_n = {q_n[ND-2:0], 1'b0};
                    rem_n = rem_n << 1;
                end else begin
                    rem_n = (rem_n << 2) | RW'(rad_n[2*ND-1 -: 2]);
                    rad_n = rad_n << 2;
                    trial = (RW'(q_n) << 2) | RW'(1);
                    if (rem_n >= trial) begin rem_n = rem_n - trial; q_n = {q_n[ND-2:0], 1'b1}; end
                    else                       q_n = {q_n[ND-2:0], 1'b0};
                end
            end
        end

        always_ff @(posedge clk) begin
            if (!rst_n || kill) begin
                state <= S_IDLE;
            end else begin
                unique case (state)
                    S_IDLE: if (start) begin
                        q   <= '0;
                        dvs <= mb;
                        if (is_sqrt) begin
                            // radicand m' * 2^e' with e' even, m' in [2^52, 2^54)
                            rem  <= '0;
                            rad  <= ea[0] ? {ma, 1'b0, {(2*ND-54){1'b0}}} : {1'b0, ma, {(2*ND-54){1'b0}}};
                        end else begin
                            rem  <= RW'(ma);
                            rad  <= '0;
                        end
                        cnt   <= 7'((fmt ? ND : NS) / U);
                        state <= is_spc ? S_FIN : S_BUSY;
                    end
                    S_BUSY: begin
                        q <= q_n; rem <= rem_n; rad <= rad_n;
                        cnt <= cnt - 7'd1;
                        if (cnt == 7'd1) state <= S_FIN;
                    end
                    default: state <= S_IDLE;   // S_FIN
                endcase
            end
        end
        assign st_bit     = (rem != '0);
        assign state_idle = (state == S_IDLE);
        assign fin        = (state == S_FIN);
        assign acc        = state_idle;
        assign post       = 1'b0;
        assign acc2       = 1'b0;
    end else begin : g_srt
        localparam int F  = 58;             // fraction bits of w, d, S, SM
        localparam int WW = F + 4;          // sign + 3 integer bits (|2w| < 6 for square root)
        localparam int E  = 5;              // estimate: sign, 3 integer bits, 1 fraction bit
        typedef enum logic [2:0] {S_IDLE, S_ITER, S_POST, S_DEN, S_FIN} st_t;
        st_t state;
        logic [WW-1:0] ws, wc, d, sr, sm, m;    // remainder (carry-save), divisor, S, SM, ulp of the next digit
        logic [E-1:0]  est;
        logic [6:0]    cnt;
        logic          stq;
        logic          den;                     // FDIV_DEN: the result may be subnormal
        logic [ND:0]   dnD;
        logic [NS:0]   dnS;
        logic          dkD, dkS;
        fp_round_den #(11, 52, ND + 1) u_dnd (.nrm(nD), .be(beD), .dnr(dnD), .stk(dkD));
        fp_round_den #(8, 23, NS + 1)  u_dns (.nrm(nS), .be(beS), .dnr(dnS), .stk(dkS));
        logic [ND-1:0] qf;
        logic          fin_q;                   // OV: FIN
        logic          hand;                    // the engine hands its operation to FIN
        assign hand = (state == S_POST && !(FDIV_DEN && den && !spc)) || state == S_DEN;
        assign acc  = state == S_IDLE || (OV && hand);

        // estimate of the next step (top of 2w') from 2w = (s, c) and the addend x
        function automatic logic [E-1:0] est_next(logic [WW-1:0] s, logic [WW-1:0] c, logic [WW-1:0] x);
            logic [E:0] t, mj;
            t  = s[WW-2 -: E+1] ^ c[WW-2 -: E+1] ^ x[WW-2 -: E+1];
            mj = (s[WW-3 -: E+1] & c[WW-3 -: E+1]) | (s[WW-3 -: E+1] & x[WW-3 -: E+1]) | (c[WW-3 -: E+1] & x[WW-3 -: E+1]);
            return t[E:1] + mj[E:1];
        endfunction

        // U radix-2 steps
        logic [WW-1:0] ws_n, wc_n, sr_n, sm_n, m_n;
        logic [E-1:0]  est_n;
        always_comb begin
            logic [WW-1:0] s2, c2, x, xp, xn, cy, h;
            logic [E-1:0]  ep, ez, em;
            logic          qpos, qneg;
            ws_n = ws; wc_n = wc; sr_n = sr; sm_n = sm; m_n = m; est_n = est;
            for (int u = 0; u < U; u++) begin
                s2   = ws_n << 1;
                c2   = wc_n << 1;
                h    = m_n >> 1;                            // 2^-(j+1)
                qpos = !est_n[E-1];                         // estimate >= 0
                qneg = est_n[E-1] && est_n != '1;           // estimate <= -1 (units of 1/2)
                xp   = sq ? ~((sr_n << 1) | h) : ~d;        // -(2S + 2^-(j+1)) - ulp / -d - ulp
                xn   = sq ? ((sm_n << 1) | m_n | h) : d;    //  2S - 2^-(j+1) = 2SM + 3 * 2^-(j+1) / d
                ep   = est_next(s2, c2, xp);
                em   = est_next(s2, c2, xn);
                ez   = est_next(s2, c2, '0);
                est_n = qpos ? ep : (qneg ? em : ez);
                x    = qpos ? xp : (qneg ? xn : '0);
                ws_n = s2 ^ c2 ^ x;
                cy   = (s2 & c2) | (s2 & x) | (c2 & x);
                wc_n = {cy[WW-2:0], qpos};                  // + ulp completes the two's complement
                {sr_n, sm_n} = qpos ? {sr_n | h, sr_n} : (qneg ? {sm_n | h, sm_n} : {sr_n, sm_n | h});
                m_n  = h;
            end
        end

        // start values, POST
        logic [WW-1:0] w0;
        logic          p_st;
        logic [ND-1:0] p_qv;
        always_comb begin
            logic [WW-1:0] w, c, w2;
            logic          neg;
            // divide: x = ma 2^-54, d = mb 2^-53; sqrt: x = ma 2^-53 (odd exponent) or 2^-54, S0 = 1
            w0  = (is_sqrt && ea[0]) ? WW'(ma) << (F - 53) : WW'(ma) << (F - 54);
            if (is_sqrt) w0 = w0 - (WW'(1) << F);
            // negative remainder: SM, remainder + correction
            c    = sq ? ((sm << 1) | m) : d;        // x - SM^2 = w + 2SM + 2^-n / w + d
            w    = ws + wc;
            w2   = (ws ^ wc ^ c) + (((ws & wc) | (ws & c) | (wc & c)) << 1);
            neg  = w[WW-1];
            p_qv = fm ? ND'((neg ? sm : sr) >> (F - ND)) : ND'((neg ? sm : sr) >> (F - NS));
            p_st = neg ? (w2 != '0) : (w != '0);
        end

        // datapath of the engine (start, ITER) and of POST / DEN
        always_ff @(posedge clk) begin
            if (state == S_ITER) begin
                ws <= ws_n; wc <= wc_n; sr <= sr_n; sm <= sm_n; m <= m_n; est <= est_n;
                cnt <= cnt - 7'd1;
                // biased exponent rexp + bias - (0 or 1) below 1 (a root is never subnormal)
                den <= fm ? (rexp <= -16'sd1022) : (rexp <= -16'sd126);
            end
            if (state == S_POST) begin
                stq <= p_st;
                qf  <= p_qv;
                // normalization for the rounding in FIN: the quotient / root has at most one
                // leading zero (operands normalized to [1, 2))
                nD  <= p_qv[ND-1] ? {p_qv, p_st} : {p_qv[ND-2:0], p_st, 1'b0};
                beD <= rexp + 16'sd1023 - (p_qv[ND-1] ? 16'sd0 : 16'sd1);
                nS  <= p_qv[NS-1] ? {p_qv[NS-1:0], p_st} : {p_qv[NS-2:0], p_st, 1'b0};
                beS <= rexp + 16'sd127 - (p_qv[NS-1] ? 16'sd0 : 16'sd1);
            end
            if (state == S_DEN) begin               // subnormal: nD / nS weigh 2^emin at the top bit
                if (fm) nD <= dnD;
                else    nS <= dnS;
            end
            if (start && acc) begin
                ws  <= w0;
                wc  <= '0;
                est <= w0[WW-2 -: E];
                d   <= WW'(mb) << (F - 53);
                sr  <= is_sqrt ? WW'(1) << F : '0;
                sm  <= '0;
                m   <= WW'(1) << F;
                cnt <= 7'((fmt ? ND : NS) / U);
            end
            if (OV && hand) begin
                t_fm <= fm; t_sgn <= sgn; t_spc <= spc; t_rm <= rmq; t_res <= sres; t_fl <= sfl; t_rexp <= rexp;
            end
            fin_q <= rst_n && OV && hand && !kill;
        end

        // state of the engine (OV: a start takes priority over the kill of the operation being handed over)
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                state <= S_IDLE;
            end else if (OV && start && acc) begin
                state <= is_spc ? S_POST : S_ITER;
            end else if (kill) begin
                state <= S_IDLE;
            end else begin
                unique case (state)
                    S_IDLE: if (start) state <= is_spc ? S_FIN : S_ITER;
                    S_ITER: if (cnt == 7'd1) state <= S_POST;
                    S_POST: state <= (FDIV_DEN && den && !spc) ? S_DEN : (OV ? S_IDLE : S_FIN);
                    S_DEN:  state <= OV ? S_IDLE : S_FIN;
                    default: state <= S_IDLE;       // S_FIN
                endcase
            end
        end
        assign q          = qf;
        assign st_bit     = stq;
        assign state_idle = (state == S_IDLE);
        assign fin        = OV ? fin_q : (state == S_FIN);
        assign post       = OV && hand;
        // the engine is free (IDLE) or hands over two cycles from now, if nothing starts in between
        assign acc2 = state == S_IDLE || state == S_POST || state == S_DEN ||
                      (state == S_ITER && (cnt == 7'd1 || (cnt == 7'd2 && !(FDIV_DEN && den))));
`ifndef SYNTHESIS
        always_ff @(posedge clk)
            if (rst_n && start && !acc) $error("fp_divsqrt: start while busy (state %0d)", state);
`endif
    end

    logic [31:0] rs;
    logic [63:0] rd;
    logic [4:0]  fls, fld;
    if (FDIV_SRT) begin : g_rnds
        // normalized in POST: FIN only rounds
        if (FDIV_DEN) begin : g_lim
            // after DEN (or a normal result) the sticky of the dropped bits is |nrm[W-3-P:0] (fp_round_den ORs it into bit 0)
            fp_round_fin_lim #(8, 23, NS + 1)  u_rs (.sign(f_sgn), .nrm(nS), .stk(|nS[NS-26:0]), .be(beS), .rm(f_rm),
                                                     .res(rs), .flags(fls));
            fp_round_fin_lim #(11, 52, ND + 1) u_rd (.sign(f_sgn), .nrm(nD), .stk(|nD[ND-55:0]), .be(beD), .rm(f_rm),
                                                     .res(rd), .flags(fld));
        end else begin : g_fin
            fp_round_fin #(8, 23, NS + 1)  u_rs (.sign(f_sgn), .nrm(nS), .be(beS), .rm(f_rm), .res(rs), .flags(fls));
            fp_round_fin #(11, 52, ND + 1) u_rd (.sign(f_sgn), .nrm(nD), .be(beD), .rm(f_rm), .res(rd), .flags(fld));
        end
`ifndef SYNTHESIS
        logic [31:0] xs; logic [63:0] xd; logic [4:0] xfs, xfd;
        fp_round #(8, 23, NS + 1)  x_rs (.sign(f_sgn), .exp(f_rexp), .sig({q[NS-1:0], st_bit}), .rm(f_rm), .res(xs), .flags(xfs));
        fp_round #(11, 52, ND + 1) x_rd (.sign(f_sgn), .exp(f_rexp), .sig({q, st_bit}),          .rm(f_rm), .res(xd), .flags(xfd));
        always_ff @(posedge clk) if (rst_n && fin && !f_spc && (f_fm ? (xd !== rd || xfd !== fld) : (xs !== rs || xfs !== fls)))
            $error("fp_divsqrt rounding: %h/%h vs %h/%h", f_fm ? xd : 64'(xs), f_fm ? xfd : xfs, f_fm ? rd : 64'(rs), f_fm ? fld : fls);
`endif
    end else begin : g_rndr
        fp_round #(8, 23, NS + 1)  u_rs (.sign(sgn), .exp(rexp), .sig({q[NS-1:0], st_bit}), .rm(rmq), .res(rs), .flags(fls));
        fp_round #(11, 52, ND + 1) u_rd (.sign(sgn), .exp(rexp), .sig({q, st_bit}),          .rm(rmq), .res(rd), .flags(fld));
    end

    assign busy = !state_idle;
    assign done = fin;
    assign res   = f_spc ? f_res : (f_fm ? rd : {32'hffffffff, rs});
    assign flags = f_spc ? f_fl  : (f_fm ? fld : fls);
endmodule
