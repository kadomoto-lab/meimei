// Issue queue (one per execution unit, 2 enqueue ports).
//  - up to IQ_ENQ enqueues per cycle
//  - operand readiness tracked per entry, updated by wakeup broadcasts
//  - selects the oldest ready entry and issues it, 1 per cycle; age is kept in an N x N matrix
//    (entries are enqueued in program order)
//  - entries younger than a redirect are flushed
//  - the unit has one register write port: a uop with fixed latency L writes it L+1 cycles after
//    issue, and is selected only if that cycle is still free (write ports are scheduled
//    at issue, in the issue queue); iterative units (DIV/FDIV) are blocked while busy
module issue_queue
    import mm_pkg::*;
#(
    parameter int N = 16,
    parameter bit DUAL = 1'b0,    // second dequeue port for BJU uops (own pipeline and write port)
    parameter bit CSR  = 1'b1     // the queue may hold CSR uops (the ROB-head check is built only then)
)
(
    input  logic       clk,
    input  logic       rst_n,
    input  redirect_t  redir,
    // enqueue
    input  logic [IQ_ENQ-1:0] enq_valid,
    input  uop_t [IQ_ENQ-1:0] enq_uop,
    input  logic [IQ_ENQ-1:0] enq_rdy1,
    input  logic [IQ_ENQ-1:0] enq_rdy2,
    input  logic [IQ_ENQ-1:0] enq_rdy3,
    input  logic [IQ_ENQ-1:0][3:1] enq_fresh,  // operand woken by a fixed-latency unit last cycle
    output logic [$clog2(IQ_MAX+1)-1:0] free_cnt,
    // memory dependence: loads marked ld_wait issue only after all older stores have an address
    input  sq_ptr_t    sq_head,
    input  sq_ptr_t    sq_tail,
    input  sq_ptr_t    sq_rdy_ptr,
    input  logic [SQ_N-1:0] sq_addrv,   // StoreSet: the awaited store has its address
    input  rob_ptr_t [SQ_N-1:0] sq_rob, //   ... or the SQ entry no longer holds it
    // unit classes that may not issue this cycle (iterative unit busy)
    input  logic [N_FU-1:0] blk,
    // CSR instructions issue only when they are the oldest instruction
    input  rob_ptr_t   rob_head,
    // wakeup
    input  logic  [N_WK-1:0] wk_valid,
    input  preg_t [N_WK-1:0] wk_preg,
    // issue: the selected uop leaves only when it also won its register-file read ports
    // (iss_ok, read-port arbitration in IS); a loser stays and is selected again
    output logic  iss_valid,
    output logic  iss_sv,         // IQ_KILL_LATE: selected, before the squash of the selected entry (for the
    output logic  iss2_sv,        //   speculative wakeup only: a squashed uop wakes only squashed consumers)
    output uop_t  iss_uop,
    output logic  [3:1] iss_fresh,  // operand woken by a fixed-latency unit 1 or 2 cycles ago
    output logic  iss_l1,         // IQ_WK_FAST: selected (before the squash), latency 1, writes a register
    output logic  iss2_l1,
                                    // (taken from the bypass network, no register-file read)
    input  logic  iss_ok,
    output logic  iss2_valid,     // DUAL: BJU port
    output uop_t  iss2_uop,
    output logic  [3:1] iss2_fresh,
    input  logic  iss2_ok,
    input  logic  [N_WK-1:0] wk_fixed,  // wakeup ports of fixed-latency units
    input  logic  [N_WK-1:0] wk_lds,    // LD_SPEC_WAKE: load wakeup ports (the value is in the bypass one cycle)
    // SPEC_WAKE: a latency-1 uop wakes its consumers when it is selected, before it knows whether it
    // won its read ports; a loser's destination comes back here the next cycle:
    // waiting operands on it are not ready again and entries depending on it do not issue this cycle
    input  logic  [N_CAN-1:0] cancel_v,
    input  preg_t [N_CAN-1:0] cancel_p,
    // register cache (RC_TRACK): sources 1, 2 found in the cache at
    // dispatch (valid from the next cycle), the cache entries readable next cycle, and this cycle's
    // writes into the cache (writer k puts preg rcw_p[k] into entry rcw_i[k])
    input  logic [IQ_ENQ-1:0][2:1]            enq_rcu,
    input  logic [IQ_ENQ-1:0][2:1][RC_IW-1:0] enq_rci,
    input  logic [N_RC-1:0]                   rc_ok,
    input  logic [N_RCW-1:0]                  rcw_v,
    input  preg_t [N_RCW-1:0]                 rcw_p,
    input  logic [N_RCW-1:0][RC_IW-1:0]       rcw_i,
    // the selected uops' sources read from the cache in RR (no register-file read port)
    output logic [2:1]                        iss_rcu,
    output logic [2:1][RC_IW-1:0]             iss_rci,
    output logic [2:1]                        iss2_rcu,
    output logic [2:1][RC_IW-1:0]             iss2_rci
);

    logic [N-1:0] v, r1, r2, r3;
    logic [1:0]   a1 [N], a2 [N], a3 [N];   // cycles since a fixed-latency wakeup (bit0: 1, bit1: 2)
    // ENQ_DELAY: an entry enqueued last cycle also takes last cycle's wakeups from
    // registered copies; the effective ready / freshness bits (re*, ae*) are what the stored bits would be
    // if those wakeups had been applied at the enqueue
    logic [N-1:0]      re1, re2, re3;
    // LD_SPEC_WAKE: source woken by a load last cycle (le*: including the enqueue cycle's, ENQ_DELAY); such
    // an operand is in the bypass network only for an issue now
    logic [N-1:0]      la1, la2, la3, le1, le2, le3;
    logic [1:0]        ae1 [N], ae2 [N], ae3 [N];
    uop_t q [N];
    logic [MAXL:0] wbb;     // wbb[k]: the write port is taken k+1 cycles from now

    // memory dependence wait of each entry (LD_WAIT_REG: evaluated from the SQ state of the previous
    // cycle and registered, so the SQ pointers are not on the select path; a load is released one
    // cycle later)
    logic [N-1:0] lw_now, lw_q, lw;
    always_comb
        for (int i = 0; i < N; i++)
            lw_now[i] = q[i].ld_wait && (MDP_STORESET ?
                        // the awaited store is still in the SQ (not drained or squashed), is that store,
                        // is older than the load, and has no address yet
                        (sq_dist(sq_head, q[i].ld_wsq) >= 0 && sq_dist(sq_head, q[i].ld_wsq) < sq_dist(sq_head, sq_tail) &&
                         !sq_addrv[q[i].ld_wsq[SQ_PW-2:0]] && sq_rob[q[i].ld_wsq[SQ_PW-2:0]] == q[i].ld_wrob &&
                         rob_older(q[i].ld_wrob, q[i].rob_idx)) :
                        (sq_dist(sq_head, q[i].sq_ptr) > sq_dist(sq_head, sq_rdy_ptr)));
    assign lw = LD_WAIT_REG ? lw_q : lw_now;
    // IQ_CAN_BIT: the speculative-wakeup ports (cancel index k) that woke each source last cycle; a cancel
    // then needs no tag compare (a port carries one wakeup per cycle, so a cancel of port k is for the tag it
    // broadcast last cycle)
    logic [N_CAN-1:0] cw1 [N], cw2 [N], cw3 [N];
    function automatic logic [N_CAN-1:0] spec_m(preg_t p, logic [N_WK-1:0] wv, preg_t [N_WK-1:0] wp);
        for (int k = 0; k < N_CAN; k++) spec_m[k] = wv[rc_wport(k)] && wp[rc_wport(k)] == p;
    endfunction
    logic [N-1:0] cn1, cn2, cn3;        // source woken last cycle by a wakeup cancelled now
    always_comb
        for (int i = 0; i < N; i++) begin
            cn1[i] = IQ_CAN_BIT ? |(cw1[i] & cancel_v) : cancelled(q[i].psrc1, cancel_v, cancel_p);
            cn2[i] = IQ_CAN_BIT ? |(cw2[i] & cancel_v) : cancelled(q[i].psrc2, cancel_v, cancel_p);
            cn3[i] = IQ_CAN_BIT ? |(cw3[i] & cancel_v) : cancelled(q[i].psrc3, cancel_v, cancel_p);
        end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (rst_n && SPEC_WAKE && IQ_CAN_BIT)
            for (int i = 0; i < N; i++)
                if (v[i] && ({cn1[i], cn2[i], cn3[i]} != {cancelled(q[i].psrc1, cancel_v, cancel_p),
                     cancelled(q[i].psrc2, cancel_v, cancel_p), cancelled(q[i].psrc3, cancel_v, cancel_p)}))
                    $error("IQ_CAN_BIT mismatch: entry %0d srcs %0d %0d %0d bits %b%b%b", i,
                           q[i].psrc1, q[i].psrc2, q[i].psrc3, cn1[i], cn2[i], cn3[i]);
