// Decoupled frontend:
//
//   BPU --(fetch block prediction)--> FTQ --> IFU --(predecode check)--> IBuffer --> backend
//
//  BPU : banked BTB (one bank per halfword slot of the block, 2-bit counters = TAGE base predictor)
//        + TAGE (4 tagged tables, geometric global history 4/8/16/32 blocks)
//        + speculative RAS. One fetch block per cycle, 0-bubble.
//        Global history: one bit per fetch block (did the block end in a taken CFI),
//        checkpointed in the FTQ and repaired on IFU/backend redirects.
//  FTQ : queue of predicted fetch blocks; lets the BPU run ahead of the IFU and keeps the
//        per-block RAS checkpoint used by backend redirects. Entries are released at commit.
//  IFU : fetches the block, finds the instruction boundaries (RVC), expands compressed
//        instructions, and corrects obvious BPU mistakes early (unpredicted / mistargeted JAL,
//        "taken" on a non-CFI or inside an instruction) -> IFU redirect.
//        A 32-bit instruction in the last slot is completed with the first halfword after the
//        block and delivered with this block; the next sequential block then skips that halfword.
//  IBuf: instruction buffer, up to FETCH_W in / DEC_W out per cycle.
//
// Instruction memory is modelled as an ideal banked SRAM read in the fetch cycle (no ICache).
module frontend
    import mm_pkg::*;
    import mm_rvc_pkg::*;
