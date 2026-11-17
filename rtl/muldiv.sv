// RV64M multiply / divide for the out-of-order core.
//   - mul_result: one signed (XLEN+1) x (XLEN+1) product (SynRV synrv_muldiv.sv, eeic-vlsi/SynRV, Apache-2.0);
//     used in EX1 when MUL_PIPE = 0 (delayed by registers in mm_core) and as the sim-only reference
//   - mm_mul_pipe: the same product as a 3-stage Booth / carry-save pipeline (MUL_PIPE)
//   - mm_div: restoring division on magnitudes with a final sign fix, U quotient bits per cycle (SynRV)
//   - mm_div_srt: carry-save SRT division with leading-zero normalization (DIV_SRT)

package mm_muldiv_pkg;
    // fn = funct3: 0 MUL, 1 MULH, 2 MULHSU, 3 MULHU ; word = MULW
    function automatic logic [63:0] mul_result(logic [2:0] fn, logic word, logic [63:0] a, logic [63:0] b);
        logic signed [64:0]  ae, be;
        logic signed [129:0] p;
        ae = {(fn == 3'd1 || fn == 3'd2) && a[63], a};
        be = {(fn == 3'd1) && b[63], b};
        p  = ae * be;
        if (word)           return {{32{p[31]}}, p[31:0]};
        if (fn[1:0] == 2'd0) return p[63:0];
        return p[127:64];
    endfunction
endpackage

// fn = funct3: 4 DIV, 5 DIVU, 6 REM, 7 REMU ; word = *W
//   start (1 cycle, operands captured) -> BUSY (64/U or 32/U cycles) -> FIN (done = 1) -> IDLE
module mm_div #(parameter int U = 4) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        kill,
    input  logic [2:0]  fn,
    input  logic        word,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        busy,
    output logic        done,
    output logic [63:0] y
);
    typedef enum logic [1:0] {S_IDLE, S_BUSY, S_FIN} st_t;
    st_t         state;
    logic [6:0]  cnt;
    logic [63:0] quo, dvs, a_orig;
    logic [64:0] rem;
    logic        neg_q, neg_r, bzero, word_q, is_rem;

    function automatic logic [63:0] sext32(logic [63:0] v);
        return {{32{v[31]}}, v[31:0]};
    endfunction

    logic        sgn, sa, sb;
    logic [63:0] aw, bw, ma, mb;
    assign sgn = !fn[0];                                   // DIV / REM
    assign aw  = word ? (sgn ? sext32(a) : {32'd0, a[31:0]}) : a;
    assign bw  = word ? (sgn ? sext32(b) : {32'd0, b[31:0]}) : b;
    assign sa  = sgn && aw[63];
    assign sb  = sgn && bw[63];
    assign ma  = sa ? -aw : aw;
    assign mb  = sb ? -bw : bw;

    // U restoring steps
    logic [63:0] quo_n;
    logic [64:0] rem_n;
    always_comb begin
        logic [64:0] rem_sh, diff;
        quo_n = quo; rem_n = rem;
        for (int u = 0; u < U; u++) begin
            rem_sh = {rem_n[63:0], quo_n[63]};
            diff   = rem_sh - {1'b0, dvs};
            if (!diff[64]) begin rem_n = diff;   quo_n = {quo_n[62:0], 1'b1}; end
            else           begin rem_n = rem_sh; quo_n = {quo_n[62:0], 1'b0}; end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || kill) begin
            state <= S_IDLE;
        end else begin
            unique case (state)
                S_IDLE: if (start) begin
                    quo    <= word ? {ma[31:0], 32'd0} : ma;
                    rem    <= '0;
                    dvs    <= mb;
                    neg_q  <= sa ^ sb;
                    neg_r  <= sa;
                    bzero  <= (bw == '0);
                    a_orig <= aw;
                    word_q <= word;
                    is_rem <= fn[1];
                    cnt    <= word ? 7'(32 / U) : 7'(64 / U);
                    state  <= S_BUSY;
                end
                S_BUSY: begin
                    quo <= quo_n; rem <= rem_n;
                    cnt <= cnt - 7'd1;
                    if (cnt == 7'd1) state <= S_FIN;
                end
                default: state <= S_IDLE;   // S_FIN
            endcase
        end
    end

    logic [63:0] qv, rv, r;
    assign qv = bzero ? '1 : (neg_q ? -quo : quo);
    assign rv = bzero ? a_orig : (neg_r ? -rem[63:0] : rem[63:0]);
    assign r  = is_rem ? rv : qv;
    assign y  = word_q ? sext32(r) : r;
    assign busy = (state != S_IDLE);
    assign done = (state == S_FIN);
endmodule

// leading-zero count as a balanced tree (pairs of (any one, count) merged level by level); cnt = W for x = 0
module mm_lzc #(parameter int W = 64, parameter int CW = $clog2(W + 1)) (
    input  logic [W-1:0]  x,
    output logic [CW-1:0] cnt
);
    localparam int L = $clog2(W);
    localparam int N = 1 << L;
    always_comb begin
        logic [N-1:0]       v [L+1];
        logic [N-1:0][L:0]  c [L+1];
        for (int i = 0; i < N; i++) begin           // index 0 = most significant bit; padding counts as zeros
            v[0][i] = (i < W) ? x[W-1-i] : 1'b0;
            c[0][i] = '0;
        end
        for (int l = 1; l <= L; l++) begin
            for (int g = 0; g < (N >> l); g++) begin
                v[l][g] = v[l-1][2*g] || v[l-1][2*g+1];
                c[l][g] = v[l-1][2*g] ? c[l-1][2*g] : (c[l-1][2*g+1] | ((L+1)'(1) << (l - 1)));
            end
            for (int g = (N >> l); g < N; g++) begin v[l][g] = 1'b0; c[l][g] = '0; end
        end
        cnt = v[L][0] ? CW'(c[L][0]) : CW'(W);
    end
endmodule

// SRT divider: the partial remainder is kept in carry-save form and each quotient digit
// (-1 / 0 / +1, radix 2) is selected from a 4-bit estimate of its top, so an iteration has no
// full-width carry propagation; U steps per cycle. The estimate of the next step is computed for all
// three digits of the current step in parallel and then selected, so the step-to-step chain is a 3-way
// select of 4 bits; the estimate is carried in a register between cycles. The quotient is assembled by
// on-the-fly conversion (Q and QM = Q - 1, digits appended without carries).
// Stages: start (absolute values) -> PRE0 (leading-zero counts,
// number of steps, shift amounts) -> PRE1 (normalization) -> ITER -> POST0 (remainder = sum of the
// carry-save pair) -> POST1 (negative remainder: + divisor and QM; denormalization; result select) -> done
// (sign, the cycle after POST1).
//   PRE1 = 1: PRE0 and PRE1 in one cycle: the dividend is normalized by its own leading-zero count and then
//     shifted by the pad of the step count to a multiple of U (0..U-1), so no adder sits in front of the shifts.
//   POST1 = 1: POST0 and POST1 in one cycle: w and w + d are summed in parallel and selected by the sign of w.
//   OVL = 1: the result stage (done) is separate from the iteration engine, so the next division starts while
//     the previous one is in POST1; acc2 tells the issue queue that a start two cycles later is taken.
// The number of steps follows from the leading-zero difference (rounded up to a multiple of U).
//   Fixed point: the divisor d = D << (dz + 4) has 68 fraction bits (d in [1/2, 1)); the remainder
//   w0 = N << (dz + 4 - n) with n steps (|w| <= d holds); after n steps N = Q * D + (w_n >> (dz + 4)).
module mm_div_srt #(parameter int U = 4, parameter bit PRE1 = 1'b0, parameter bit POST1 = 1'b0,
                    parameter bit OVL = 1'b0) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic        kill,              // the operation in the iteration engine is killed
    input  logic [2:0]  fn,
    input  logic        word,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic        busy,              // the iteration engine holds an operation
    output logic        post,              // ... in its last cycle (the result follows in the next cycle)
    output logic        acc2,              // OVL: a start two cycles from now is taken
    output logic        done,
    output logic [63:0] y
);
    localparam int WW = 71;            // remainder width: 68 fraction bits, 2 integer bits, sign
    typedef enum logic [2:0] {S_IDLE, S_PRE0, S_PRE1, S_ITER, S_POST0, S_POST1} st_t;
    st_t state;

    function automatic logic [63:0] sext32(logic [63:0] v);
        return {{32{v[31]}}, v[31:0]};
    endfunction
    // estimate of the next step (top of 2w') from bits [WW-2:WW-6] of 2w = (s, c) and the addend x
    function automatic logic [3:0] est_next(logic [WW-1:0] s, logic [WW-1:0] c, logic [WW-1:0] x);
        logic [4:0] t, m;
        t = s[WW-2 -: 5] ^ c[WW-2 -: 5] ^ x[WW-2 -: 5];
        m = (s[WW-3 -: 5] & c[WW-3 -: 5]) | (s[WW-3 -: 5] & x[WW-3 -: 5]) | (c[WW-3 -: 5] & x[WW-3 -: 5]);
        return t[4:1] + m[4:1];
    endfunction

    logic        sgn, sa, sb;
    logic [63:0] aw, bw, ma, mb;
    assign sgn = !fn[0];                                   // DIV / REM
    assign aw  = word ? (sgn ? sext32(a) : {32'd0, a[31:0]}) : a;
    assign bw  = word ? (sgn ? sext32(b) : {32'd0, b[31:0]}) : b;
    assign sa  = sgn && aw[63];
    assign sb  = sgn && bw[63];
    assign ma  = sa ? -aw : aw;
    assign mb  = sb ? -bw : bw;

    logic [63:0]   n_q, d_q, a_orig;
    logic          neg_q, neg_r, bzero, word_q, is_rem, none_q;
    logic [6:0]    shd, shn, cnt;
    logic [WW-1:0] ws, wc, dfix, wsum;
    logic [3:0]    est;
    logic [63:0]   qq, qm;             // quotient Q and QM = Q - 1 (on-the-fly conversion)
    logic [63:0]   fr;                 // result before the sign (done stage)
    logic          fneg, fword, fin;

    logic [6:0] dz, nz;
    mm_lzc #(64, 7) u_lzd (.x(d_q), .cnt(dz));
    mm_lzc #(64, 7) u_lzn (.x(n_q), .cnt(nz));

    // U radix-2 SRT steps on the carry-save remainder
    logic [WW-1:0] ws_n, wc_n;
    logic [63:0]   qq_n, qm_n;
    logic [3:0]    est_n;
    always_comb begin
        logic [WW-1:0] s2, c2, x, cy;
        logic [3:0]    ep, ez, em;
        logic          qpos, qneg;
        ws_n = ws; wc_n = wc; qq_n = qq; qm_n = qm; est_n = est;
        for (int u = 0; u < U; u++) begin
            s2   = ws_n << 1;
            c2   = wc_n << 1;
            qpos = !est_n[3];                           // estimate >= 0
            qneg = est_n[3] && est_n != 4'b1111;        // estimate <= -1 (units of 1/2)
            ep   = est_next(s2, c2, ~dfix);             // next estimate for q = +1 / -1 / 0
            em   = est_next(s2, c2, dfix);
            ez   = est_next(s2, c2, '0);
            est_n = qpos ? ep : (qneg ? em : ez);
            x    = qpos ? ~dfix : (qneg ? dfix : '0);
            ws_n = s2 ^ c2 ^ x;
            cy   = (s2 & c2) | (s2 & x) | (c2 & x);
            wc_n = {cy[WW-2:0], qpos};                  // + 1 completes -d for q = +1
            // on-the-fly conversion: +1: Q.1 / Q.0, 0: Q.0 / QM.1, -1: QM.1 / QM.0
            {qq_n, qm_n} = qpos ? {qq_n[62:0], 1'b1, qq_n[62:0], 1'b0} :
                           qneg ? {qm_n[62:0], 1'b1, qm_n[62:0], 1'b0} :
                                  {qq_n[62:0], 1'b0, qm_n[62:0], 1'b1};
        end
    end

    // POST1 inputs: the remainder w and w + d (POST1 = 1: summed here from the carry-save pair)
    logic [WW-1:0] pw, pwd;
    always_comb begin
        if (POST1) begin
            pw  = ws + wc;
            pwd = (ws ^ wc ^ dfix) + (((ws & wc) | (ws & dfix) | (wc & dfix)) << 1);
        end else begin
            pw  = wsum;
            pwd = wsum + dfix;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            fin   <= 1'b0;
        end else begin
            fin <= (state == S_POST1) && !kill;
            if (start && (state == S_IDLE || (OVL && state == S_POST1))) begin
                n_q    <= ma;
                d_q    <= mb;
                neg_q  <= sa ^ sb;
                neg_r  <= sa;
                bzero  <= (bw == '0);
                a_orig <= aw;
                word_q <= word;
                is_rem <= fn[1];
                state  <= PRE1 ? S_PRE1 : S_PRE0;
            end else if (kill) begin
                state <= S_IDLE;
            end else begin
                unique case (state)
                    S_IDLE: ;
                    S_PRE0: begin                       // steps n = dz - nz + 1, rounded up to a multiple of U
                        logic [7:0] n, nr;
                        logic       none;
                        n    = {1'b0, dz} - {1'b0, nz} + 8'd1;
                        none = n[7] || n == 8'd0 || dz[6];  // N < D, or D == 0
                        nr   = (n + 8'(U - 1)) & ~8'(U - 1);
                        shd  <= dz + 7'd4;
                        shn  <= dz + 7'd4 - (none ? 7'd0 : nr[6:0]);
                        cnt  <= none ? 7'd0 : nr[6:0] / 7'(U);
                        none_q <= 1'b0;
                        state <= S_PRE1;
                    end
                    S_PRE1: begin                       // normalization
                        logic [WW-1:0] w0;
                        logic [7:0]    n, nr;
                        logic [1:0]    pad;
                        logic          none;
                        if (PRE1) begin
                            // w0 = N << (dz + 4 - nr) = (N << nz) << (3 - pad), pad = nr - n (U <= 4)
                            n    = {1'b0, dz} - {1'b0, nz} + 8'd1;
                            none = n[7] || n == 8'd0 || dz[6];
                            nr   = (n + 8'(U - 1)) & ~8'(U - 1);
                            pad  = 2'(nz - dz - 7'd1) & 2'(U - 1);
                            w0   = (WW'(n_q) << nz) << (2'd3 - pad);
                            dfix <= (WW'(d_q) << dz) << 4;
                            shd  <= dz + 7'd4;
                            none_q <= none;             // quotient 0, remainder N (w0 is not used)
                            cnt  <= none ? 7'd0 : nr[6:0] / 7'(U);
                            state <= none ? (POST1 ? S_POST1 : S_POST0) : S_ITER;
                        end else begin
                            w0    = WW'({7'd0, n_q}) << shn;
                            dfix  <= WW'({7'd0, d_q}) << shd;
                            state <= (cnt == 7'd0) ? (POST1 ? S_POST1 : S_POST0) : S_ITER;
                        end
                        ws    <= w0;
                        wc    <= '0;
                        est   <= w0[WW-2 -: 4];         // top of 2 * w0
                        qq    <= '0;
                        qm    <= '0;                    // (the first digit is +1: w0 >= 0)
                    end
                    S_ITER: begin
                        ws <= ws_n; wc <= wc_n; qq <= qq_n; qm <= qm_n; est <= est_n;
                        cnt <= cnt - 7'd1;
                        if (cnt == 7'd1) state <= POST1 ? S_POST1 : S_POST0;
                    end
                    S_POST0: begin                      // remainder
                        wsum  <= ws + wc;
                        state <= S_POST1;
                    end
                    default: state <= S_IDLE;           // S_POST1
                endcase
            end
            if (state == S_POST1) begin                 // negative remainder: + d and QM; denormalization
                logic [63:0] rv, qv;
                rv    = none_q ? n_q : 64'((pw[WW-1] ? pwd : pw) >> shd);
                qv    = none_q ? '0  : (pw[WW-1] ? qm : qq);
                fr    <= bzero ? (is_rem ? a_orig : '1) : (is_rem ? rv : qv);
                fneg  <= !bzero && (is_rem ? neg_r : neg_q);
                fword <= word_q;
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (rst_n && start && !(state == S_IDLE || (OVL && state == S_POST1)))
            $error("mm_div_srt: start while busy (state %0d)", state);
    initial if (PRE1 && U > 4) $error("mm_div_srt: PRE1 needs U <= 4");
`endif

    logic [63:0] r;
    assign r    = fneg ? -fr : fr;
    assign y    = fword ? sext32(r) : r;
    assign busy = (state != S_IDLE);
    assign post = (state == S_POST1);
    // the engine is free (IDLE) or in POST1 two cycles from now, if nothing starts in between
    assign acc2 = state == S_IDLE || state == S_POST1 || state == S_POST0 ||
                  (state == S_ITER && cnt <= (POST1 ? 7'd2 : 7'd1));
    assign done = fin;
endmodule

// one level of 3:2 carry-save compression on N rows of W bits (rows beyond the last full group pass through)
module mm_csa_rows #(parameter int N = 3, parameter int W = 128) (
    input  logic [N-1:0][W-1:0]                 in,
    output logic [(N/3)*2+(N%3)-1:0][W-1:0]     out
);
    for (genvar g = 0; g < N / 3; g++) begin : g_grp
        logic [W-1:0] a, b, c;
        assign a = in[3*g]; assign b = in[3*g+1]; assign c = in[3*g+2];
        assign out[2*g]   = a ^ b ^ c;
        assign out[2*g+1] = {((a & b) | (a & c) | (b & c)), 1'b0} >> 0;
    end
    for (genvar r = 0; r < N % 3; r++) begin : g_rest
        assign out[(N/3)*2+r] = in[(N/3)*3+r];
    end
endmodule

// Pipelined multiplier (Booth radix-4 partial products and a carry-save tree
// cut by pipeline registers, final carry-propagate add in the last stage).
//   EX1: Booth encoding, partial products (33 rows + negation row + sign-extension constant) and three
//        3:2 levels (35 -> 11 rows) -> registers
//   EX2: four 3:2 levels (11 -> 3 rows) -> registers
//   EX3: last 3:2 level, 128-bit add, result selection (y, combinational from the EX2 registers)
// The partial products use the sign-extension constant: row i = {~s_i, low 65 bits} - 2^65 (weight 2^2i).
module mm_mul_pipe (
    input  logic        clk,
    input  logic [2:0]  fn,         // EX1: funct3 (0 MUL, 1 MULH, 2 MULHSU, 3 MULHU)
    input  logic        word,
    input  logic [63:0] a,
    input  logic [63:0] b,
    output logic [63:0] y           // EX3
);
    localparam int W  = 128;
    localparam int NP = 33;         // Booth digits of the 65-bit multiplier
    localparam int R0 = NP + 2;
    function automatic int nxt(int n); return (n / 3) * 2 + (n % 3); endfunction
    localparam int R1 = nxt(R0), R2 = nxt(R1), R3 = nxt(R2);              // EX1: 35 -> 24 -> 16 -> 11
    localparam int R4 = nxt(R3), R5 = nxt(R4), R6 = nxt(R5), R7 = nxt(R6); // EX2: 11 -> 8 -> 6 -> 4 -> 3
    localparam int R8 = nxt(R7);                                           // EX3: 3 -> 2

    // ---- EX1: partial products ----
    logic [R0-1:0][W-1:0] pp;
    always_comb begin
        logic [64:0] ae;
        logic [66:0] be;            // multiplier, sign-extended, with be[-1] = 0 at bit 0
        logic [65:0] x, r;
        logic [W-1:0] k, nr;
        logic [2:0]  d;
        logic        neg;
        ae = {(fn == 3'd1 || fn == 3'd2) && a[63], a};
        be = {{2{(fn == 3'd1) && b[63]}}, b, 1'b0};
        k  = '0;
        nr = '0;
        for (int i = 0; i < NP; i++) begin
            d   = be[2*i +: 3];
            neg = d[2] && !(d[1] && d[0]);
            unique case (d)
                3'b001, 3'b010, 3'b101, 3'b110: x = {ae[64], ae};
                3'b011, 3'b100:                 x = {ae, 1'b0};
                default:                        x = '0;
            endcase
            r     = neg ? ~x : x;
            pp[i] = W'({!r[65], r[64:0]}) << (2 * i);
            nr[2*i] = neg;
            k     = k - (W'(1) << (65 + 2 * i));
        end
        pp[NP]     = nr;
        pp[NP + 1] = k;
    end
    logic [R1-1:0][W-1:0] t1;
    logic [R2-1:0][W-1:0] t2;
    logic [R3-1:0][W-1:0] t3, q3;
    mm_csa_rows #(R0, W) c1 (.in(pp), .out(t1));
    mm_csa_rows #(R1, W) c2 (.in(t1), .out(t2));
    mm_csa_rows #(R2, W) c3 (.in(t2), .out(t3));

    // ---- EX2 ----
    logic [2:0] fn2, fn3;
    logic       word2, word3;
    logic [R4-1:0][W-1:0] t4;
    logic [R5-1:0][W-1:0] t5;
    logic [R6-1:0][W-1:0] t6;
    logic [R7-1:0][W-1:0] t7, q7;
    mm_csa_rows #(R3, W) c4 (.in(q3), .out(t4));
    mm_csa_rows #(R4, W) c5 (.in(t4), .out(t5));
    mm_csa_rows #(R5, W) c6 (.in(t5), .out(t6));
    mm_csa_rows #(R6, W) c7 (.in(t6), .out(t7));

    // ---- EX3 ----
    logic [R8-1:0][W-1:0] t8;
    logic [W-1:0]         p;
    mm_csa_rows #(R7, W) c8 (.in(q7), .out(t8));
    assign p = t8[0] + t8[1];
    assign y = word3 ? {{32{p[31]}}, p[31:0]} : (fn3[1:0] == 2'd0 ? p[63:0] : p[127:64]);

    always_ff @(posedge clk) begin
        q3 <= t3; fn2 <= fn; word2 <= word;
        q7 <= t7; fn3 <= fn2; word3 <= word2;
    end
endmodule