`endif
    // ready entries, excluding those squashed this cycle (IQ_KILL_LATE: the squash is applied to the selected
    // entry only; entries are in program order, so if the oldest ready entry is squashed every younger one is)
    logic [N-1:0] rdy, rdy2, kv;
    always_comb begin
        for (int i = 0; i < N; i++) begin
            logic base, bj;
            kv[i] = killed_by(redir, q[i].rob_idx);
            base = v[i] && re1[i] && re2[i] && re3[i] && !(!IQ_KILL_LATE && kv[i]) && !lw[i] &&
                   !cn1[i] && !cn2[i] && !cn3[i] &&
                   !blk[q[i].fu] && !(CSR && q[i].fu == FU_CSR && q[i].rob_idx != rob_head);
            bj = DUAL && q[i].fu == FU_BJU;
            rdy[i]  = base && !bj && !(q[i].lat != '0 && wbb[q[i].lat]);
            rdy2[i] = base && bj;
        end
    end

    // debug: an otherwise ready entry is held back by the write-port reservation
    logic wbb_stall;
    always_comb begin
        wbb_stall = 1'b0;
        for (int i = 0; i < N; i++)
            if (v[i] && re1[i] && re2[i] && re3[i] && q[i].lat != '0 && wbb[q[i].lat]) wbb_stall = 1'b1;
    end

    // age matrix: older[i][j] = entry j was enqueued before entry i
    logic [N-1:0] older [N];
    // enqueue slots: the lowest free entries (enq_valid is a prefix: slot 0 first)
    logic [$clog2(N)-1:0] enq_slot [IQ_ENQ];
    logic [IQ_ENQ-1:0]    enq_ok;
    logic [N-1:0]         enq_mask;
    always_comb begin
        int c;
        c = 0;
        for (int e = 0; e < IQ_ENQ; e++) enq_slot[e] = '0;
        for (int i = 0; i < N; i++)
            if (!v[i] && c < IQ_ENQ) begin enq_slot[c] = i[$clog2(N)-1:0]; c++; end
        enq_mask = '0;
        for (int e = 0; e < IQ_ENQ; e++) begin
            enq_ok[e] = enq_valid[e] && e < c;
            if (enq_ok[e]) enq_mask[enq_slot[e]] = 1'b1;
        end
    end
    for (genvar i = 0; i < N; i++) begin : g_age
        always_ff @(posedge clk) begin
            logic [N-1:0] row;
            row = older[i] & ~enq_mask;                 // a new entry is younger than everything
            for (int e = 0; e < IQ_ENQ; e++)
                if (enq_ok[e] && enq_slot[e] == i) begin
                    row = v;                            // older: every valid entry ...
                    for (int e2 = 0; e2 < e; e2++)      // ... and those enqueued before it this cycle
                        if (enq_ok[e2]) row[enq_slot[e2]] = 1'b1;
                end
            older[i] <= row;
        end
    end

    // oldest-first select: a ready entry with no older ready entry
    function automatic logic [$clog2(N)-1:0] oldest(logic [N-1:0] r);
        oldest = '0;
        for (int i = 0; i < N; i++) if (r[i] && (r & older[i]) == '0) oldest = i[$clog2(N)-1:0];
    endfunction
    // IQ_ONEHOT: the oldest ready entry as a one-hot vector (exactly one bit: the age matrix is a total order)
    function automatic logic [N-1:0] oldest_oh(logic [N-1:0] r);
        for (int i = 0; i < N; i++) oldest_oh[i] = r[i] && (r & older[i]) == '0;
    endfunction
    logic [$clog2(N)-1:0] sel, sel2;
    logic [N-1:0]         g, g2;
    // register cache state of each source: kept while its entry is readable (cleared for good once the
    // entry is overwritten or dropped), set when the value is written into the cache
    // this cycle (usable now, as the write lands before RR)
    logic [2:1]            rcu [N];
    logic [2:1][RC_IW-1:0] rci [N];
    logic [2:1]            rcu_now [N];
    logic [2:1][RC_IW-1:0] rci_now [N];
    always_comb
        for (int i = 0; i < N; i++)
            for (int s = 1; s <= 2; s++) begin
                preg_t p;
                logic [N_RCW-1:0] m;
                logic [RC_IW-1:0] ci;
                p = (s == 1) ? q[i].psrc1 : q[i].psrc2;
                ci = '0;
                for (int k = 0; k < N_RCW; k++) begin
                    m[k] = rcw_v[k] && rcw_p[k] == p;
                    ci = ci | ({RC_IW{m[k]}} & rcw_i[k]);
                end
                rcu_now[i][s] = REGCACHE && RC_TRACK && (rcu[i][s] && rc_ok[rci[i][s]] || m != '0);
                rci_now[i][s] = (m != '0) ? ci : rci[i][s];
            end

    if (IQ_ONEHOT) begin : g_oh
        // the AND-OR is made per bit over a column of the entries (reduction OR: a tree, where an
        // accumulating loop "u = u | q[i]" was built as a chain over the entries)
        localparam int UW = $bits(uop_t);
        logic [N-1:0] qcol [UW];
        logic [N-1:0] fcol [3:1];
        logic [N-1:0] l1col;
        logic [N-1:0] rucol [2:1];
        logic [N-1:0] ricol [2:1][RC_IW];
        always_comb
            for (int i = 0; i < N; i++) begin
                for (int b = 0; b < UW; b++) qcol[b][i] = q[i][b];
                for (int s = 1; s <= 2; s++) begin
                    rucol[s][i] = rcu_now[i][s];
                    for (int b = 0; b < RC_IW; b++) ricol[s][b][i] = rci_now[i][s][b];
                end
                l1col[i]   = q[i].lat == 3'd1 && q[i].rf_wen;
                fcol[1][i] = ae1[i] != '0 || le1[i];
                fcol[2][i] = ae2[i] != '0 || le2[i];
                fcol[3][i] = ae3[i] != '0 || le3[i];
            end
        always_comb begin
            uop_t u, u2;
            logic [3:1] f, f2;
            g  = oldest_oh(rdy);
            g2 = oldest_oh(rdy2);
            sel = '0; sel2 = '0;
            for (int i = 0; i < N; i++) begin
                if (g[i])  sel  = sel  | i[$clog2(N)-1:0];
                if (g2[i]) sel2 = sel2 | i[$clog2(N)-1:0];
            end
            for (int b = 0; b < UW; b++) begin
                u[b]  = |(g  & qcol[b]);
                u2[b] = |(g2 & qcol[b]);
            end
            for (int k = 1; k <= 3; k++) begin
                f[k]  = |(g  & fcol[k]);
                f2[k] = |(g2 & fcol[k]);
            end
            iss_sv     = |rdy;
            iss2_sv    = |rdy2;
            iss_valid  = |rdy && !(IQ_KILL_LATE && |(g & kv));
            iss_uop    = u;
            iss_fresh  = f;
            iss2_valid = |rdy2 && !(IQ_KILL_LATE && |(g2 & kv));
            iss2_uop   = u2;
            iss2_fresh = f2;
            iss_l1     = |(g  & l1col);
            iss2_l1    = |(g2 & l1col);
            for (int s = 1; s <= 2; s++) begin
                iss_rcu[s]  = |(g  & rucol[s]);
                iss2_rcu[s] = |(g2 & rucol[s]);
                for (int b = 0; b < RC_IW; b++) begin
                    iss_rci[s][b]  = |(g  & ricol[s][b]);
                    iss2_rci[s][b] = |(g2 & ricol[s][b]);
                end
            end
        end
    end else begin : g_ix
        always_comb begin
            g = '0; g2 = '0;
            sel        = oldest(rdy);
            iss_sv     = |rdy;
            iss2_sv    = |rdy2;
            iss_valid  = |rdy && !(IQ_KILL_LATE && kv[sel]);
            iss_uop    = q[sel];
            iss_fresh  = {ae3[sel] != '0 || le3[sel], ae2[sel] != '0 || le2[sel], ae1[sel] != '0 || le1[sel]};
            sel2       = oldest(rdy2);
            iss2_valid = |rdy2 && !(IQ_KILL_LATE && kv[sel2]);
            iss2_uop   = q[sel2];
            iss2_fresh = {ae3[sel2] != '0 || le3[sel2], ae2[sel2] != '0 || le2[sel2], ae1[sel2] != '0 || le1[sel2]};
            iss_l1     = |rdy  && q[sel].lat == 3'd1 && q[sel].rf_wen;
            iss2_l1    = |rdy2 && q[sel2].lat == 3'd1 && q[sel2].rf_wen;
            iss_rcu    = rcu_now[sel];
            iss_rci    = rci_now[sel];
            iss2_rcu   = rcu_now[sel2];
            iss2_rci   = rci_now[sel2];
        end
    end

    always_comb begin
        free_cnt = '0;
        for (int i = 0; i < N; i++) if (!v[i]) free_cnt = free_cnt + 1'b1;
    end

    // match vector + reduction OR (an early return in the loop is built as a chain over the ports)
    function automatic logic woken(preg_t p, logic [N_WK-1:0] wv, preg_t [N_WK-1:0] wp);
        logic [N_WK-1:0] m;
        for (int k = 0; k < N_WK; k++) m[k] = wv[k] && wp[k] == p;
        return |m;
    endfunction
    function automatic logic cancelled(preg_t p, logic [N_CAN-1:0] cv, preg_t [N_CAN-1:0] cp);
        logic [N_CAN-1:0] m;
        for (int k = 0; k < N_CAN; k++) m[k] = cv[k] && cp[k] == p;
        return |m;
    endfunction
    logic [N_WK-1:0] wk_fx, wk_ld;
    assign wk_fx = wk_valid & wk_fixed;
    assign wk_ld = wk_valid & wk_lds;
    // LD_SPEC_WAKE: load wakeups of the enqueue cycle, per entry (ENQ_DELAY)
    logic [3:1] jdl [N];
    always_ff @(posedge clk)
        for (int i = 0; i < N; i++) begin
            logic [3:1] d;
            d = '0;
            for (int e = 0; e < IQ_ENQ; e++)
                if (LD_SPEC_WAKE && ENQ_DELAY && enq_ok[e] && enq_slot[e] == i)
                    d = d | {woken(enq_uop[e].psrc3, wk_ld, wk_preg), woken(enq_uop[e].psrc2, wk_ld, wk_preg),
                             woken(enq_uop[e].psrc1, wk_ld, wk_preg)};
            jdl[i] <= rst_n ? d : '0;
        end
    always_comb
        for (int i = 0; i < N; i++) begin
            le1[i] = LD_SPEC_WAKE && (la1[i] || jdl[i][1]);
            le2[i] = LD_SPEC_WAKE && (la2[i] || jdl[i][2]);
            le3[i] = LD_SPEC_WAKE && (la3[i] || jdl[i][3]);
        end
    // the compares are made only for the (at most IQ_ENQ) entries enqueued last cycle, from their
    // registered slots and sources
    logic [IQ_ENQ-1:0]          jv;
    logic [N-1:0]               js  [IQ_ENQ];      // one-hot slot
    logic [IQ_ENQ-1:0][3:1]     jw, jf;             // woken last cycle (any / fixed-latency unit)
    // (the compares are made in the enqueue cycle, against that cycle's wakeups, like the queued entries'
    // compares, and only their results are registered: the next cycle starts from an AND-OR)
    always_ff @(posedge clk) begin
        for (int e = 0; e < IQ_ENQ; e++) begin
            jv[e]    <= rst_n && enq_ok[e];
            js[e]    <= N'(1) << enq_slot[e];
            jw[e][1] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc1, wk_valid, wk_preg);
            jw[e][2] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc2, wk_valid, wk_preg);
            jw[e][3] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc3, wk_valid, wk_preg);
            jf[e][1] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc1, wk_fx, wk_preg);
            jf[e][2] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc2, wk_fx, wk_preg);
            jf[e][3] <= ENQ_DELAY && enq_ok[e] && woken(enq_uop[e].psrc3, wk_fx, wk_preg);
        end
    end
    // IQ_WK_FAST: the same bits registered per entry (the slot decode is made in the enqueue cycle)
    logic [3:1] jd [N], jdf [N];
    always_ff @(posedge clk)
        for (int i = 0; i < N; i++) begin
            logic [3:1] d, f;
            d = '0; f = '0;
            for (int e = 0; e < IQ_ENQ; e++)
                if (ENQ_DELAY && enq_ok[e] && enq_slot[e] == i) begin
                    d = d | {woken(enq_uop[e].psrc3, wk_valid, wk_preg), woken(enq_uop[e].psrc2, wk_valid, wk_preg),
                             woken(enq_uop[e].psrc1, wk_valid, wk_preg)};
                    f = f | {woken(enq_uop[e].psrc3, wk_fx, wk_preg), woken(enq_uop[e].psrc2, wk_fx, wk_preg),
                             woken(enq_uop[e].psrc1, wk_fx, wk_preg)};
                end
            jd[i]  <= rst_n ? d : '0;
            jdf[i] <= rst_n ? f : '0;
        end
    always_comb
        for (int i = 0; i < N; i++) begin
            logic [3:1] d, f;
            d = '0; f = '0;
            for (int e = 0; e < IQ_ENQ; e++)
                if (jv[e] && js[e][i]) begin d = d | jw[e]; f = f | jf[e]; end
            if (IQ_WK_FAST) begin d = jd[i]; f = jdf[i]; end
            re1[i] = r1[i] || d[1];
            re2[i] = r2[i] || d[2];
            re3[i] = r3[i] || d[3];
            ae1[i] = {a1[i][1], a1[i][0] || f[1]};
            ae2[i] = {a2[i][1], a2[i][0] || f[2]};
            ae3[i] = {a3[i][1], a3[i][0] || f[3]};
        end

    // IQ_WK_FAST: next ready bits apart from this cycle's wakeups (an entry enqueued now is not valid now)
    logic [N-1:0] rb1, rb2, rb3;
    always_comb
        for (int i = 0; i < N; i++) begin
            rb1[i] = re1[i] && !cn1[i];
            rb2[i] = re2[i] && !cn2[i];
            rb3[i] = re3[i] && !cn3[i];
            for (int e = 0; e < IQ_ENQ; e++)
                if (enq_ok[e] && enq_slot[e] == i) begin
                    rb1[i] = enq_rdy1[e]; rb2[i] = enq_rdy2[e]; rb3[i] = enq_rdy3[e];
                end
        end
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v <= '0;
            wbb <= '0;
        end else begin
            wbb <= (wbb | ((iss_valid && iss_ok && iss_uop.lat != '0) ? (MAXL+1)'(1) << iss_uop.lat : '0)) >> 1;
            // wakeup + flush + issue
            for (int i = 0; i < N; i++) begin
                r1[i] <= re1[i]; r2[i] <= re2[i]; r3[i] <= re3[i];
                if (cn1[i]) r1[i] <= 1'b0;
                if (cn2[i]) r2[i] <= 1'b0;
                if (cn3[i]) r3[i] <= 1'b0;
                // (IQ_WK_FAST: assigned below as one OR with the wakeup last)
                cw1[i] <= spec_m(q[i].psrc1, wk_valid, wk_preg);
                cw2[i] <= spec_m(q[i].psrc2, wk_valid, wk_preg);
                cw3[i] <= spec_m(q[i].psrc3, wk_valid, wk_preg);
                if (woken(q[i].psrc1, wk_valid, wk_preg)) r1[i] <= 1'b1;
                if (woken(q[i].psrc2, wk_valid, wk_preg)) r2[i] <= 1'b1;
                if (woken(q[i].psrc3, wk_valid, wk_preg)) r3[i] <= 1'b1;
                a1[i] <= {ae1[i][0], woken(q[i].psrc1, wk_fx, wk_preg)};
                la1[i] <= woken(q[i].psrc1, wk_ld, wk_preg);
                la2[i] <= woken(q[i].psrc2, wk_ld, wk_preg);
                la3[i] <= woken(q[i].psrc3, wk_ld, wk_preg);
                a2[i] <= {ae2[i][0], woken(q[i].psrc2, wk_fx, wk_preg)};
                a3[i] <= {ae3[i][0], woken(q[i].psrc3, wk_fx, wk_preg)};
                if (killed_by(redir, q[i].rob_idx)) v[i] <= 1'b0;
                rcu[i] <= rcu_now[i];
                rci[i] <= rci_now[i];
            end
            if (IQ_WK_FAST)
                for (int i = 0; i < N; i++) begin
                    r1[i] <= (v[i] && woken(q[i].psrc1, wk_valid, wk_preg)) || rb1[i];
                    r2[i] <= (v[i] && woken(q[i].psrc2, wk_valid, wk_preg)) || rb2[i];
                    r3[i] <= (v[i] && woken(q[i].psrc3, wk_valid, wk_preg)) || rb3[i];
                end
            lw_q <= lw_now;
            if (iss_valid && iss_ok) v[sel] <= 1'b0;
            if (iss2_valid && iss2_ok) v[sel2] <= 1'b0;
            for (int e = 0; e < IQ_ENQ; e++)
                if (enq_ok[e]) begin
                    v[enq_slot[e]]  <= 1'b1;
                    q[enq_slot[e]]  <= enq_uop[e];
                    if (!IQ_WK_FAST) begin
                        r1[enq_slot[e]] <= enq_rdy1[e];
                        r2[enq_slot[e]] <= enq_rdy2[e];
                        r3[enq_slot[e]] <= enq_rdy3[e];
                    end
                    lw_q[enq_slot[e]] <= enq_uop[e].ld_wait;     // evaluated from the next cycle
                    // wakeups of the dispatch cycle (they reach the entry through ENQ_DELAY / enq_rdy*)
                    cw1[enq_slot[e]] <= spec_m(enq_uop[e].psrc1, wk_valid, wk_preg);
                    cw2[enq_slot[e]] <= spec_m(enq_uop[e].psrc2, wk_valid, wk_preg);
                    cw3[enq_slot[e]] <= spec_m(enq_uop[e].psrc3, wk_valid, wk_preg);
                    rcu[enq_slot[e]]  <= enq_rcu[e];
                    rci[enq_slot[e]]  <= enq_rci[e];
                    // woken in the dispatch cycle: as if woken while in the queue
                    a1[enq_slot[e]] <= {enq_fresh[e][1], !ENQ_DELAY && woken(enq_uop[e].psrc1, wk_fx, wk_preg)};
                    la1[enq_slot[e]] <= !ENQ_DELAY && woken(enq_uop[e].psrc1, wk_ld, wk_preg);
                    la2[enq_slot[e]] <= !ENQ_DELAY && woken(enq_uop[e].psrc2, wk_ld, wk_preg);
                    la3[enq_slot[e]] <= !ENQ_DELAY && woken(enq_uop[e].psrc3, wk_ld, wk_preg);
                    a2[enq_slot[e]] <= {enq_fresh[e][2], !ENQ_DELAY && woken(enq_uop[e].psrc2, wk_fx, wk_preg)};
                    a3[enq_slot[e]] <= {enq_fresh[e][3], !ENQ_DELAY && woken(enq_uop[e].psrc3, wk_fx, wk_preg)};
                end
        end
    end

endmodule