#(
    parameter logic [63:0] RESET_PC = 64'h0
)
(
    input  logic        clk,
    input  logic        rst_n,
    // instruction memory load port
    input  logic        imem_wr_en,
    input  logic [IMEM_AW-1:0] imem_wr_addr,
    input  logic [31:0] imem_wr_data,
    // backend redirect (already selected and registered by the backend)
    input  redirect_t   be_redir,
    // commit-time training (one entry per commit slot, in program order) / FTQ release
    input  logic [DEC_W-1:0]        cu_valid,
    input  logic [DEC_W-1:0][63:0]  cu_pc,
    input  logic [DEC_W-1:0][63:0]  cu_target,
    input  logic [DEC_W-1:0]        cu_taken,
    input  cfi_t [DEC_W-1:0]        cu_type,
    input  logic [DEC_W-1:0]        cu_call,
    input  logic [DEC_W-1:0]        cu_rvc,      // the CFI is a compressed instruction
    input  ftq_ptr_t [DEC_W-1:0]    cu_ftq,      // FTQ entry of the CFI (history used to predict it)
    output int                      cu_free,     // CFIs that may commit next cycle
    input  logic        cmt_ftq_valid,
    input  ftq_ptr_t    cmt_ftq,
    // FTQ PC memory: block start and predicted target, read by the backend
    output logic [63:0] pcm_start  [FTQ_N],
    output logic [63:0] pcm_target [FTQ_N],
    // IBuffer -> backend
    output fetch_t [DEC_W-1:0] ib_out,
    output logic   [DEC_W-1:0] ib_valid,
    input  logic   [$clog2(DEC_W+1)-1:0] ib_deq
);

    // ------------------------------------------------------------------
    // instruction memory (256 x 32-bit, loaded by the testbench)
    // ------------------------------------------------------------------
    logic [63:0]          im_addr;
    logic [NSLOT:0][15:0] im_data;
    mm_imem u_imem (.clk, .addr(im_addr), .data(im_data),
                    .wr_en(imem_wr_en), .wr_addr(imem_wr_addr), .wr_data(imem_wr_data));

    // ------------------------------------------------------------------
    // BTB : NSLOT banks (halfword slot in the block) x BTB_SETS, 12-bit tag
    //   (for 32-bit-only code the set / tag bits are those of the earlier word-banked BTB)
    // ------------------------------------------------------------------
    localparam int SET_W = $clog2(BTB_SETS);
    function automatic logic [SLOT_W-1:0] btb_bank(logic [63:0] p); return p[1 +: SLOT_W]; endfunction
    function automatic logic [SET_W-1:0]  btb_set(logic [63:0] p);  return p[1 + SLOT_W +: SET_W]; endfunction
    function automatic logic [11:0]       btb_tagf(logic [63:0] p); return p[1 + SLOT_W + SET_W +: 12]; endfunction
    logic        btb_v      [NSLOT][BTB_SETS];
    logic [11:0] btb_tag    [NSLOT][BTB_SETS];
    cfi_t        btb_type   [NSLOT][BTB_SETS];
    logic        btb_call   [NSLOT][BTB_SETS];
    logic        btb_rvc    [NSLOT][BTB_SETS];     // CFI length (return address of a call)
    logic [1:0]  btb_ctr    [NSLOT][BTB_SETS];
    logic [BTB_TGT_W-1:0] btb_target [NSLOT][BTB_SETS];   // target[BTB_TGT_W:1]
    // full target of a BTB entry: upper bits from the CFI pc
    function automatic logic [63:0] btb_full(logic [63:0] pc, logic [BTB_TGT_W-1:0] t);
        return {pc[63:BTB_TGT_W+1], t, 1'b0};
    endfunction
    // predicted target: upper bits from the block start (BP_TGT_START: no adder
    // on the prediction path) or from the CFI's pc
    function automatic logic [63:0] bp_full(logic [63:0] start, logic [63:0] cpc, logic [BTB_TGT_W-1:0] t);
        return btb_full(BP_TGT_START ? start : cpc, t);
    endfunction

    // RAS
    logic [63:0] ras [RAS_N];
    // RAS_WDELAY: a push is registered and written to the stack the next cycle, reads see it
    // through a bypass
    logic        rw_v;
    logic [$clog2(RAS_N)-1:0] rw_i;
    logic [63:0] rw_d;
    function automatic logic [63:0] ras_rd(logic [$clog2(RAS_N)-1:0] i, logic [63:0] q, logic qv,
                                           logic [$clog2(RAS_N)-1:0] qi, logic [63:0] qd);
        return (RAS_WDELAY && qv && qi == i) ? qd : q;
    endfunction
    logic [$clog2(RAS_N)-1:0] ras_sp;   // points at the top entry

    // TAGE
    // TS sets x TAGE_WAYS ways; entry e = set * TAGE_WAYS + way
    localparam int TSI_W = TAGE_IDX_W - $clog2(TAGE_WAYS);
    localparam int TE = 1 << TAGE_IDX_W;
    logic [TE-1:0]         t_v   [TAGE_NT];
    logic [TAGE_TAG_W-1:0] t_tag [TAGE_NT][TE];
    logic [2:0]            t_ctr [TAGE_NT][TE];
    logic [TE-1:0][1:0]    t_u   [TAGE_NT];
    // TAGE_RAM: write port of each table's tag / counter RAM (from the training) and read rows
    // (ports 0..NCHK-1: s1 chunks, port NCHK: the training read)
    logic [TAGE_NT-1:0]    tt_we, tc_we;
    logic [TAGE_IDX_W-1:0] tt_a [TAGE_NT], tc_a [TAGE_NT];
    logic [TAGE_TAG_W-1:0] tt_d [TAGE_NT];
    logic [2:0]            tc_d [TAGE_NT];

    function automatic logic [TE-1:0][1:0] age_u(logic [TE-1:0][1:0] u);
        for (int e = 0; e < TE; e++) age_u[e] = {1'b0, u[e][1]};
    endfunction
    logic [12:0]           t_reset_cnt;
    logic [HIST_W-1:0]    hist;

    function automatic int hist_len(int t);
        return HIST_PATH ? TAGE_HIST_P[t] : TAGE_HIST_B[t];
    endfunction
    // history update for one fetch block (taken: block ended in a taken CFI at pc -> tgt)
    function automatic logic [HIST_W-1:0] upd_hist(logic [HIST_W-1:0] h, logic taken,
                                                   logic [63:0] pc, logic [63:0] tgt);
        logic [14:0] hash;
        hash = {2'b00, pc[9:1], 4'b0000} ^ tgt[16:2];       // path hash
        if (HIST_PATH) return taken ? ((h << 2) ^ HIST_W'(hash)) : h;
        else           return {h[HIST_W-2:0], taken};
    endfunction
    function automatic logic [15:0] fold(logic [HIST_W-1:0] h, int len, int w);
        logic [15:0] r;
        r = '0;
        for (int i = 0; i < HIST_W; i++)
            if (i < len) r[i % w] = r[i % w] ^ h[i];
        return r;
    endfunction
    // index "pc" of an aligned chunk (mode 2): the chunk number, placed at bit 1 like a pc
    localparam int NCHK = NSLOT / (1 << BP_ALIGN_W) + 1;     // chunks touched by a block
    function automatic logic [63:0] line_ipc(logic [63-(1+BP_ALIGN_W):0] ln);
        return 64'({ln, 1'b0});
    endfunction
    // pc used to index the predictors for the CFI in slot pos of the block at start
    function automatic logic [63:0] bp_ipc(logic [63:0] start, int pos);
        logic [63:0] p;
        p = start + 64'(2 * pos);
        return (BP_IDX_MODE == 1) ? start : (BP_IDX_MODE == 2) ? line_ipc(p[63:1+BP_ALIGN_W]) : p;
    endfunction
    // position xor-ed into the predictor tags
    function automatic logic [SLOT_W-1:0] bp_tpos(logic [63:0] start, int pos);
        logic [63:0] p;
        p = start + 64'(2 * pos);
        return (BP_IDX_MODE == 1) ? SLOT_W'(pos) : (BP_IDX_MODE == 2) ? SLOT_W'(p[1 +: BP_ALIGN_W]) : '0;
    endfunction
    function automatic logic [TSI_W-1:0] t_index(int t, logic [63:0] pc, logic [HIST_W-1:0] h);
        logic [15:0] f;
        f = fold(h, hist_len(t), TSI_W);
        return pc[1 +: TSI_W] ^ pc[1 + TSI_W +: TSI_W] ^ f[TSI_W-1:0];
    endfunction
    function automatic logic [TAGE_TAG_W-1:0] t_tagof(int t, logic [63:0] pc, logic [HIST_W-1:0] h);
        logic [15:0] f1, f2;
        f1 = fold(h, hist_len(t), TAGE_TAG_W);
        f2 = fold(h, hist_len(t), TAGE_TAG_W - 1);
        return pc[2 +: TAGE_TAG_W] ^ pc[12 +: TAGE_TAG_W] ^ f1[TAGE_TAG_W-1:0] ^ {f2[TAGE_TAG_W-2:0], 1'b0} ^ TAGE_TAG_W'(pc[1]);
    endfunction
    // tag of the CFI in slot pos (the position is xor-ed into the tag)
    function automatic logic [TAGE_TAG_W-1:0] t_tag_at(int t, logic [63:0] start, int pos, logic [HIST_W-1:0] h);
        return t_tagof(t, bp_ipc(start, pos), h) ^ TAGE_TAG_W'(bp_tpos(start, pos));
    endfunction
    // TAGE provider counter as a signed confidence (-7..+7 odd); base: +-3 from the 2-bit counter
    // (generic lookup, used by the training logic and the single-stage s1 predictor)
    function automatic int tage_conf(logic [63:0] start, int pos, logic [HIST_W-1:0] h, logic [1:0] basectr);
        int c;
        c = 2 * int'(basectr) - 3;
        for (int t = 0; t < TAGE_NT; t++) begin
            logic [TSI_W-1:0] ix;
            logic [TAGE_TAG_W-1:0] tg;
            ix = t_index(t, bp_ipc(start, pos), h);
            tg = t_tag_at(t, start, pos, h);
            for (int w = TAGE_WAYS - 1; w >= 0; w--)
                if (ENABLE_TAGE && t_v[t][int'(ix) * TAGE_WAYS + w] && t_tag[t][int'(ix) * TAGE_WAYS + w] == tg)
                    c = 2 * int'(t_ctr[t][int'(ix) * TAGE_WAYS + w]) - 7;
        end
        return c;
    endfunction

    // ---------------- SC (statistical corrector) ----------------
    localparam int SCE = 1 << SC_IDX_W;
    logic [SCE-1:0][5:0] sc_t [SC_NT];      // 6-bit signed counters

    function automatic logic [SC_IDX_W-1:0] sc_index(int k, logic [63:0] pc, logic [HIST_W-1:0] h, logic tdir);
        logic [15:0] f;
        f = fold(h, SC_HIST[k], SC_IDX_W);
        return pc[2 +: SC_IDX_W] ^ ((k == 0) ? {tdir, {(SC_IDX_W-1){1'b0}}} : f[SC_IDX_W-1:0]) ^ SC_IDX_W'(pc[1]);
    endfunction
    function automatic int sc_sum(logic [63:0] pc, logic [HIST_W-1:0] h, logic tdir);
        int sum;
        sum = 0;
        for (int k = 0; k < SC_NT; k++)
            sum += 2 * int'($signed(sc_t[k][sc_index(k, pc, h, tdir)])) + 1;
        return sum;
    endfunction
    // TAGE-SC style: SC counters are summed together with the TAGE confidence (weighted);
    // the sign of the total is the final direction
    localparam int SC_TAGE_W = 6;
    function automatic int sc_total(logic [63:0] pc, logic [HIST_W-1:0] h, int tconf);
        return sc_sum(pc, h, tconf > 0) + SC_TAGE_W * tconf;
    endfunction
    function automatic logic sc_dir(logic [63:0] pc, logic [HIST_W-1:0] h, int tconf);
        if (!ENABLE_SC) return tconf > 0;
        return sc_total(pc, h, tconf) >= 0;
    endfunction

    // ---------------- ITTAGE (indirect target predictor) ----------------
    localparam int ITE = 1 << IT_IDX_W;
    logic [ITE-1:0]        it_v   [IT_NT];
    logic [ITE-1:0]        it_u   [IT_NT];
    logic [IT_TAG_W-1:0]   it_tag [IT_NT][ITE];
    logic [BTB_TGT_W-1:0]  it_tgt [IT_NT][ITE];    // target[BTB_TGT_W:1]
    logic [1:0]            it_ctr [IT_NT][ITE];

    function automatic logic [IT_IDX_W-1:0] it_index(int k, logic [63:0] pc, logic [HIST_W-1:0] h);
        logic [15:0] f;
        f = fold(h, IT_HIST[k], IT_IDX_W);
        return pc[2 +: IT_IDX_W] ^ pc[2 + IT_IDX_W +: IT_IDX_W] ^ f[IT_IDX_W-1:0] ^ IT_IDX_W'(pc[1]);
    endfunction
    function automatic logic [IT_TAG_W-1:0] it_tagof(int k, logic [63:0] pc, logic [HIST_W-1:0] h);
        logic [15:0] f1, f2;
        f1 = fold(h, IT_HIST[k], IT_TAG_W);
        f2 = fold(h, IT_HIST[k], IT_TAG_W - 1);
        return pc[2 +: IT_TAG_W] ^ f1[IT_TAG_W-1:0] ^ {f2[IT_TAG_W-2:0], 1'b0} ^ IT_TAG_W'(pc[1]);
    endfunction
    function automatic logic [IT_TAG_W-1:0] it_tag_at(int k, logic [63:0] start, int pos, logic [HIST_W-1:0] h);
        return it_tagof(k, bp_ipc(start, pos), h) ^ IT_TAG_W'(bp_tpos(start, pos));
    endfunction
    function automatic logic [63:0] it_target(logic [63:0] start, int pos, logic [HIST_W-1:0] h, logic [63:0] dflt);
        logic [63:0] prov_t, alt_t;
        logic prov, alt;
        logic [1:0] prov_c;
        prov = 1'b0; alt = 1'b0; prov_t = dflt; alt_t = dflt; prov_c = '0;
        for (int k = 0; k < IT_NT; k++) begin
            logic [IT_IDX_W-1:0] ix;
            ix = it_index(k, bp_ipc(start, pos), h);
            if (it_v[k][ix] && it_tag[k][ix] == it_tag_at(k, start, pos, h)) begin
                alt = prov; alt_t = prov_t;
                prov = 1'b1; prov_t = bp_full(start, start + 64'(2 * pos), it_tgt[k][ix]); prov_c = it_ctr[k][ix];
            end
        end
        if (!ENABLE_ITTAGE || !prov) return dflt;
        return (prov_c == 2'd0 && alt) ? alt_t : prov_t;
    endfunction

    // FTQ
    logic [HIST_W-1:0] ftq_hist [FTQ_N];
    logic [63:0] ftq_start  [FTQ_N];
    logic        ftq_taken  [FTQ_N];
    logic [SLOT_W-1:0] ftq_off [FTQ_N];
    logic [FTQ_N-1:0]  ftq_cross;       // last instruction delivered from the block straddles its end
    logic [63:0] ftq_target [FTQ_N];
    logic [$clog2(RAS_N)-1:0] ftq_ras_sp [FTQ_N];
    ftq_ptr_t ftq_tail, ifu_ptr, ftq_cmt;

    // redirect target (REDIR_PC_LATE: a re-executed instruction's pc from its FTQ entry, read with the
    // registered redirect)
    logic [63:0] be_tgt;
    assign be_tgt = (REDIR_PC_LATE && be_redir.flush_self)
                    ? ftq_start[be_redir.ftq_idx[FTQ_PW-2:0]] + 64'(2 * int'(be_redir.off)) : be_redir.target;
    // ---------------- training queue (commit -> BPU training, one CFI per cycle) ----------------
    logic        upd_valid, upd_taken, upd_call, upd_rvc;
    logic [63:0] upd_pc, upd_target;
    cfi_t        upd_type;
    logic [HIST_W-1:0] upd_h;               // global history the CFI was predicted with
    logic [SLOT_W-1:0] upd_pos;             // CFI position in its fetch block
    typedef struct packed {
        logic [63:0] pc, target;
        logic taken, call, rvc;
        cfi_t typ;
        logic [HIST_W-1:0] h;
        logic [SLOT_W-1:0] pos;
    } tr_t;
    // position of a committing CFI in its fetch block
    logic [SLOT_W-1:0] cu_posv [DEC_W];
    always_comb
        for (int k = 0; k < DEC_W; k++)
            cu_posv[k] = SLOT_W'(cu_pc[k][1 +: SLOT_W] - ftq_start[cu_ftq[k][FTQ_PW-2:0]][1 +: SLOT_W]);
    tr_t trq [TRQ_N];
    int  trq_head, trq_cnt;
    // table indices / tags of the CFI being trained (pure functions of its pc, position and history),
    // block start, and whether the target's upper bits equal the block start's (the predicted target
    // takes them from there, BP_TGT_START)
    logic [63:0]           upd_ust;
    logic [TSI_W-1:0]      upd_tix [TAGE_NT];
    logic [TAGE_TAG_W-1:0] upd_ttg [TAGE_NT];
    logic [IT_IDX_W-1:0]   upd_iix [IT_NT];
    logic [IT_TAG_W-1:0]   upd_itg [IT_NT];
    logic                  upd_fit;
    typedef struct packed {
        logic [63:0]           ust;
        logic [TAGE_NT-1:0][TSI_W-1:0]      tix;
        logic [TAGE_NT-1:0][TAGE_TAG_W-1:0] ttg;
        logic [IT_NT-1:0][IT_IDX_W-1:0]     iix;
        logic [IT_NT-1:0][IT_TAG_W-1:0]     itg;
        logic                  fit;
    } upd_hash_t;
    function automatic upd_hash_t upd_hash(logic [63:0] pc, logic [63:0] tgt, logic [SLOT_W-1:0] pos, logic [HIST_W-1:0] h);
        upd_hash_t r;
        r.ust = pc - 64'(2 * int'(pos));
        for (int t = 0; t < TAGE_NT; t++) begin
            r.tix[t] = t_index(t, bp_ipc(r.ust, int'(pos)), h);
            r.ttg[t] = t_tag_at(t, r.ust, int'(pos), h);
        end
        for (int k = 0; k < IT_NT; k++) begin
            r.iix[k] = it_index(k, bp_ipc(r.ust, int'(pos)), h);
            r.itg[k] = it_tag_at(k, r.ust, int'(pos), h);
        end
        r.fit = tgt[63:BTB_TGT_W+1] == (BP_TGT_START ? r.ust[63:BTB_TGT_W+1] : pc[63:BTB_TGT_W+1]);
        return r;
    endfunction
    upd_hash_t uh;
    always_comb begin
        upd_ust = uh.ust; upd_fit = uh.fit;
        for (int t = 0; t < TAGE_NT; t++) begin upd_tix[t] = uh.tix[t]; upd_ttg[t] = uh.ttg[t]; end
        for (int k = 0; k < IT_NT; k++) begin upd_iix[k] = uh.iix[k]; upd_itg[k] = uh.itg[k]; end
    end
    // TRAIN_SRAM: table rows of the CFI being trained, read synchronously in the stage before the
    // training (SRAM-style: index registered, data the next cycle); else read in the training cycle
    logic                  upd_tv   [TAGE_NT][TAGE_WAYS];
    logic [TAGE_TAG_W-1:0] upd_ttag [TAGE_NT][TAGE_WAYS];
    logic [2:0]            upd_tctr [TAGE_NT][TAGE_WAYS];
    logic [1:0]            upd_tu   [TAGE_NT][TAGE_WAYS];
    logic                  upd_iv   [IT_NT];
    logic [IT_TAG_W-1:0]   upd_itag [IT_NT];
    logic [BTB_TGT_W-1:0]  upd_itgt [IT_NT];
    logic [1:0]            upd_ictr [IT_NT];
    logic                  upd_iu   [IT_NT];
    logic [TSI_W-1:0]      u0_tix   [TAGE_NT];      // TAGE row read for the training (U0, TRAIN_SRAM)
    logic [TAGE_TAG_W-1:0] rm_tg [NCHK+1][TAGE_NT][TAGE_WAYS];   // TAGE_RAM read rows
    logic [2:0]            rm_ct [NCHK+1][TAGE_NT][TAGE_WAYS];
    logic                  ur_bv;
    logic [11:0]           ur_btag;
    logic [1:0]            ur_bctr;
    logic [BTB_TGT_W-1:0]  ur_btgt;
    if (MULTI_CFI_COMMIT) begin : g_trq
        // TRAIN_STAGE: the queue head is registered with its hashes, the tables are read and written
        // the next cycle
        tr_t       uq;
        logic      uq_v;
        upd_hash_t uq_h;
        upd_hash_t h0;                     // hashes of the queue head (U0)
        logic      pop;
        assign h0 = upd_hash(trq[trq_head].pc, trq[trq_head].target, trq[trq_head].pos, trq[trq_head].h);
        // (TRAIN_SRAM: a row the training in U1 writes this cycle is read before the write by the head;
        // the next training of that entry starts from the older value. Waiting for it instead cost
        // string_mem +7%)
        assign pop  = trq_cnt > 0;
        always_comb for (int t = 0; t < TAGE_NT; t++) u0_tix[t] = TRAIN_SRAM ? h0.tix[t] : upd_tix[t];
        if (TRAIN_SRAM) begin : g_rows
            always_ff @(posedge clk) begin
                for (int t = 0; t < TAGE_NT; t++)
                    for (int w = 0; w < TAGE_WAYS; w++) begin
                        upd_tv[t][w]   <= t_v[t][int'(h0.tix[t]) * TAGE_WAYS + w];
                        upd_ttag[t][w] <= TAGE_RAM ? rm_tg[NCHK][t][w] : t_tag[t][int'(h0.tix[t]) * TAGE_WAYS + w];
                        upd_tctr[t][w] <= TAGE_RAM ? rm_ct[NCHK][t][w] : t_ctr[t][int'(h0.tix[t]) * TAGE_WAYS + w];
                    end
                for (int k = 0; k < IT_NT; k++) begin
                    upd_iv[k]   <= it_v[k][h0.iix[k]];
                    upd_itag[k] <= it_tag[k][h0.iix[k]];
                    upd_itgt[k] <= it_tgt[k][h0.iix[k]];
                    upd_ictr[k] <= it_ctr[k][h0.iix[k]];
                end
                if (TRAIN_U_REG) begin
                    for (int t = 0; t < TAGE_NT; t++)
                        for (int w = 0; w < TAGE_WAYS; w++)
                            upd_tu[t][w] <= t_u[t][int'(h0.tix[t]) * TAGE_WAYS + w];
                    for (int k = 0; k < IT_NT; k++) upd_iu[k] <= it_u[k][h0.iix[k]];
                end
                ur_bv   <= btb_v[btb_bank(trq[trq_head].pc)][btb_set(trq[trq_head].pc)];
                ur_btag <= btb_tag[btb_bank(trq[trq_head].pc)][btb_set(trq[trq_head].pc)];
                ur_bctr <= btb_ctr[btb_bank(trq[trq_head].pc)][btb_set(trq[trq_head].pc)];
                ur_btgt <= btb_target[btb_bank(trq[trq_head].pc)][btb_set(trq[trq_head].pc)];
            end
        end
        always_comb begin
            tr_t u;
            u          = TRAIN_STAGE ? uq : trq[trq_head];
            upd_valid  = TRAIN_STAGE ? uq_v : trq_cnt > 0;
            upd_pc     = u.pc;     upd_target = u.target;
            upd_taken  = u.taken;  upd_call   = u.call;
            upd_rvc    = u.rvc;    upd_type   = u.typ;
            upd_h      = u.h;
            upd_pos    = u.pos;
            uh         = TRAIN_STAGE ? uq_h : upd_hash(u.pc, u.target, u.pos, u.h);
            cu_free    = TRQ_N - trq_cnt;      // pushes this cycle must fit before the pop
        end
        always_ff @(posedge clk) begin
            uq   <= trq[trq_head];
            uq_h <= h0;
            if (!rst_n) uq_v <= 1'b0;
            else        uq_v <= pop;
        end
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                trq_head <= 0; trq_cnt <= 0;
            end else begin
                int n;
                n = 0;
                for (int k = 0; k < DEC_W; k++) begin
                    if (cu_valid[k]) begin
                        trq[(trq_head + trq_cnt + n) % TRQ_N] <= '{pc: cu_pc[k], target: cu_target[k], taken: cu_taken[k],
                            call: cu_call[k], rvc: cu_rvc[k], typ: cu_type[k], h: ftq_hist[cu_ftq[k][FTQ_PW-2:0]],
                            pos: cu_posv[k]};
                        n++;
                    end
                end
                // pop: the head moves to the training stage (TRAIN_STAGE) or is trained this cycle
                if (pop) trq_head <= (trq_head + 1) % TRQ_N;
                trq_cnt <= trq_cnt + n - int'(pop);
            end
        end
    end else begin : g_direct      // one CFI per cycle, trained in its commit cycle
        always_comb begin
            upd_valid = 1'b0; upd_pc = '0; upd_target = '0; upd_taken = 1'b0; upd_call = 1'b0;
            upd_rvc = 1'b0; upd_type = CFI_BR; upd_h = '0; upd_pos = '0;
            for (int k = 0; k < DEC_W; k++) if (cu_valid[k]) begin
                upd_valid = 1'b1; upd_pc = cu_pc[k]; upd_target = cu_target[k]; upd_taken = cu_taken[k];
                upd_call = cu_call[k]; upd_rvc = cu_rvc[k]; upd_type = cu_type[k];
                upd_h = ftq_hist[cu_ftq[k][FTQ_PW-2:0]];
                upd_pos = cu_posv[k];
            end
            uh = upd_hash(upd_pc, upd_target, upd_pos, upd_h);
            cu_free = 1;
        end
        always_comb for (int t = 0; t < TAGE_NT; t++) u0_tix[t] = upd_tix[t];
    end

    // BTB entry of the CFI being trained (one read shared by the BTB / TAGE / ITTAGE training)
    logic upd_bhit;
    logic [1:0] upd_bctr;
    logic [BTB_TGT_W-1:0] upd_btgt;
    always_comb begin
        logic [SLOT_W-1:0] b;
        logic [SET_W-1:0] s;
        b = btb_bank(upd_pc);
        s = btb_set(upd_pc);
        if (TRAIN_SRAM) begin
            upd_bhit = ur_bv && ur_btag == btb_tagf(upd_pc);
            upd_bctr = ur_bctr;
            upd_btgt = ur_btgt;
        end else begin
            upd_bhit = btb_v[b][s] && btb_tag[b][s] == btb_tagf(upd_pc);
            upd_bctr = btb_ctr[b][s];
            upd_btgt = btb_target[b][s];
        end
    end
    // useful bits of the trained rows (TRAIN_U_REG: read with the other rows in U0)
    if (!(TRAIN_SRAM && TRAIN_U_REG && MULTI_CFI_COMMIT)) begin : g_urow_c
        always_comb begin
            for (int t = 0; t < TAGE_NT; t++)
                for (int w = 0; w < TAGE_WAYS; w++)
                    upd_tu[t][w] = t_u[t][int'(upd_tix[t]) * TAGE_WAYS + w];
            for (int k = 0; k < IT_NT; k++) upd_iu[k] = it_u[k][upd_iix[k]];
        end
    end
    if (!TRAIN_SRAM) begin : g_rows_c
        always_comb begin
            for (int t = 0; t < TAGE_NT; t++)
                for (int w = 0; w < TAGE_WAYS; w++) begin
                    upd_tv[t][w]   = t_v[t][int'(upd_tix[t]) * TAGE_WAYS + w];
                    upd_ttag[t][w] = TAGE_RAM ? rm_tg[NCHK][t][w] : t_tag[t][int'(upd_tix[t]) * TAGE_WAYS + w];
                    upd_tctr[t][w] = TAGE_RAM ? rm_ct[NCHK][t][w] : t_ctr[t][int'(upd_tix[t]) * TAGE_WAYS + w];
                end
            for (int k = 0; k < IT_NT; k++) begin
                upd_iv[k]   = it_v[k][upd_iix[k]];
                upd_itag[k] = it_tag[k][upd_iix[k]];
                upd_itgt[k] = it_tgt[k][upd_iix[k]];
                upd_ictr[k] = it_ctr[k][upd_iix[k]];
            end
        end
    end

    // TAGE_RAM: the training's table writes (the same decisions as the training block below: provider counter,
    // allocation of the first way with useful counter 0 in a longer-history table)
    always_comb begin
        int prov, ew [TAGE_NT], e [TAGE_NT];
        logic base, pdir, alloc;
        logic [2:0] pc;
        tt_we = '0; tc_we = '0;
        for (int t = 0; t < TAGE_NT; t++) begin tt_a[t] = '0; tc_a[t] = '0; tt_d[t] = '0; tc_d[t] = '0; end
        base = upd_bhit && upd_bctr[1];
        prov = -1;
        for (int t = 0; t < TAGE_NT; t++) begin
            e[t] = -1; ew[t] = 0;
            for (int w = TAGE_WAYS - 1; w >= 0; w--)
                if (upd_tv[t][w] && upd_ttag[t][w] == upd_ttg[t]) begin e[t] = int'(upd_tix[t]) * TAGE_WAYS + w; ew[t] = w; end
            if (e[t] >= 0) prov = t;
        end
        pdir = (prov >= 0) ? upd_tctr[prov][ew[prov]][2] : base;
        if (ENABLE_TAGE && upd_valid && upd_type == CFI_BR) begin
            if (prov >= 0) begin
                pc = upd_tctr[prov][ew[prov]];
                if (upd_taken ? pc != 3'd7 : pc != 3'd0) begin
                    tc_we[prov] = 1'b1;
                    tc_a[prov]  = TAGE_IDX_W'(e[prov]);
                    tc_d[prov]  = upd_taken ? pc + 1'b1 : pc - 1'b1;
                end
            end
            if (pdir != upd_taken) begin
                alloc = 1'b0;
                for (int t = 0; t < TAGE_NT; t++)
                    for (int w = 0; w < TAGE_WAYS; w++)
                        if (t > prov && !alloc && upd_tu[t][w] == 2'd0) begin
                            alloc = 1'b1;
                            tt_we[t] = 1'b1; tt_a[t] = TAGE_IDX_W'(int'(upd_tix[t]) * TAGE_WAYS + w); tt_d[t] = upd_ttg[t];
                            tc_we[t] = 1'b1; tc_a[t] = tt_a[t];                           tc_d[t] = upd_taken ? 3'd4 : 3'd3;
                        end
            end
        end
    end
    if (TAGE_RAM) begin : g_tram
        for (genvar t = 0; t < TAGE_NT; t++) begin : g_t
            logic [TAGE_TAG_W-1:0] tg_m [TE];
            logic [2:0]            ct_m [TE];
            always_ff @(posedge clk) begin
                if (tt_we[t]) tg_m[tt_a[t]] <= tt_d[t];
                if (tc_we[t]) ct_m[tc_a[t]] <= tc_d[t];
            end
            for (genvar p = 0; p <= NCHK; p++)
                for (genvar w = 0; w < TAGE_WAYS; w++) begin : g_rd
                    logic [TSI_W-1:0] ix;
                    if (p < NCHK) begin : g_s1
                        assign ix = s1_tix[p][t];
                    end else begin : g_u0
                        assign ix = u0_tix[t];
                    end
                    assign rm_tg[p][t][w] = tg_m[int'(ix) * TAGE_WAYS + w];
                    assign rm_ct[p][t][w] = ct_m[int'(ix) * TAGE_WAYS + w];
                end
        end
`ifndef SYNTHESIS
        // the same contents in t_tag / t_ctr for the reference lookups (predict(), checked against s2)
        always_ff @(posedge clk)
            for (int t = 0; t < TAGE_NT; t++) begin
                if (tt_we[t]) t_tag[t][tt_a[t]] <= tt_d[t];
                if (tc_we[t]) t_ctr[t][tc_a[t]] <= tc_d[t];
            end
`endif
    end

    // IBuffer
    fetch_t ibuf [IBUF_N];
    logic [IBUF_IW-1:0] ib_head;
    logic [IBUF_IW:0]   ib_count;

    // ------------------------------------------------------------------
    // BPU prediction of one fetch block
    // ------------------------------------------------------------------
    typedef struct packed {
        logic        taken;
        logic [SLOT_W-1:0] off;
        logic [63:0] target;
        logic        push;
        logic        pop;
        logic        rvc;      // length of the predicted CFI (push address = pc + 2 / 4)
    } bpred_t;

    // single-stage prediction of a block (s1 when the uBTB is disabled; slow, one lookup per slot)
    function automatic bpred_t predict(logic [63:0] start, logic [HIST_W-1:0] h,
                                       logic rok, logic [63:0] rtop, logic use_tage);
        bpred_t r;
        logic [63:0] p;
        logic [SLOT_W-1:0] b;
        logic [SET_W-1:0] s;
        r = '0;
        for (int i = 0; i < NSLOT; i++) begin
            p = start + 64'(2 * i);
            b = btb_bank(p);
            s = btb_set(p);
            if (!r.taken && btb_v[b][s] && btb_tag[b][s] == btb_tagf(p) &&
                (btb_type[b][s] != CFI_BR ||
                 (use_tage ? tage_conf(start, i, h, btb_ctr[b][s]) > 0 : btb_ctr[b][s][1]))) begin
                r.taken  = 1'b1;
                r.off    = SLOT_W'(i);
                r.rvc    = btb_rvc[b][s];
                r.target = (btb_type[b][s] == CFI_RET && rok) ? rtop : bp_full(start, p, btb_target[b][s]);
                r.pop    = (btb_type[b][s] == CFI_RET);
                r.push   = btb_call[b][s];
            end
        end
        return r;
    endfunction

    // ---------------- s2 / s3 lookup (BTB + TAGE, then ITTAGE in s3) ----------------
    // The BTB is read once per bank: bank b holds the slot (b - start slot) mod NSLOT of the block.
    // TAGE reads one set per table (block start + history) and matches each bank's CFI by
    // position. The per-bank results of s2 are passed to s3 (no second BTB / TAGE lookup).
    typedef struct packed {
        logic                 hit;
        cfi_t                 typ;
        logic                 call;
        logic                 rvc;
        logic [1:0]           ctr;
        logic [BTB_TGT_W-1:0] tgt;
        logic signed [3:0]    conf;      // TAGE confidence (-7..+7)
    } bank_rd_t;

    function automatic int bank_pos(logic [63:0] start, int b);
        return (b - int'(start[1 +: SLOT_W]) + NSLOT) % NSLOT;
    endfunction
    // first predicted-taken slot of a block given the per-bank taken bits
    function automatic int first_taken(logic [63:0] start, logic [NSLOT-1:0] tk);
        logic [2*NSLOT-1:0] r;
        r = {tk, tk} >> start[1 +: SLOT_W];
        for (int i = NSLOT - 1; i >= 0; i--) if (r[i]) first_taken = i;
        if (r[NSLOT-1:0] == '0) first_taken = -1;
    endfunction

    // ---------------- uBTB (s1 fast predictor, one entry per fetch block) ----------------
    logic [UBTB_N-1:0] ub_v;
    logic [62:0]       ub_tag  [UBTB_N];    // block start pc[63:1]
    logic [SLOT_W-1:0] ub_off  [UBTB_N];
    logic              ub_rvc  [UBTB_N];
    logic [63:0]       ub_tgt  [UBTB_N];
    logic              ub_ret  [UBTB_N];
    logic              ub_call [UBTB_N];
    logic [$clog2(UBTB_N)-1:0] ub_rr;

    function automatic bpred_t ubtb_predict(logic [63:0] start, logic rok, logic [63:0] rtop);
        bpred_t r;
        r = '0;
        for (int i = 0; i < UBTB_N; i++) begin
            if (ub_v[i] && ub_tag[i] == start[63:1]) begin
                r.taken  = 1'b1;
                r.off    = ub_off[i];
                r.rvc    = ub_rvc[i];
                r.target = (ub_ret[i] && rok) ? rtop : ub_tgt[i];
                r.pop    = ub_ret[i];
                r.push   = ub_call[i];
            end
        end
        return r;
    endfunction

    // s1: fast prediction (BTB + bimodal; with BPU_OVERRIDE = 0 also TAGE)
    logic [63:0] bpu_pc;
    // BP_LINE_PRE: chunk lines bpu_pc[63:1+BP_ALIGN_W] + r, written with bpu_pc
    logic [NCHK-1:0][63-(1+BP_ALIGN_W):0] s1_ln;
    function automatic logic [NCHK-1:0][63-(1+BP_ALIGN_W):0] chunk_lns(logic [63:0] p);
        for (int r = 0; r < NCHK; r++) chunk_lns[r] = p[63:1+BP_ALIGN_W] + (64-(1+BP_ALIGN_W))'(r);
    endfunction
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (rst_n && BP_LINE_PRE && s1_ln != chunk_lns(bpu_pc)) $error("BP_LINE_PRE: chunk lines differ from bpu_pc");
`endif
    bpred_t      s1p;
    logic        bp_taken;
    logic [SLOT_W-1:0] bp_off;
    logic [63:0] bp_target;
    logic        bp_push, bp_pop;
    logic [63:0] bp_next;
    // RAS top seen by s1: the micro-RAS (RAS_S3) or the speculative RAS
    logic        s1_rok;
    logic [63:0] s1_rtop, ras_top;
    logic        u_ok;               // micro-RAS: s1's RAS top, valid flag
    logic [63:0] u_top;
    assign ras_top = ras_rd(ras_sp, ras[ras_sp], rw_v, rw_i, rw_d);
    assign s1_rok  = RAS_S3 ? u_ok : 1'b1;
    assign s1_rtop = RAS_S3 ? u_top : ras_top;
    always_comb begin
        s1p       = (UBTB_EN && BPU_OVERRIDE) ? ubtb_predict(bpu_pc, s1_rok, s1_rtop)
                                                  : predict(bpu_pc, hist, s1_rok, s1_rtop, ENABLE_TAGE && !BPU_OVERRIDE);
        bp_taken  = s1p.taken;
        bp_off    = s1p.off;
        bp_target = s1p.target;
        bp_push   = s1p.push;
        bp_pop    = s1p.pop;
        bp_next   = bp_taken ? bp_target : bpu_pc + 64'(2 * NSLOT);
    end

    // s2: TAGE prediction of the block s1 enqueued last cycle; override s1 if different
    logic     s2_v;
    ftq_ptr_t s2_e;
    bpred_t   s2p;
    logic     s2_override;
    // pc and link (push) address of the predicted CFI of the s2 / s3 block, computed from the
    // stage's own prediction (not after the override select; one adder: start + (2 * off + len))
    logic [63:0] s2_cpc, s2_lnk, s3_cpc, s3_lnk;
    logic [$clog2(FTQ_N)-1:0] s2i;
    assign s2i = s2_e[FTQ_PW-2:0];
    bank_rd_t s2_bk [NSLOT], s3_bk [NSLOT];
    // Table read for s2: the BTB rows of every bank and the TAGE rows of every chunk are read for
    // the block being enqueued (bpu_pc / hist) and registered; s2 only compares tags and decides
    typedef struct packed {
        logic                 v;
        logic [11:0]          tag;
        cfi_t                 typ;
        logic                 call;
        logic                 rvc;
        logic [1:0]           ctr;
        logic [BTB_TGT_W-1:0] tgt;
    } btb_row_t;
    btb_row_t s1_btb [NSLOT], s2_btb [NSLOT];
    logic s1_rv [NCHK][TAGE_NT][TAGE_WAYS], s2_rv [NCHK][TAGE_NT][TAGE_WAYS];
    logic [TAGE_TAG_W-1:0] s1_rtg [NCHK][TAGE_NT][TAGE_WAYS], s2_rtg [NCHK][TAGE_NT][TAGE_WAYS];
    logic [2:0] s1_rct [NCHK][TAGE_NT][TAGE_WAYS], s2_rct [NCHK][TAGE_NT][TAGE_WAYS];
    logic [TAGE_TAG_W-1:0] s1_traw [NCHK][TAGE_NT], s2_traw [NCHK][TAGE_NT];   // tag hash of each chunk
    // per-stage copies of the block (pipeline registers) instead of FTQ reads:
    // start, history, RAS pointer and the prediction the FTQ entry holds
    typedef struct packed {
        logic              taken;
        logic [SLOT_W-1:0] off;
        logic [63:0]       target;
    } ftq_pred_t;
    logic [63:0] s2_st, s3_st, s2_ft, s3_ft;
    logic [HIST_W-1:0] s2_h, s3_h;
    // BP_PRE: per-bank set-up from the s1 block start (registered for s2 / s3)
    localparam bit PRE   = BP_PRE && BP_IDX_MODE == 2;
    localparam bit S3PRE = PRE && !ENABLE_SC;            // s3 direction = s2 direction
    localparam int CK_W  = $clog2(NCHK);
    logic [CK_W-1:0]       s1_bchk [NSLOT], s2_bchk [NSLOT], s3_bchk [NSLOT];   // chunk of bank b's slot
    logic [BP_ALIGN_W-1:0] s1_bxr  [NSLOT], s2_bxr  [NSLOT];                    // its position in the chunk
    logic [TAGE_TAG_W-1:0] s1_want [NSLOT][TAGE_NT], s2_want [NSLOT][TAGE_NT];  // expected TAGE tags
    logic [63:SLOT_W+2]    s1_sthi1, s2_sthi1, s3_sthi1;                         // start[63:SLOT_W+2] + 1
    logic [NSLOT-1:0]      s1_tk, s2_tk;                                         // direction of bank b's CFI
    logic signed [3:0]     s1_conf [NSLOT], s2_conf [NSLOT];                     // its TAGE confidence
    logic [$clog2(RAS_N)-1:0] s2_sp, s3_sp;
    ftq_pred_t s2_pp, s3_pp;
    logic [TSI_W-1:0] s1_tix [NCHK][TAGE_NT];     // TAGE row of chunk r in table t
    always_comb
        for (int r = 0; r < NCHK; r++)
            for (int t = 0; t < TAGE_NT; t++)
                s1_tix[r][t] = t_index(t, (BP_IDX_MODE == 1) ? bpu_pc : line_ipc(BP_LINE_PRE ? s1_ln[r] : bpu_pc[63:1+BP_ALIGN_W] + (64-(1+BP_ALIGN_W))'(r)), hist);
    always_comb begin
        logic [63-(1+SLOT_W):0] line0, line1, ln;
        logic [TSI_W-1:0] bix;
        logic [SET_W-1:0] bs;
        line0 = bpu_pc[63:1+SLOT_W];
        line1 = line0 + 1'b1;
        for (int r = 0; r < NCHK; r++)                  // r: aligned chunk of the block (mode 2)
            for (int t = 0; t < TAGE_NT; t++) begin
                bix = s1_tix[r][t];
                s1_traw[r][t] = t_tagof(t, (BP_IDX_MODE == 1) ? bpu_pc : line_ipc(BP_LINE_PRE ? s1_ln[r] : bpu_pc[63:1+BP_ALIGN_W] + (64-(1+BP_ALIGN_W))'(r)), hist);
                for (int w = 0; w < TAGE_WAYS; w++) begin
                    s1_rv[r][t][w]  = t_v[t][int'(bix) * TAGE_WAYS + w];
                    s1_rtg[r][t][w] = TAGE_RAM ? rm_tg[r][t][w] : t_tag[t][int'(bix) * TAGE_WAYS + w];
                    s1_rct[r][t][w] = TAGE_RAM ? rm_ct[r][t][w] : t_ctr[t][int'(bix) * TAGE_WAYS + w];
                end
            end
        for (int b = 0; b < NSLOT; b++) begin
            logic [SLOT_W-1:0] pos;
            logic [SLOT_W:0]   ps;
            pos = SLOT_W'(b) - bpu_pc[1 +: SLOT_W];                       // slot of bank b in the block
            ps  = (SLOT_W+1)'(bpu_pc[1 +: BP_ALIGN_W]) + (SLOT_W+1)'(pos);
            s1_bchk[b] = CK_W'(ps >> BP_ALIGN_W);
            s1_bxr[b]  = ps[BP_ALIGN_W-1:0];
            for (int t = 0; t < TAGE_NT; t++)
                s1_want[b][t] = s1_traw[CK_W'(ps >> BP_ALIGN_W)][t] ^ TAGE_TAG_W'(ps[BP_ALIGN_W-1:0]);
        end
        s1_sthi1 = bpu_pc[63:SLOT_W+2] + 1'b1;
        // BP_PRE: TAGE tag compares and the direction of every bank's CFI in s1 (registered for s2)
        for (int b = 0; b < NSLOT; b++) begin
            logic       prov;
            logic [2:0] pct;
            logic [CK_W-1:0] ck;
            int c;
            ck = s1_bchk[b];
            prov = 1'b0; pct = '0;
            for (int t = 0; t < TAGE_NT; t++)
                for (int w = TAGE_WAYS - 1; w >= 0; w--)
                    if (ENABLE_TAGE && s1_rv[ck][t][w] && s1_rtg[ck][t][w] == s1_want[b][t]) begin
                        prov = 1'b1; pct = s1_rct[ck][t][w];
                    end
            c = prov ? 2 * int'(pct) - 7 : 2 * int'(s1_btb[b].ctr) - 3;
            s1_conf[b] = 4'(c);
            // c > 0: the provider counter >= 4, or the bimodal counter >= 2
            s1_tk[b] = s1_btb[b].v && (s1_btb[b].typ != CFI_BR || ((ENABLE_TAGE && prov) ? pct[2] : s1_btb[b].ctr[1]));
        end
        for (int b = 0; b < NSLOT; b++) begin
            ln = (b < int'(bpu_pc[1 +: SLOT_W])) ? line1 : line0;    // slot wrapped into the next line
            bs = ln[SET_W-1:0];
            s1_btb[b].v    = btb_v[b][bs] && btb_tag[b][bs] == ln[SET_W +: 12];
            s1_btb[b].tag  = btb_tag[b][bs];
            s1_btb[b].typ  = btb_type[b][bs];
            s1_btb[b].call = btb_call[b][bs];
            s1_btb[b].rvc  = btb_rvc[b][bs];
            s1_btb[b].ctr  = btb_ctr[b][bs];
            s1_btb[b].tgt  = btb_target[b][bs];
        end
    end
    always_ff @(posedge clk) begin
        s2_btb <= s1_btb;
        s2_rv <= s1_rv; s2_rtg <= s1_rtg; s2_rct <= s1_rct; s2_traw <= s1_traw;
        s2_st <= bpu_pc;
        s2_ft <= bpu_pc + 64'(2 * NSLOT);       // fall-through of the block, ready for an override
        s3_ft <= s2_ft;
        s2_h  <= hist;
        s2_bchk <= s1_bchk; s2_bxr <= s1_bxr; s2_want <= s1_want; s2_sthi1 <= s1_sthi1;
        s2_tk <= s1_tk; s2_conf <= s1_conf;
        s3_bchk <= s2_bchk; s3_sthi1 <= s2_sthi1;
        s2_sp <= ras_sp;
        s2_pp <= '{taken: bp_taken, off: bp_off, target: bp_target};
        s3_st <= s2_st;
        s3_h  <= s2_h;
        s3_sp <= s2_sp;
        s3_pp <= s2_override ? '{taken: s2p.taken, off: s2p.off, target: s2p.target} : s2_pp;
    end
    // s2 decision results passed to s3 (S3PRE)
    logic              s2_fv, s3_fv;
    logic [SLOT_W-1:0] s2_off, s2_bw, s3_off, s3_bw;
    logic [63:0]       s3_cpcq, s3_lnkq;
    bank_rd_t          s3_sbk;
    logic [CK_W-1:0]   s3_schk;
    if (PRE) begin : g_s2p
        // the directions come from s1 (tag compares against the expected tags there); s2 finds the first
        // taken slot on narrow vectors and forms the carry-select CFI / link addresses
        always_comb begin
            logic [NSLOT-1:0]   tk, rt;
            logic [2*NSLOT-1:0] rr;
            logic [SLOT_W+2:0]  lo_c, lo_l;
            for (int b = 0; b < NSLOT; b++) begin
                s2_bk[b].hit  = s2_btb[b].v;
                s2_bk[b].typ  = s2_btb[b].typ;
                s2_bk[b].call = s2_btb[b].call;
                s2_bk[b].rvc  = s2_btb[b].rvc;
                s2_bk[b].ctr  = s2_btb[b].ctr;
                s2_bk[b].tgt  = s2_btb[b].tgt;
                s2_bk[b].conf = s2_conf[b];     // tag compares and directions were made in s1
                tk[b]         = s2_tk[b];
            end
            rr = {tk, tk} >> s2_st[1 +: SLOT_W];
            rt = rr[NSLOT-1:0];
            s2_fv  = rt != '0;
            s2_off = '0;
            for (int i = NSLOT - 1; i >= 0; i--) if (rt[i]) s2_off = SLOT_W'(i);
            s2_bw  = s2_st[1 +: SLOT_W] + s2_off;
            // low parts of every bank's CFI / link address in parallel; the decided bank's are selected
            lo_c = '0; lo_l = '0;
            for (int b = 0; b < NSLOT; b++) begin
                logic [SLOT_W-1:0] pb;
                logic [SLOT_W+2:0] c, l;
                pb = SLOT_W'(b) - s2_st[1 +: SLOT_W];
                c  = (SLOT_W+3)'(s2_st[SLOT_W+1:0]) + (SLOT_W+3)'({pb, 1'b0});
                l  = c + (SLOT_W+3)'(s2_btb[b].rvc ? 2 : 4);
                if (SLOT_W'(b) == s2_bw) begin lo_c = c; lo_l = l; end
            end
            s2_cpc = {lo_c[SLOT_W+2] ? s2_sthi1 : s2_st[63:SLOT_W+2], lo_c[SLOT_W+1:0]};
            s2p    = '0;
            s2_lnk = '0;
            if (s2_fv) begin
                s2p.taken  = 1'b1;
                s2p.off    = s2_off;
                s2p.rvc    = s2_bk[s2_bw].rvc;
                s2p.target = (s2_bk[s2_bw].typ == CFI_RET && !RAS_S3) ? ras_rd(s2_sp, ras[s2_sp], rw_v, rw_i, rw_d)
                                                                      : bp_full(s2_st, s2_cpc, s2_bk[s2_bw].tgt);
                s2_lnk     = {lo_l[SLOT_W+2] ? s2_sthi1 : s2_st[63:SLOT_W+2], lo_l[SLOT_W+1:0]};
                s2p.pop    = (s2_bk[s2_bw].typ == CFI_RET);
                s2p.push   = s2_bk[s2_bw].call;
            end
            s2_override = BPU_OVERRIDE && s2_v &&
                          (s2p.taken != s2_pp.taken ||
                           (s2p.taken && (s2p.off != s2_pp.off || (S2_TGT_CMP && s2p.target != s2_pp.target))));
        end
`ifndef SYNTHESIS
        always_ff @(posedge clk) if (rst_n && s2_v && s2p.taken &&
                                      (s2_cpc != s2_st + 64'(2 * s2_off) ||
                                       s2_lnk != s2_st + 64'(2 * s2_off + (s2p.rvc ? 2 : 4))))
            $error("s2 carry-select address %h + %0d: %h / %h", s2_st, s2_off, s2_cpc, s2_lnk);
`endif
        always_ff @(posedge clk) begin
            s3_fv <= s2_fv; s3_off <= s2_off; s3_bw <= s2_bw;
            s3_cpcq <= s2_cpc; s3_lnkq <= s2_lnk;
            // BP_S3_SEL: the decided bank's fields and its ITTAGE chunk, selected at the end of s2
            s3_sbk <= s2_bk[s2_bw]; s3_schk <= s2_bchk[s2_bw];
        end
    end else begin : g_s2o
        always_comb begin
            logic [63:0] st;
            logic [HIST_W-1:0] h;
            logic [NSLOT-1:0] tk;
            int off, bw;
            st = s2_st;                     // = ftq_start / ftq_hist of the s2 block
            h  = s2_h;
            for (int b = 0; b < NSLOT; b++) begin
                int pos, c;
                pos = bank_pos(st, b);
                s2_bk[b].hit  = s2_btb[b].v;
                s2_bk[b].typ  = s2_btb[b].typ;
                s2_bk[b].call = s2_btb[b].call;
                s2_bk[b].rvc  = s2_btb[b].rvc;
                s2_bk[b].ctr  = s2_btb[b].ctr;
                s2_bk[b].tgt  = s2_btb[b].tgt;
                c = 2 * int'(s2_btb[b].ctr) - 3;
                for (int t = 0; t < TAGE_NT; t++)
                    for (int w = TAGE_WAYS - 1; w >= 0; w--) begin
                        logic v;
                        logic [TAGE_TAG_W-1:0] tg, want;
                        logic [2:0] ct;
                        want = t_tag_at(t, st, pos, h);
                        if (BP_IDX_MODE != 0) begin
                            int r;
                            r = (BP_IDX_MODE == 2) ? (int'(st[1 +: BP_ALIGN_W]) + pos) >> BP_ALIGN_W : 0;
                            v = s2_rv[r][t][w]; tg = s2_rtg[r][t][w]; ct = s2_rct[r][t][w];
                            want = s2_traw[r][t] ^ TAGE_TAG_W'(bp_tpos(st, pos));   // hash from s1
                        end else begin
                            logic [TSI_W-1:0] ix;
                            ix = t_index(t, st + 64'(2 * pos), h);
                            v  = t_v[t][int'(ix) * TAGE_WAYS + w];
                            tg = t_tag[t][int'(ix) * TAGE_WAYS + w];
                            ct = t_ctr[t][int'(ix) * TAGE_WAYS + w];
                        end
                        if (ENABLE_TAGE && v && tg == want) c = 2 * int'(ct) - 7;
                    end
                s2_bk[b].conf = 4'(c);
                tk[b] = s2_bk[b].hit && (s2_bk[b].typ != CFI_BR || (ENABLE_TAGE ? c > 0 : s2_bk[b].ctr[1]));
            end
            off = first_taken(st, tk);
            bw  = (int'(st[1 +: SLOT_W]) + off) % NSLOT;
            s2p = '0;
            s2_cpc = st + 64'(2 * ((off >= 0) ? off : 0));
            s2_lnk = '0;
            if (off >= 0) begin
                logic [63:0] cpc;
                cpc        = st + 64'(2 * off);
                s2p.taken  = 1'b1;
                s2p.off    = SLOT_W'(off);
                s2p.rvc    = s2_bk[bw].rvc;
                // RAS_S3: s2 does not read the RAS (the return target is checked in s3)
                s2p.target = (s2_bk[bw].typ == CFI_RET && !RAS_S3) ? ras_rd(s2_sp, ras[s2_sp], rw_v, rw_i, rw_d)
                                                                    : bp_full(st, cpc, s2_bk[bw].tgt);
                s2_lnk     = st + 64'(2 * off + (s2_bk[bw].rvc ? 2 : 4));
                s2p.pop    = (s2_bk[bw].typ == CFI_RET);
                s2p.push   = s2_bk[bw].call;
            end
            // s2 override: taken / position differ (targets are compared in s3)
            s2_override = BPU_OVERRIDE && s2_v &&
                          (s2p.taken != s2_pp.taken ||
                           (s2p.taken && (s2p.off != s2_pp.off || (S2_TGT_CMP && s2p.target != s2_pp.target))));
        end
        assign s2_fv = 1'b0; assign s2_off = '0; assign s2_bw = '0;
        assign s3_fv = 1'b0; assign s3_off = '0; assign s3_bw = '0; assign s3_cpcq = '0; assign s3_lnkq = '0;
    end

    function automatic logic ftq_older(ftq_ptr_t a, ftq_ptr_t b);   // a older than b
        ftq_ptr_t d;
        d = b - a;
        return (d != '0) && !d[FTQ_PW-1];
    endfunction

    // s3: SC / ITTAGE re-prediction of the block s2 checked last cycle
    localparam bit S3_EN = BPU_OVERRIDE && (ENABLE_SC || ENABLE_ITTAGE);
    logic     s3_v;
    ftq_ptr_t s3_e;
    bpred_t   s3p;
    logic     s3_override;
    logic [$clog2(FTQ_N)-1:0] s3i;
    assign s3i = s3_e[FTQ_PW-2:0];
    always_ff @(posedge clk) s3_bk <= s2_bk;      // s3 is always the block s2 looked up last cycle
    // ITTAGE rows of every chunk of the s2 block, read in s2 for s3 (the SRAM read
    // starts early and s3 only compares)
    typedef struct packed {
        logic                 v;
        logic [IT_TAG_W-1:0]  tag;
        logic [BTB_TGT_W-1:0] tgt;
        logic [1:0]           ctr;
    } it_row_t;
    it_row_t s2_itr [NCHK][IT_NT], s3_itr [NCHK][IT_NT];
    always_comb
        for (int r = 0; r < NCHK; r++)
            for (int k = 0; k < IT_NT; k++) begin
                logic [IT_IDX_W-1:0] ix;
                ix = it_index(k, (BP_IDX_MODE == 1) ? s2_st : line_ipc(s2_st[63:1+BP_ALIGN_W] + (64-(1+BP_ALIGN_W))'(r)), s2_h);
                s2_itr[r][k].v   = it_v[k][ix];
                s2_itr[r][k].tag = it_tag[k][ix];
                s2_itr[r][k].tgt = it_tgt[k][ix];
                s2_itr[r][k].ctr = it_ctr[k][ix];
            end
    always_ff @(posedge clk) s3_itr <= s2_itr;
    // S3PRE: expected ITTAGE tag of every bank's slot (chunk hash of the s2 block + position in the chunk)
    logic [IT_TAG_W-1:0] s2_itw [NSLOT][IT_NT], s3_itw [NSLOT][IT_NT];
    logic [IT_TAG_W-1:0] s2_sitw [IT_NT], s3_sitw [IT_NT];     // BP_S3_SEL: of the decided bank
    always_comb begin
        logic [IT_TAG_W-1:0] raw [NCHK][IT_NT];
        for (int r = 0; r < NCHK; r++)
            for (int k = 0; k < IT_NT; k++)
                raw[r][k] = it_tagof(k, line_ipc(s2_st[63:1+BP_ALIGN_W] + (64-(1+BP_ALIGN_W))'(r)), s2_h);
        for (int b = 0; b < NSLOT; b++)
            for (int k = 0; k < IT_NT; k++)
                s2_itw[b][k] = raw[s2_bchk[b]][k] ^ IT_TAG_W'(s2_bxr[b]);
        for (int k = 0; k < IT_NT; k++)
            s2_sitw[k] = raw[s2_bchk[s2_bw]][k] ^ IT_TAG_W'(s2_bxr[s2_bw]);
    end
    always_ff @(posedge clk) begin s3_itw <= s2_itw; s3_sitw <= s2_sitw; end
    // ITTAGE target of the CFI in slot pos of the s3 block from the registered rows
    function automatic logic [63:0] it_target_q(logic [63:0] start, int pos, logic [HIST_W-1:0] h, logic [63:0] dflt);
        logic [63:0] prov_t, alt_t, cpc;
        logic prov, alt;
        logic [1:0] prov_c;
        int r;
        cpc = start + 64'(2 * pos);
        r = (BP_IDX_MODE == 2) ? (int'(start[1 +: BP_ALIGN_W]) + pos) >> BP_ALIGN_W : 0;
        prov = 1'b0; alt = 1'b0; prov_t = dflt; alt_t = dflt; prov_c = '0;
        for (int k = 0; k < IT_NT; k++)
            if (s3_itr[r][k].v && s3_itr[r][k].tag == it_tag_at(k, start, pos, h)) begin
                alt = prov; alt_t = prov_t;
                prov = 1'b1; prov_t = bp_full(start, cpc, s3_itr[r][k].tgt); prov_c = s3_itr[r][k].ctr;
            end
        if (!ENABLE_ITTAGE || !prov) return dflt;
        return (prov_c == 2'd0 && alt) ? alt_t : prov_t;
    endfunction
`ifndef SYNTHESIS
    // the banked s2 lookup must equal the slot-by-slot reference lookup
    // (the reference is made from the tables at the read cycle; RET targets come from the RAS later)
    bpred_t ref_q;
    always_ff @(posedge clk) ref_q <= predict(bpu_pc, hist, s1_rok, s1_rtop, ENABLE_TAGE);
    always_ff @(posedge clk) if (rst_n && s2_v) begin
        if (ref_q.taken != s2p.taken || ref_q.off != s2p.off || ref_q.push != s2p.push || ref_q.pop != s2p.pop ||
            (!s2p.pop && ref_q.target != s2p.target))
            $error("s2 lookup %h: ref %0d/%0d/%h s2 %0d/%0d/%h", s2_st,
                   ref_q.taken, ref_q.off, ref_q.target, s2p.taken, s2p.off, s2p.target);
    end
`endif
    if (S3PRE) begin : g_s3p
        // s3: the s2 decision of this block (registered); RET from the RAS, JALR from the ITTAGE rows of the
        // decided slot's chunk compared with its registered expected tags
        always_comb begin
            logic [63:0]          bt;
            logic                 prov, alt;
            logic [BTB_TGT_W-1:0] prov_t, alt_t;
            logic [1:0]           prov_c;
            logic [CK_W-1:0]      r;
            bank_rd_t             sb;
            logic [IT_TAG_W-1:0]  w [IT_NT];
            // the decided bank (BP_S3_SEL: selected at the end of s2, so s3 starts from registers)
            sb     = BP_S3_SEL ? s3_sbk : s3_bk[s3_bw];
            r      = BP_S3_SEL ? s3_schk : s3_bchk[s3_bw];
            for (int k = 0; k < IT_NT; k++) w[k] = BP_S3_SEL ? s3_sitw[k] : s3_itw[s3_bw][k];
            s3p    = '0;
            s3_cpc = s3_cpcq;
            s3_lnk = s3_lnkq;
            bt     = bp_full(s3_st, s3_cpcq, sb.tgt);
            prov = 1'b0; alt = 1'b0; prov_t = '0; alt_t = '0; prov_c = '0;
            for (int k = 0; k < IT_NT; k++)
                if (s3_itr[r][k].v && s3_itr[r][k].tag == w[k]) begin
                    alt = prov; alt_t = prov_t;
                    prov = 1'b1; prov_t = s3_itr[r][k].tgt; prov_c = s3_itr[r][k].ctr;
                end
            if (s3_fv) begin
                s3p.taken  = 1'b1;
                s3p.off    = s3_off;
                s3p.rvc    = sb.rvc;
                s3p.target = (sb.typ == CFI_RET)  ? (RAS_S3 ? ras_top : ras_rd(s3_sp, ras[s3_sp], rw_v, rw_i, rw_d)) :
                             (sb.typ == CFI_JALR && ENABLE_ITTAGE && prov)
                                 ? bp_full(s3_st, s3_cpcq, (prov_c == 2'd0 && alt) ? alt_t : prov_t) : bt;
                s3p.pop    = (sb.typ == CFI_RET);
                s3p.push   = sb.call;
            end
            // target compare per candidate in parallel (BP_TGT_START: a predicted target is {upper bits of
            // the block start, 20-bit target, 0}, so the upper part compares registers only), then selected
            begin
                logic hi_eq, eq_bt, eq_pv, eq_al, eq_rt, teq;
                hi_eq = BP_TGT_START && s3_st[63:BTB_TGT_W+1] == s3_pp.target[63:BTB_TGT_W+1] && !s3_pp.target[0];
                eq_bt = hi_eq && sb.tgt == s3_pp.target[BTB_TGT_W:1];
                eq_pv = hi_eq && prov_t == s3_pp.target[BTB_TGT_W:1];
                eq_al = hi_eq && alt_t  == s3_pp.target[BTB_TGT_W:1];
                eq_rt = (RAS_S3 ? ras_top : ras_rd(s3_sp, ras[s3_sp], rw_v, rw_i, rw_d)) == s3_pp.target;
                teq   = (sb.typ == CFI_RET) ? eq_rt :
                        (sb.typ == CFI_JALR && ENABLE_ITTAGE && prov) ? ((prov_c == 2'd0 && alt) ? eq_al : eq_pv) :
                        eq_bt;
                if (!BP_TGT_START) teq = s3p.target == s3_pp.target;
                s3_override = S3_EN && s3_v &&
                              (s3p.taken != s3_pp.taken ||
                               (s3p.taken && (s3p.off != s3_pp.off || !teq)));
            end
        end
`ifndef SYNTHESIS
        // the old s3 (its own direction / first-taken / ITTAGE lookup) must agree
        bpred_t r3p;
        logic [63:0] r3_cpc, r3_lnk;
        logic r3_override;
        always_comb begin
            logic [63:0] st;
            logic [HIST_W-1:0] h;
            logic [NSLOT-1:0] tk;
            int off, bw;
            st = s3_st;
            h  = s3_h;
            for (int b = 0; b < NSLOT; b++)
                tk[b] = s3_bk[b].hit && (s3_bk[b].typ != CFI_BR ||
                        (ENABLE_TAGE ? sc_dir(st + 64'(2 * bank_pos(st, b)), h, int'(s3_bk[b].conf)) : s3_bk[b].ctr[1]));
            off = first_taken(st, tk);
            bw  = (int'(st[1 +: SLOT_W]) + off) % NSLOT;
            r3p = '0;
            r3_cpc = st + 64'(2 * ((off >= 0) ? off : 0));
            r3_lnk = '0;
            if (off >= 0) begin
                logic [63:0] cpc, bt;
                cpc        = st + 64'(2 * off);
                bt         = bp_full(st, cpc, s3_bk[bw].tgt);
                r3p.taken  = 1'b1;
                r3p.off    = SLOT_W'(off);
                r3p.rvc    = s3_bk[bw].rvc;
                r3p.target = (s3_bk[bw].typ == CFI_RET)  ? (RAS_S3 ? ras_top : ras_rd(s3_sp, ras[s3_sp], rw_v, rw_i, rw_d)) :
                             (s3_bk[bw].typ == CFI_JALR) ? ((BP_IDX_MODE == 0) ? it_target(st, off, h, bt)
                                                                               : it_target_q(st, off, h, bt)) : bt;
                r3p.pop    = (s3_bk[bw].typ == CFI_RET);
                r3p.push   = s3_bk[bw].call;
                r3_lnk     = st + 64'(2 * off + (s3_bk[bw].rvc ? 2 : 4));
            end
            r3_override = S3_EN && s3_v &&
                          (r3p.taken != s3_pp.taken ||
                           (r3p.taken && (r3p.off != s3_pp.off || r3p.target != s3_pp.target)));
        end
        always_ff @(posedge clk) if (rst_n && s3_v && (r3p != s3p || r3_override != s3_override ||
                                                       (s3p.taken && (r3_cpc != s3_cpc || r3_lnk != s3_lnk))))
            $error("s3 decision %h: ref %0d/%0d/%h s3 %0d/%0d/%h", s3_st, r3p.taken, r3p.off, r3p.target,
                   s3p.taken, s3p.off, s3p.target);
`endif
    end else begin : g_s3o
        always_comb begin
            logic [63:0] st;
            logic [HIST_W-1:0] h;
            logic [NSLOT-1:0] tk;
            int off, bw;
            st = s3_st;
            h  = s3_h;
            for (int b = 0; b < NSLOT; b++)
                tk[b] = s3_bk[b].hit && (s3_bk[b].typ != CFI_BR ||
                        (ENABLE_TAGE ? sc_dir(st + 64'(2 * bank_pos(st, b)), h, int'(s3_bk[b].conf)) : s3_bk[b].ctr[1]));
            off = first_taken(st, tk);
            bw  = (int'(st[1 +: SLOT_W]) + off) % NSLOT;
            s3p = '0;
            s3_cpc = st + 64'(2 * ((off >= 0) ? off : 0));
            s3_lnk = '0;
            if (off >= 0) begin
                logic [63:0] cpc, bt;
                cpc        = st + 64'(2 * off);
                bt         = bp_full(st, cpc, s3_bk[bw].tgt);
                s3p.taken  = 1'b1;
                s3p.off    = SLOT_W'(off);
                s3p.rvc    = s3_bk[bw].rvc;
                s3p.target = (s3_bk[bw].typ == CFI_RET)  ? (RAS_S3 ? ras_top : ras_rd(s3_sp, ras[s3_sp], rw_v, rw_i, rw_d)) :
                             (s3_bk[bw].typ == CFI_JALR) ? ((BP_IDX_MODE == 0) ? it_target(st, off, h, bt)
                                                                               : it_target_q(st, off, h, bt)) : bt;
                s3p.pop    = (s3_bk[bw].typ == CFI_RET);
                s3p.push   = s3_bk[bw].call;
                s3_lnk     = st + 64'(2 * off + (s3_bk[bw].rvc ? 2 : 4));
            end
            s3_override = S3_EN && s3_v &&
                          (s3p.taken != s3_pp.taken ||
                           (s3p.taken && (s3p.off != s3_pp.off || s3p.target != s3_pp.target)));
        end
    end

    // override to apply this cycle: s3 (older block) has priority over s2
    logic     ovr_v, ovr_s3;
    ftq_ptr_t ovr_e;
    bpred_t   ovr_p;
    logic [$clog2(FTQ_N)-1:0] ovi;
    always_comb begin
        ovr_v  = s3_override || s2_override;
        ovr_s3 = s3_override;
        ovr_e  = s3_override ? s3_e : s2_e;
        ovr_p  = s3_override ? s3p : s2p;
        ovi    = ovr_e[FTQ_PW-2:0];
    end

    logic ftq_full;
    assign ftq_full = (ftq_ptr_t'(ftq_tail - ftq_cmt) == ftq_ptr_t'(FTQ_N));

    // ------------------------------------------------------------------
    // IFU pipeline (the ideal instruction memory is one stage, F0):
    //   F0 : take the FTQ entry at ifu_ptr, read the instruction memory banks
    //   F1 : instruction boundaries (incl. the second half of the previous block's last
    //        instruction), compaction, RVC expansion, pcs
    //   F2 : predecode check of the prediction -> IBuffer (only the instructions up to the cut)
    //   WB : IFU redirect (unpredicted / mistargeted JAL, "taken" on a non-CFI) to the BPU / FTQ;
    //        younger blocks in F0..F2 are dropped
    // BPU s2/s3 overrides drop the overridden block and younger ones from F0/F1 and refetch;
    // the s3 check of a block always ends before it reaches F2.
    // ------------------------------------------------------------------
    // F1 / F2 / WB stage registers
    logic        f1_v;
    ftq_ptr_t    f1_ptr;
    logic [NSLOT:0][15:0] f1_hw;
    logic        f1_seq;               // the block starts where the previous FTQ block ends
    logic        f2_v;
    ftq_ptr_t    f2_ptr;
    int          f2_n;                 // instructions found
    logic [31:0] f2_insn [NSLOT];
    logic        f2_rvc  [NSLOT];
    int          f2_slot [NSLOT];
    logic [63:0] f2_pc   [NSLOT];
    logic        f2_skip;
    logic        w_v;                  // IFU redirect in WB
    ftq_ptr_t    w_ptr;
    logic [63:0] w_pc, w_link, w_cut_target, w_cut_pc;
    logic        w_push, w_cut_taken, w_cross;
    logic [SLOT_W-1:0] w_cut_slot;

    // ---------------- F0 ----------------
    logic f0_go, f1_go, f2_go, f1_free, f2_free;
    logic f1_flush, f2_flush;
    // a BPU override reaches the IFU one cycle later; the s3
    // check of a block is still before its F2 / IBuffer write
    logic     ovr_q_v;
    ftq_ptr_t ovr_q_e;
    always_ff @(posedge clk) begin
        ovr_q_v <= rst_n && ovr_v && !be_redir.valid && !w_v;
        ovr_q_e <= ovr_e;
    end
    logic [$clog2(FTQ_N)-1:0] fi;      // F2 block (names kept from the one-stage IFU)
    assign im_addr = ftq_start[ifu_ptr[FTQ_PW-2:0]];
    // an override in this cycle rewrites its entry and drops the younger ones
    assign f0_go    = (ifu_ptr != ftq_tail) && f1_free && !be_redir.valid && !w_v;

    // ---------------- F1: boundaries + RVC expansion ----------------
    logic [$clog2(FTQ_N)-1:0] f1i, fprev;
    logic        f1_skip, f1_cross;
    int          n_inst;
    logic [31:0] f_insn [NSLOT];
    logic        f_rvc  [NSLOT];
    int          f_slot [NSLOT];
    logic [63:0] f_pc   [NSLOT];
    assign f1i   = f1_ptr[FTQ_PW-2:0];
    assign fprev = ftq_ptr_t'(f1_ptr - 1'b1);
    // does this block start with the second half of the previous block's last instruction?
    // (f1_seq, the start-address comparison, is made in F0)
    assign f1_skip = ftq_cross[fprev] && f1_seq;
    // Instruction boundaries: a bit chain
    // start[i] = !start[i-1] || rvc[i-1], the second half computed for both values of the first
    // half's end (carry select); then every slot is expanded in parallel and the starts are
    // compacted by their rank
    logic [NSLOT-1:0] f1_rvc, f1_start, f1_hi0, f1_hi1;
    always_comb begin
        localparam int H = NSLOT / 2;
        logic lo_open;
        logic [NSLOT-1:0] rv, st, h0, h1;
        for (int i = 0; i < NSLOT; i++) rv[i] = f1_hw[i][1:0] != 2'b11;
        st = '0; h0 = '0; h1 = '0;
        st[0] = !f1_skip;
        for (int i = 1; i < H; i++) st[i] = !st[i-1] || rv[i-1];
        h0[H] = 1'b1;                     // the first half ends with a complete instruction
        h1[H] = 1'b0;                     // ... or with the first half of a 32-bit one
        for (int i = H + 1; i < NSLOT; i++) begin
            h0[i] = !h0[i-1] || rv[i-1];
            h1[i] = !h1[i-1] || rv[i-1];
        end
        lo_open = st[H-1] && !rv[H-1];
        for (int i = H; i < NSLOT; i++) st[i] = lo_open ? h1[i] : h0[i];
        f1_rvc = rv; f1_start = st; f1_hi0 = h0; f1_hi1 = h1;
    end
    always_comb begin
        int rank;
        logic [31:0] ins;
        n_inst = 0;
        for (int k = 0; k < NSLOT; k++) begin
            f_insn[k] = '0; f_rvc[k] = 1'b0; f_slot[k] = 0; f_pc[k] = '0;
        end
        rank = 0;
        for (int i = 0; i < NSLOT; i++) begin
            ins = f1_rvc[i] ? rvc_expand(f1_hw[i]) : {f1_hw[i+1], f1_hw[i]};
            for (int k = 0; k < NSLOT; k++)
                if (f1_start[i] && rank == k) begin
                    f_insn[k] = f_insn[k] | ins;
                    f_rvc[k]  = f_rvc[k] | f1_rvc[i];
                    f_slot[k] = f_slot[k] | i;
                    f_pc[k]   = f_pc[k] | (ftq_start[f1i] + 64'(2 * i));
                end
            rank += int'(f1_start[i]);
        end
        for (int k = 0; k < NSLOT; k++) if (k >= rank) f_slot[k] = NSLOT;
        n_inst = rank;
        // the last instruction delivered when the check finds nothing to correct (up to the
        // predicted taken slot, else the block end) straddles the block end
        f1_cross = f1_start[NSLOT-1] && !f1_rvc[NSLOT-1] && !(ftq_taken[f1i] && int'(ftq_off[f1i]) < NSLOT - 1);
    end

    // ---------------- F2: predecode check ----------------
    int          ifu_n;            // instructions delivered (0..NSLOT)
    logic        ifu_redir;
    logic [63:0] ifu_redir_pc;
    logic        ifu_redir_push;
    logic [63:0] ifu_redir_link;
    logic        cut_taken;
    logic [63:0] cut_target;
    logic [63:0] cut_pc;
    logic [SLOT_W-1:0] cut_slot;
    logic        ifu_cross;        // the last delivered instruction straddles the block end
    logic        ifu_fire, ifu_skip;   // statistics (test benches)
    assign fi       = f2_ptr[FTQ_PW-2:0];
    assign ifu_skip = f2_skip;
    // Predecode check: the faults of every slot are found in parallel (an unpredicted
    // JAL, "taken" on a non-CFI or inside an instruction), the first one by a priority encoder;
    // the jump / fall-through targets are only data for the redirect in WB
    logic [NSLOT-1:0] f2_ok, f2_jf, f2_nf;
    logic [63:0] f2_jtgt [NSLOT], f2_seq [NSLOT];
    always_comb begin
        int off;
        off = int'(ftq_off[fi]);
        for (int k = 0; k < NSLOT; k++) begin
            logic is_jal, is_cfi, covers;
            is_jal = (f2_insn[k][6:0] == 7'b1101111);
            is_cfi = is_jal || (f2_insn[k][6:0] == 7'b1100111) || (f2_insn[k][6:0] == 7'b1100011);
            f2_jtgt[k] = f2_pc[k] + {{43{f2_insn[k][31]}}, f2_insn[k][31], f2_insn[k][19:12], f2_insn[k][20],
                                     f2_insn[k][30:21], 1'b0};
            f2_seq[k]  = f2_pc[k] + (f2_rvc[k] ? 64'd2 : 64'd4);
            covers   = ftq_taken[fi] && (f2_slot[k] == off || (!f2_rvc[k] && f2_slot[k] + 1 == off));
            // instructions up to the predicted taken slot (a prefix of the found instructions)
            f2_ok[k] = k < f2_n && !(ftq_taken[fi] && f2_slot[k] > off);
            f2_jf[k] = is_jal && !(ftq_taken[fi] && f2_slot[k] == off &&
                                   (!IFU_JAL_TGT_CHK || ftq_target[fi] == f2_jtgt[k]));
            f2_nf[k] = !f2_jf[k] && covers && (!is_cfi || f2_slot[k] != off);
        end
    end
    always_comb begin
        logic [NSLOT-1:0] fault;
        int first, nok;
        fault = f2_ok & (f2_jf | f2_nf);
        first = 0;
        for (int k = NSLOT - 1; k >= 0; k--) if (fault[k]) first = k;
        nok = 0;
        for (int k = 0; k < NSLOT; k++) if (f2_ok[k]) nok = k + 1;
        ifu_n = (fault != '0) ? first + 1 : nok;
        ifu_redir = 1'b0; ifu_redir_pc = '0; ifu_redir_push = 1'b0; ifu_redir_link = '0;
        cut_taken = 1'b0; cut_target = '0; cut_pc = '0; cut_slot = '0;
        if (ftq_taken[fi] && f2_skip && ftq_off[fi] == '0) begin
            // "taken" predicted on the second half of the previous block's instruction
            ifu_n = 0;
            ifu_redir = 1'b1; ifu_redir_pc = ftq_start[fi] + 64'd2;
            cut_target = ftq_start[fi] + 64'd2; cut_pc = ftq_start[fi];
        end else if (fault != '0) begin
            ifu_redir = 1'b1;
            cut_pc    = f2_pc[first];
            cut_slot  = SLOT_W'(f2_slot[first]);
            if (f2_jf[first]) begin
                // JAL not predicted (or wrong target): cut the block here and jump
                cut_taken      = 1'b1;
                cut_target     = f2_jtgt[first];
                ifu_redir_pc   = f2_jtgt[first];
                ifu_redir_push = (f2_insn[first][11:7] == 5'd1) || (f2_insn[first][11:7] == 5'd5);
                ifu_redir_link = f2_seq[first];
            end else begin
                // "taken" predicted on a non-CFI or inside an instruction: fall through
                cut_target   = f2_seq[first];
                ifu_redir_pc = f2_seq[first];
            end
        end
        ifu_cross = (ifu_n > 0) && !f2_rvc[ifu_n - 1] && f2_slot[ifu_n - 1] == NSLOT - 1;
    end

    // ---------------- pipeline control ----------------
    // IBuffer enqueue: room for a whole block (registered count only); all NSLOT slots are
    // written and the check result only sets how many become valid
    assign f2_flush = be_redir.valid || w_v || (ovr_q_v && !ftq_older(f2_ptr, ovr_q_e));
    assign f2_go    = f2_v && (int'(ib_count) <= IBUF_N - NSLOT) && !f2_flush;
    assign ifu_fire = f2_go;
    assign f2_free  = !f2_v || f2_go;
    // F1 is dropped by a redirect / IFU redirect, or by an override of its block or an older one
    assign f1_flush = be_redir.valid || w_v || (ovr_q_v && !ftq_older(f1_ptr, ovr_q_e));
    assign f1_go    = f1_v && !f1_flush && f2_free;
    assign f1_free  = !f1_v || f1_flush || f2_free;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            f1_v <= 1'b0; f2_v <= 1'b0; w_v <= 1'b0;
        end else begin
            if (f0_go) begin
                f1_v   <= 1'b1;
                f1_ptr <= ifu_ptr;
                f1_hw  <= im_data;
                f1_seq <= ftq_start[ifu_ptr[FTQ_PW-2:0]] ==
                          ftq_start[ftq_ptr_t'(ifu_ptr - 1'b1)] + 64'(2 * NSLOT);
            end else if (f1_free) f1_v <= 1'b0;
            if (f1_go) begin
                f2_v    <= 1'b1;
                f2_ptr  <= f1_ptr;
                f2_n    <= n_inst;
                f2_insn <= f_insn;
                f2_rvc  <= f_rvc;
                f2_slot <= f_slot;
                f2_pc   <= f_pc;
                f2_skip <= f1_skip;
            end else if (f2_free || f2_flush) f2_v <= 1'b0;
            w_v <= f2_go && ifu_redir;
            if (f2_go) begin
                w_ptr <= f2_ptr; w_pc <= ifu_redir_pc; w_push <= ifu_redir_push; w_link <= ifu_redir_link;
                w_cut_taken <= cut_taken; w_cut_target <= cut_target; w_cut_pc <= cut_pc;
                w_cut_slot <= cut_slot; w_cross <= ifu_cross;
            end
        end
    end

    // ------------------------------------------------------------------
    // sequential: BPU / RAS / FTQ / IFU / IBuffer
    // ------------------------------------------------------------------
    // micro-RAS (RAS_S3): s1's RAS top, from the main RAS and the pushes / pops of
    // the blocks in s2 and s3 (not yet applied to the main RAS); u_ok = 0 when it cannot be known
    // (a pop below the main RAS top, or the cycle after a redirect)
    if (RAS_S3) begin : g_uras
        logic        u2_push, u2_pop, u3_push, u3_pop, u_rd1;
        logic [63:0] u2_ret, u3_ret, s1_lnk;
        logic        r, s3ov, s2ov, s1f, s2f;
        assign s1_lnk = bpu_pc + 64'(2 * bp_off) + (s1p.rvc ? 64'd2 : 64'd4);
        assign r    = be_redir.valid || w_v;
        assign s3ov = !r && s3_override;
        assign s2ov = !r && !s3_override && s2_override;
        assign s1f  = !r && !ovr_v && !ftq_full;          // s1 block enters the FTQ / s2
        assign s2f  = !r && !s3_override && s2_v;         // s2 block moves to s3
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                u2_push <= 1'b0; u2_pop <= 1'b0; u3_push <= 1'b0; u3_pop <= 1'b0;
                u_ok <= 1'b0; u_top <= '0; u_rd1 <= 1'b0;
            end else begin
                u_rd1 <= r;
                // ops of the block in s2
                if (s3ov || r)  begin u2_push <= 1'b0;    u2_pop <= 1'b0;   end
                else if (s2ov)  begin u2_push <= 1'b0;    u2_pop <= 1'b0;   end   // it moves to s3
                else if (s1f)   begin u2_push <= bp_push; u2_pop <= bp_pop; end
                else if (s2f)   begin u2_push <= 1'b0;    u2_pop <= 1'b0;   end
                // ops of the block in s3
                if (s3ov || r)  begin u3_push <= 1'b0; u3_pop <= 1'b0; end
                else if (s2f)   begin u3_push <= s2ov ? s2p.push : u2_push; u3_pop <= s2ov ? s2p.pop : u2_pop; end
                else if (s3_v)  begin u3_push <= 1'b0; u3_pop <= 1'b0; end
                if (s1f && bp_push) u2_ret <= s1_lnk;
                if (s2f) u3_ret <= s2ov ? s2_lnk : u2_ret;
                // RAS top for the next s1 block
                if (r) u_ok <= 1'b0;
                else if (s3ov) begin
                    u_ok  <= !s3p.pop;
                    u_top <= s3p.push ? s3_lnk : ras_top;
                end else if (s2ov) begin
                    if (s2p.push)      begin u_ok <= 1'b1;    u_top <= s2_lnk; end
                    else if (s2p.pop)  begin u_ok <= u3_push; u_top <= ras_top; end
                    else if (u3_push)  begin u_ok <= 1'b1;    u_top <= u3_ret; end
                    else if (u3_pop)         u_ok <= 1'b0;
                    else               begin u_ok <= !u_rd1;  u_top <= ras_top; end
                end else if (s1f && bp_push) begin
                    u_ok <= 1'b1; u_top <= s1_lnk;
                end else if (s1f && bp_pop) begin
                    if (u2_push)       begin u_ok <= !u3_pop; u_top <= u3_push ? u3_ret : ras_top; end
                    else if (u2_pop)         u_ok <= 1'b0;
                    else if (u3_push)  begin u_ok <= 1'b1;    u_top <= ras_top; end
                    else                     u_ok <= 1'b0;
                end else if (s1f) begin
                    if (u2_push)       begin u_ok <= 1'b1;    u_top <= u2_ret; end
                    else if (u2_pop)   begin u_ok <= u3_push; u_top <= ras_top; end
                    else if (u3_pop)         u_ok <= 1'b0;
                    else if (u3_push)  begin u_ok <= 1'b1;    u_top <= u3_ret; end
                    else               begin u_ok <= !u_rd1;  u_top <= ras_top; end
                end
            end
        end
    end else begin : g_nouras
        assign u_ok = 1'b0; assign u_top = '0;
    end
    if (RAS_WDELAY) begin : g_rasw
        always_ff @(posedge clk) if (rw_v) ras[rw_i] <= rw_d;
    end
    always_ff @(posedge clk) begin
        logic                     rw_v_n;
        logic [$clog2(RAS_N)-1:0] rw_i_n;
        logic [63:0]              rw_d_n;
        if (!rst_n) begin
            bpu_pc <= RESET_PC;
            s1_ln  <= chunk_lns(RESET_PC);
            ras_sp <= '0;
            hist <= '0;
            s2_v <= 1'b0;
            s2_e <= '0;
            s3_v <= 1'b0;
            s3_e <= '0;
            ub_v <= '0;
            ub_rr <= '0;
            ftq_cross <= '0;
            for (int k = 0; k < SC_NT; k++) sc_t[k] <= '0;
            for (int k = 0; k < IT_NT; k++) it_v[k] <= '0;
            for (int k = 0; k < IT_NT; k++) it_u[k] <= '0;
            t_reset_cnt <= '0;
            for (int t = 0; t < TAGE_NT; t++) t_v[t] <= '0;
            for (int t = 0; t < TAGE_NT; t++) t_u[t] <= '0;
            ftq_tail <= '0; ifu_ptr <= '0; ftq_cmt <= '0;
            ib_head <= '0; ib_count <= '0;
            rw_v <= 1'b0;
            for (int b = 0; b < NSLOT; b++)
                for (int s = 0; s < BTB_SETS; s++) btb_v[b][s] <= 1'b0;
        end else begin
            rw_v_n = 1'b0; rw_i_n = '0; rw_d_n = '0;
            // ---------------- redirects / prediction ----------------
            if (be_redir.valid) begin
                logic [$clog2(RAS_N)-1:0] sp;
                sp = ftq_ras_sp[be_redir.ftq_idx[FTQ_PW-2:0]];
                if (be_redir.is_call) begin
                    sp = sp + 1'b1;
                    rw_v_n = 1'b1; rw_i_n = sp; rw_d_n = be_redir.link;
                end else if (be_redir.is_ret) begin
                    sp = sp - 1'b1;
                end
                ras_sp   <= sp;
                hist     <= upd_hist(ftq_hist[be_redir.ftq_idx[FTQ_PW-2:0]],
                                     !be_redir.flush_self && be_redir.taken,
                                     be_redir.link - (be_redir.rvc ? 64'd2 : 64'd4), be_tgt);
                s2_v     <= 1'b0;
                s3_v     <= 1'b0;
                bpu_pc   <= be_tgt;
                s1_ln    <= chunk_lns(be_tgt);
                ftq_tail <= be_redir.ftq_idx + 1'b1;
                ifu_ptr  <= be_redir.ftq_idx + 1'b1;
                ib_count <= '0;                            // flush IBuffer
            end else if (w_v) begin
                // IFU redirect (WB): the block in WB ends at the cut
                logic [$clog2(RAS_N)-1:0] sp;
                logic [$clog2(FTQ_N)-1:0] wi;
                wi = w_ptr[FTQ_PW-2:0];
                sp = ftq_ras_sp[wi];
                if (w_push) begin
                    sp = sp + 1'b1;
                    rw_v_n = 1'b1; rw_i_n = sp; rw_d_n = w_link;
                end
                ras_sp   <= sp;
                hist     <= upd_hist(ftq_hist[wi], w_cut_taken, w_cut_pc, w_cut_target);
                s2_v     <= 1'b0;
                s3_v     <= 1'b0;
                bpu_pc   <= w_pc;
                s1_ln    <= chunk_lns(w_pc);
                ftq_tail <= w_ptr + 1'b1;
                ifu_ptr  <= w_ptr + 1'b1;
                ftq_taken[wi]  <= w_cut_taken;      // the corrected prediction of this block
                ftq_off[wi]    <= w_cut_slot;
                ftq_target[wi] <= w_cut_target;
            end else if (ovr_v) begin
                // s2 (TAGE) or s3 (SC/ITTAGE) disagrees with the earlier prediction:
                // rewrite the FTQ entry, drop younger BPU work
                logic [$clog2(RAS_N)-1:0] sp;
                logic [63:0] cpc;
                cpc = ovr_s3 ? s3_cpc : s2_cpc;
                sp = ovr_s3 ? s3_sp : s2_sp;
                if (!RAS_S3) begin
                    if (ovr_p.push) begin
                        sp = sp + 1'b1;
                        rw_v_n = 1'b1; rw_i_n = sp; rw_d_n = ovr_s3 ? s3_lnk : s2_lnk;
                    end else if (ovr_p.pop) begin
                        sp = sp - 1'b1;
                    end
                    ras_sp <= sp;
                end
                hist             <= upd_hist(ovr_s3 ? s3_h : s2_h, ovr_p.taken, cpc, ovr_p.target);
                ftq_taken[ovi]   <= ovr_p.taken;
                ftq_off[ovi]     <= ovr_p.off;
                ftq_target[ovi]  <= ovr_p.target;
                ftq_tail         <= ovr_e + 1'b1;
                bpu_pc           <= ovr_p.taken ? ovr_p.target : (ovr_s3 ? s3_ft : s2_ft);
                s1_ln            <= chunk_lns(ovr_p.taken ? ovr_p.target : (ovr_s3 ? s3_ft : s2_ft));
                s2_v             <= 1'b0;
                s3_v             <= !ovr_s3;          // an s2-overridden block still goes through s3
                s3_e             <= ovr_e;
                if (ftq_older(ovr_e, ifu_ptr) || (f0_go && ifu_ptr == ovr_e))
                    ifu_ptr <= ovr_e;                 // block already in the IFU: refetch it
                else if (f0_go)
                    ifu_ptr <= ifu_ptr + 1'b1;
            end else begin
                s3_v <= s2_v;
                s3_e <= s2_e;
                s2_v <= !ftq_full;
                s2_e <= ftq_tail;
                if (!ftq_full) begin
                    logic [$clog2(FTQ_N)-1:0] t;
                    t = ftq_tail[FTQ_PW-2:0];
                    ftq_start[t]  <= bpu_pc;
                    ftq_taken[t]  <= bp_taken;
                    ftq_off[t]    <= bp_off;
                    ftq_target[t] <= bp_target;
                    if (!RAS_S3) ftq_ras_sp[t] <= ras_sp;
                    ftq_hist[t]  <= hist;
                    hist          <= upd_hist(hist, bp_taken, bpu_pc + 64'(2 * bp_off), bp_target);
                    ftq_tail      <= ftq_tail + 1'b1;
                    bpu_pc        <= bp_next;
                    s1_ln         <= chunk_lns(bp_next);
                    if (!RAS_S3 && bp_push) begin
                        rw_v_n = 1'b1; rw_i_n = ras_sp + 1'b1; rw_d_n = bpu_pc + 64'(2 * bp_off) + (s1p.rvc ? 64'd2 : 64'd4);
                        ras_sp <= ras_sp + 1'b1;
                    end else if (!RAS_S3 && bp_pop) begin
                        ras_sp <= ras_sp - 1'b1;
                    end
                end
                if (f0_go) ifu_ptr <= ifu_ptr + 1'b1;
            end

            // ---------------- uBTB fast training from the s2 prediction ----------------
            if (UBTB_EN && BPU_OVERRIDE && s2_v) begin
                int hit;
                hit = -1;
                for (int i = 0; i < UBTB_N; i++)
                    if (ub_v[i] && ub_tag[i] == s2_st[63:1]) hit = i;
                if (s2p.taken) begin
                    logic [$clog2(UBTB_N)-1:0] w;
                    w = (hit >= 0) ? hit[$clog2(UBTB_N)-1:0] : ub_rr;
                    ub_v[w]    <= 1'b1;
                    ub_tag[w]  <= s2_st[63:1];
                    ub_off[w]  <= s2p.off;
                    ub_rvc[w]  <= s2p.rvc;
                    ub_tgt[w]  <= s2p.target;
                    ub_ret[w]  <= s2p.pop;
                    ub_call[w] <= s2p.push;
                    if (hit < 0) ub_rr <= ub_rr + 1'b1;
                end else if (hit >= 0) begin
                    ub_v[hit] <= 1'b0;
                end
            end

            // ---------------- IBuffer ----------------
            if (!be_redir.valid) begin
                if (ifu_fire) begin
                    ib_count <= ib_count + (IBUF_IW+1)'(ifu_n) - ib_deq;   // entries: g_ibw below
                end else begin
                    ib_count <= ib_count - ib_deq;
                end
                ib_head <= (IBUF_IW)'((int'(ib_head) + int'(ib_deq)) % IBUF_N);
            end

            // ftq_cross: provisional value in F1 (for the next block's F1), final value on an IFU redirect
            if (w_v && !be_redir.valid) ftq_cross[w_ptr[FTQ_PW-2:0]] <= w_cross;
            else if (f1_go)             ftq_cross[f1i] <= f1_cross;

            // ---------------- FTQ release ----------------
            if (cmt_ftq_valid) ftq_cmt <= cmt_ftq;

            // ---------------- TAGE training (commit, conditional branches) ----------------
            if (ENABLE_TAGE && upd_valid && upd_type == CFI_BR) begin
                logic [HIST_W-1:0] h;
                logic [63:0] ust;
                logic [TSI_W-1:0] ix [TAGE_NT];
                logic [TAGE_TAG_W-1:0] tg [TAGE_NT];
                int e [TAGE_NT];                    // hit entry of each table (-1: miss)
                int ew [TAGE_NT];                   // its way
                int prov, alt;
                logic base, prov_dir, alt_dir, final_dir, allocated;
                h = upd_h;
                ust = upd_ust;                              // block start
                base = upd_bhit && upd_bctr[1];
                prov = -1; alt = -1;
                for (int t = 0; t < TAGE_NT; t++) begin
                    ix[t] = upd_tix[t];
                    tg[t] = upd_ttg[t];
                    e[t]  = -1; ew[t] = 0;
                    for (int w = TAGE_WAYS - 1; w >= 0; w--)
                        if (upd_tv[t][w] && upd_ttag[t][w] == tg[t]) begin
                            e[t] = int'(ix[t]) * TAGE_WAYS + w; ew[t] = w;
                        end
                    if (e[t] >= 0) begin alt = prov; prov = t; end
                end
                alt_dir   = (alt >= 0) ? upd_tctr[alt][ew[alt]][2] : base;
                prov_dir  = (prov >= 0) ? upd_tctr[prov][ew[prov]][2] : base;
                final_dir = prov_dir;
                if (prov >= 0) begin
                    if (!TAGE_RAM && upd_taken && upd_tctr[prov][ew[prov]] != 3'd7) t_ctr[prov][e[prov]] <= upd_tctr[prov][ew[prov]] + 1'b1;
                    if (!TAGE_RAM && !upd_taken && upd_tctr[prov][ew[prov]] != 3'd0) t_ctr[prov][e[prov]] <= upd_tctr[prov][ew[prov]] - 1'b1;
                    if (prov_dir != alt_dir) begin
                        if (prov_dir == upd_taken && upd_tu[prov][ew[prov]] != 2'd3) t_u[prov][e[prov]] <= upd_tu[prov][ew[prov]] + 1'b1;
                        if (prov_dir != upd_taken && upd_tu[prov][ew[prov]] != 2'd0) t_u[prov][e[prov]] <= upd_tu[prov][ew[prov]] - 1'b1;
                    end
                end
                if (final_dir != upd_taken) begin
                    // allocate one way (useful counter 0) in a longer-history table
                    allocated = 1'b0;
                    for (int t = 0; t < TAGE_NT; t++)
                        for (int w = 0; w < TAGE_WAYS; w++) begin
                            int a;
                            a = int'(ix[t]) * TAGE_WAYS + w;
                            if (t > prov && !allocated && upd_tu[t][w] == 2'd0) begin
                                allocated = 1'b1;
                                t_v[t][a]   <= 1'b1;
                                if (!TAGE_RAM) begin
                                    t_tag[t][a] <= tg[t];
                                    t_ctr[t][a] <= upd_taken ? 3'd4 : 3'd3;
                                end
                            end
                        end
                    if (!allocated)
                        for (int t = 0; t < TAGE_NT; t++)
                            for (int w = 0; w < TAGE_WAYS; w++)
                                if (t > prov && upd_tu[t][w] != 2'd0)
                                    t_u[t][int'(ix[t]) * TAGE_WAYS + w] <= upd_tu[t][w] - 1'b1;
                end
                // periodic aging of the useful counters
                t_reset_cnt <= t_reset_cnt + 1'b1;
                if (t_reset_cnt == '1) begin
                    t_u[0] <= age_u(t_u[0]); t_u[1] <= age_u(t_u[1]);
                    t_u[2] <= age_u(t_u[2]); t_u[3] <= age_u(t_u[3]);
                end
            end

            // ---------------- SC / ITTAGE training (commit) ----------------
            if (upd_valid && (ENABLE_SC || ENABLE_ITTAGE)) begin
                logic [HIST_W-1:0] h;
                logic [63:0] ust;
                h   = upd_h;
                ust = upd_ust;
                if (ENABLE_SC && upd_type == CFI_BR) begin
                    int tconf, tot;
                    logic tdir, fdir;
                    tconf = tage_conf(ust, int'(upd_pos), h, upd_bhit ? upd_bctr : 2'b01);
                    tdir  = tconf > 0;
                    tot   = sc_total(upd_pc, h, tconf);
                    fdir  = tot >= 0;
                    if (fdir != upd_taken || (tot <= SC_THR && tot >= -SC_THR)) begin
                        for (int k = 0; k < SC_NT; k++) begin
                            logic [SC_IDX_W-1:0] ix;
                            ix = sc_index(k, upd_pc, h, tdir);
                            if (upd_taken && sc_t[k][ix] != 6'sd31)   sc_t[k][ix] <= sc_t[k][ix] + 1'b1;
                            if (!upd_taken && sc_t[k][ix] != 6'h20)   sc_t[k][ix] <= sc_t[k][ix] - 1'b1;
                        end
                    end
                end
                if (ENABLE_ITTAGE && upd_type == CFI_JALR) begin
                    logic [IT_IDX_W-1:0] ix [IT_NT];
                    logic [IT_TAG_W-1:0] tg [IT_NT];
                    int prov, alt;
                    logic pred_ok;
                    logic allocated;
                    prov = -1; alt = -1;
                    for (int k = 0; k < IT_NT; k++) begin
                        ix[k] = upd_iix[k];
                        tg[k] = upd_itg[k];
                        if (upd_iv[k] && upd_itag[k] == tg[k]) begin alt = prov; prov = k; end
                    end
                    // predicted target == upd_target <=> the upper bits fit and the 20 stored bits are equal
                    pred_ok = upd_bhit && upd_fit && upd_btgt == upd_target[BTB_TGT_W:1];
                    if (prov >= 0) pred_ok = upd_fit && ((upd_ictr[prov] == 2'd0 && alt >= 0) ? upd_itgt[alt]
                                                                     : upd_itgt[prov]) == upd_target[BTB_TGT_W:1];
                    if (prov >= 0) begin
                        if (upd_fit && upd_itgt[prov] == upd_target[BTB_TGT_W:1]) begin
                            if (upd_ictr[prov] != 2'd3) it_ctr[prov][ix[prov]] <= upd_ictr[prov] + 1'b1;
                            it_u[prov][ix[prov]] <= 1'b1;
                        end else if (upd_ictr[prov] == 2'd0) begin
                            it_tgt[prov][ix[prov]] <= upd_target[BTB_TGT_W:1];
                        end else begin
                            it_ctr[prov][ix[prov]] <= upd_ictr[prov] - 1'b1;
                        end
                    end
                    if (!pred_ok) begin
                        allocated = 1'b0;
                        for (int k = 0; k < IT_NT; k++) begin
                            if (k > prov && !allocated && !upd_iu[k]) begin
                                allocated = 1'b1;
                                it_v[k][ix[k]]   <= 1'b1;
                                it_tag[k][ix[k]] <= tg[k];
                                it_tgt[k][ix[k]] <= upd_target[BTB_TGT_W:1];
                                it_ctr[k][ix[k]] <= 2'd0;
                            end
                        end
                        if (!allocated)
                            for (int k = 0; k < IT_NT; k++)
                                if (k > prov) it_u[k][ix[k]] <= 1'b0;
                    end
                end
            end

            // ---------------- BTB training (commit) ----------------
            if (upd_valid) begin
                logic [SLOT_W-1:0] b;
                logic [SET_W-1:0] s;
                b = btb_bank(upd_pc);
                s = btb_set(upd_pc);
                if (upd_type == CFI_BR) begin
                    if (upd_bhit) begin
                        if (upd_taken && upd_bctr != 2'b11) btb_ctr[b][s] <= upd_bctr + 1'b1;
                        if (!upd_taken && upd_bctr != 2'b00) btb_ctr[b][s] <= upd_bctr - 1'b1;
                        if (upd_taken) btb_target[b][s] <= upd_target[BTB_TGT_W:1];
                    end else if (upd_taken) begin
                        btb_v[b][s] <= 1'b1; btb_tag[b][s] <= btb_tagf(upd_pc);
                        btb_type[b][s] <= CFI_BR; btb_call[b][s] <= 1'b0; btb_rvc[b][s] <= upd_rvc;
                        btb_ctr[b][s] <= 2'b10; btb_target[b][s] <= upd_target[BTB_TGT_W:1];
                    end
                end else begin
                    btb_v[b][s] <= 1'b1; btb_tag[b][s] <= btb_tagf(upd_pc);
                    btb_type[b][s] <= upd_type; btb_call[b][s] <= upd_call; btb_rvc[b][s] <= upd_rvc;
                    btb_ctr[b][s] <= 2'b11; btb_target[b][s] <= upd_target[BTB_TGT_W:1];
                end
            end
            // RAS_S3: the main RAS follows the final (s3) prediction of every block that leaves s3;
            // the pointer before the block is kept in its FTQ entry
            if (RAS_S3 && s3_v && !be_redir.valid && !w_v) begin
                logic [$clog2(RAS_N)-1:0] sp;
                sp = ras_sp;
                ftq_ras_sp[s3i] <= ras_sp;
                if (s3p.push) begin
                    sp = sp + 1'b1;
                    rw_v_n = 1'b1; rw_i_n = sp; rw_d_n = s3_lnk;
                end else if (s3p.pop) begin
                    sp = sp - 1'b1;
                end
                ras_sp <= sp;
            end
            rw_v <= rw_v_n; rw_i <= rw_i_n; rw_d <= rw_d_n;
            if (!RAS_WDELAY && rw_v_n) ras[rw_i_n] <= rw_d_n;
        end
    end

    always_comb for (int i = 0; i < FTQ_N; i++) begin
        pcm_start[i]  = ftq_start[i];
        pcm_target[i] = ftq_target[i];
    end

    // IBuffer write (IB_WB = 4 write banks): the IFU output is pre-rotated by
    // (tail mod IB_WB), so entry e (bank e mod IB_WB) selects among NSLOT/IB_WB + 1 instructions
    localparam int IB_WB  = 4;
    localparam int IB_PRE = NSLOT + IB_WB;
    fetch_t ib_new [NSLOT];
    fetch_t ib_pre [IB_PRE];
    logic   ib_wen;
    int     ib_rot, ib_tal;
    always_comb begin
        int tail;
        for (int i = 0; i < NSLOT; i++) begin
            ib_new[i].insn       = f2_insn[i];
            ib_new[i].rvc        = f2_rvc[i];
            ib_new[i].pc         = f2_pc[i];
            ib_new[i].off        = SLOT_W'(f2_slot[i]);
            ib_new[i].ftq_idx    = f2_ptr;
            // IFU_PT_SLOT: a delivered slot is the last one iff it is the first fault or the predicted
            // taken slot with no fault before it, so its own bits decide (later slots are not counted)
            ib_new[i].pred_taken = IFU_PT_SLOT ? (f2_jf[i] || (ftq_taken[fi] && f2_slot[i] == int'(ftq_off[fi]) && !f2_nf[i]))
                                 : (i == ifu_n - 1) &&
                                   (ifu_redir ? cut_taken : (ftq_taken[fi] && f2_slot[i] == int'(ftq_off[fi])));
        end
        tail   = (int'(ib_head) + int'(ib_count)) % IBUF_N;
        ib_rot = tail % IB_WB;
        ib_tal = tail - ib_rot;
        for (int j = 0; j < IB_PRE; j++)
            ib_pre[j] = (j >= ib_rot && j - ib_rot < NSLOT) ? ib_new[j - ib_rot] : '0;
        ib_wen = ifu_fire;
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (rst_n && IFU_PT_SLOT && ifu_fire)
            for (int i = 0; i < NSLOT; i++)
                if (i < ifu_n && ib_new[i].pred_taken != ((i == ifu_n - 1) &&
                        (ifu_redir ? cut_taken : (ftq_taken[fi] && f2_slot[i] == int'(ftq_off[fi])))))
                    $error("IFU_PT_SLOT: slot %0d of %0d disagrees", i, ifu_n);
`endif
    for (genvar e = 0; e < IBUF_N; e++) begin : g_ibw
        always_ff @(posedge clk) begin
            int r, j;
            r = ((e - ib_tal + IBUF_N) % IBUF_N) / IB_WB;    // row of the pre-rotated vector
            j = r * IB_WB + e % IB_WB;
            if (ib_wen && r < IB_PRE / IB_WB && j >= ib_rot && j < ib_rot + NSLOT)
                ibuf[e] <= ib_pre[r * IB_WB + e % IB_WB];
        end
    end

    // IBuffer outputs
    always_comb begin
        for (int i = 0; i < DEC_W; i++) begin
            ib_out[i]   = ibuf[(int'(ib_head) + i) % IBUF_N];
            ib_valid[i] = (i < int'(ib_count));
        end
    end

endmodule
