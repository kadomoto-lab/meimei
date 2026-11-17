// Out-of-order RV64IMFDC_Zicsr core (bare metal: M mode only, no traps).
// Default configuration (8-wide, ROB 352, 224 int + 256 FP pregs,
// 6 ALU (3 with BJU, MUL x2, DIV, I2F), 3 LDU, 2 STA + 2 STD, 4 FEX (FALU+FMA, FCVT, FDIV x2));
// +define+MM_SMALL gives the earlier 4-wide core.
// No privileged architecture, no I/O, no exceptions: same "ideal memory" model as the in-order
// SynRV cores. Zicsr: fflags / frm / fcsr and the read-only counters cycle / time / instret;
// other CSRs read as 0 and ignore writes. CSR instructions execute on ALU0 when they are the
// oldest instruction and block younger dispatch until they commit, so the dynamic rounding mode
// can be resolved from frm at decode.
// FP exception flags travel with the result to the ROB and are ORed into fflags at commit.
// C: compressed instructions are expanded in the IFU; uop.rvc gives the length (pc + 2).
//
//  Frontend : BPU(uBTB | BTB+TAGE | ITTAGE) -> FTQ -> IFU(predecode) -> IBuffer   (frontend.sv)
//  Backend  : Decode+Rename+Dispatch (DEC_W-wide)
//             -> one issue queue per unit: ALU(+BJU/MUL/DIV/I2F) x N_ALU, LDU x N_LDU, STA x N_STU,
//                STD x N_STD, FEX x N_FEX
//             -> RegRead -> Execute -> Writeback to the physical register file
//             ROB with in-order commit (DEC_W-wide) and backward walk for recovery
//  Memory   : load queue (+ RAW queue, load replay queue) / store queue, speculative loads with
//             store-to-load forwarding, memory-order violation detection after store address
//             generation, StoreSet memory dependence prediction, committed-store buffer
//
// Registers: one physical index space, integer pregs [0, INT_PRF_N) and FP pregs
// [INT_PRF_N, PRF_N), one rename table over the 64 architectural registers (x0..x31, f0..f31)
// and a free list per register class (separate int / FP register files).
//
// Pipeline timing (one ALU op):  IS | RR | EX | WB(write PRF, ROB done) ; dependents are woken at
// IS so back-to-back dependent ALU ops issue in consecutive cycles: operands are taken at RR from
// the PRF or from the results of this cycle (forward) / the WB stage (bypass)
// (WB_STAGE = 0: PRF and ROB written in EX, bypass in EX).
// Fixed-latency units (MUL 3, I2F 3, FALU 2, FMA 3, FCVT 4 cycles) give their result at IS+1+LAT on
// one write port per unit, reserved at issue; dependents are woken 2 cycles before the result.
// Loads: IS | RR | AGU | MEM(+forward, wakeup) | WB(write PRF)  -> load-to-use 4 cycles.
// DIV / FDIV / FSQRT: iterative units with their own write port, woken at the write.
module mm_core
    import mm_pkg::*;
    import cpu_pkg::*;
    import mm_muldiv_pkg::*;
    import mm_rvc_pkg::*;
#(
    parameter logic [63:0] RESET_PC = 64'h0
)
(
    input  logic clk,
    input  logic rst_n,
    // instruction memory load port
    input  logic        imem_wr_en,
    input  logic [IMEM_AW-1:0] imem_wr_addr,
    input  logic [31:0] imem_wr_data,
    // data bus: cacheable reads (one per LDU, combinational), committed stores (2 per cycle,
    // also MMIO), and one uncached read port used by MMIO loads at the ROB head
    output logic [N_LDU-1:0][63:0] dm_raddr,
    output logic [N_LDU-1:0][63:0] dm_raddr_n,    // next-cycle read address (synchronous RAM)
    input  logic [N_LDU-1:0][63:0] dm_rdata,
    output logic [1:0]             dm_we,
    output logic [1:0][63:0]       dm_waddr,
    output logic [1:0][63:0]       dm_wdata,
    output logic [1:0][7:0]        dm_wmask,
    output logic                   io_re,
    output logic [63:0]            io_raddr,
    input  logic [63:0]            io_rdata,
    output logic [63:0]            instret,       // retired instructions (SoC INSTRET register)
    // debug: register writeback ports (like debug_rd_value of the in-order cores)
    output logic [N_WB-1:0]       dbg_wb_valid,
    output logic [N_WB-1:0][63:0] dbg_wb_value
);

    localparam logic [31:0] HALT = 32'h0000_006f;

    // =====================================================================
    // global state declared early
    // =====================================================================
    redirect_t redir_q;            // redirect being applied this cycle
    logic      walking;
    logic      fwalk;              // forward walk after a snapshot restore
    rob_ptr_t  fw_ptr, fw_end;
    rob_ptr_t  walk_target;

    // physical register files (separate int / FP register files). Integer units read only
    // the integer file, FP units only the FP file; store data reads either.
    logic [63:0] prf_i [INT_PRF_N];
    logic [63:0] prf_f [FP_PRF_N];
`ifndef SYNTHESIS
    logic [63:0] prf [PRF_N];               // simulation view of both files (test benches)
    always_comb begin
        for (int p = 0; p < INT_PRF_N; p++) prf[p] = prf_i[p];
        for (int p = 0; p < FP_PRF_N; p++)  prf[INT_PRF_N + p] = prf_f[p];
    end
`endif
    logic busy      [PRF_N];
    preg_t rat [64];
    preg_t arch_rat [64];

    // CSRs
    logic [4:0]  fflags;
    logic [2:0]  frm;
    logic [63:0] cycle_cnt, instret_cnt;
    logic        csr_pend;               // a CSR instruction is between rename and commit
    rob_ptr_t    csr_rob;

    // ROB
    rob_ptr_t rob_head, rob_tail;
    logic        rob_done   [ROB_N];
    logic        rob_wen    [ROB_N];
    logic        rob_mv     [ROB_N];
    logic        rob_sta_f  [ROB_N];     // STD_SPLIT: the store's address part / data part has completed
    logic        rob_std_f  [ROB_N];     // MOVE_ELIM: eliminated move (no register allocated)
    logic [5:0]  rob_ldst   [ROB_N];
    preg_t       rob_pdest  [ROB_N];
    preg_t       rob_old    [ROB_N];
    logic        rob_is_ld  [ROB_N];
    logic        rob_is_st  [ROB_N];
    logic        rob_is_cfi [ROB_N];
    cfi_t        rob_cfi    [ROB_N];
    logic        rob_call   [ROB_N];
    logic        rob_rvc    [ROB_N];
    fu_t         rob_fu     [ROB_N];     // debug: unit class (performance analysis)
    logic [4:0]  rob_fflags [ROB_N];
    logic        rob_taken  [ROB_N];
    logic [SLOT_W-1:0] rob_off [ROB_N];      // pc = FTQ start + 2 * off
`ifndef SYNTHESIS
    logic [31:0] rob_insn   [ROB_N];          // simulation only (HALT detection in the test bench)
`endif
    ftq_ptr_t    rob_ftq    [ROB_N];

    // LSQ
    lq_ptr_t lq_head, lq_tail;
    rob_ptr_t    lq_rob   [LQ_N];
    logic        lq_exec  [LQ_N];
    logic [63:0] lq_addr  [LQ_N];
    logic [7:0]  lq_mask  [LQ_N];
    logic [SLOT_W-1:0] lq_off [LQ_N];
    ftq_ptr_t    lq_ftq   [LQ_N];
    sq_ptr_t     lq_sqptr [LQ_N];

    sq_ptr_t sq_head, sq_cmt, sq_tail;
    logic        sq_addrv [SQ_N];
    logic [63:0] sq_addr  [SQ_N];
    logic [63:0] sq_data  [SQ_N];   // aligned to the dword (STD_SPLIT: once address and data are both in)
    logic        sq_dv    [SQ_N];   // STD_SPLIT: the store data is in
    logic [63:0] sq_draw  [SQ_N];   //   as read by the STD (not yet aligned when the address comes later)
    ftq_ptr_t    sq_ftq   [SQ_N];   //   the store's pc (FTQ entry + slot) for StoreSet training on a
    logic [SLOT_W-1:0] sq_off [SQ_N];   //   forward from a store without data
    // STD_SPLIT store data pipelines (below)
    logic        std_rr_v [N_STD > 0 ? N_STD : 1]; uop_t std_rr [N_STD > 0 ? N_STD : 1];
    logic        std_ex_v [N_STD > 0 ? N_STD : 1]; uop_t std_ex [N_STD > 0 ? N_STD : 1];
    logic [63:0] std_dat  [N_STD > 0 ? N_STD : 1];
    logic        std_live [N_STD > 0 ? N_STD : 1];
    logic [7:0]  sq_mask  [SQ_N];

    // data memory is outside the core (ideal SRAM, no data cache)
    sq_ptr_t          sq_head_next;
    // committed-store buffer (SBUFFER, below): 16 B lines
    logic [SB_N-1:0]  sb_v;
    logic [59:0]      sb_tag  [SB_N];     // line address [63:4]
    logic [127:0]     sb_data [SB_N];
    logic [15:0]      sb_mask [SB_N];
    logic             sb_empty;
    logic [SB_N-1:0]  sb_infl;            // the line being written to memory this cycle (s1)
    assign sb_empty = !SBUFFER || sb_v == '0;
    logic             mmio_wq;              // MMIO_WREG: an MMIO store registered for its write the next cycle

    // wakeup network
    function automatic logic [N_WK-1:0] wk_fixed_mask();
        for (int q = 0; q < N_WK; q++) wk_fixed_mask[q] = wb_fixed(q);
    endfunction
    localparam logic [N_WK-1:0] WK_FIXED = wk_fixed_mask();     // wakeups of fixed-latency units
    function automatic logic [N_WK-1:0] wk_lds_mask();
        for (int q = 0; q < N_WK; q++) wk_lds_mask[q] = LD_SPEC_WAKE && q >= WB_LDU0 && q < WB_LDU0 + N_LDU;
    endfunction
    localparam logic [N_WK-1:0] WK_LDS = wk_lds_mask();         // LD_SPEC_WAKE: load wakeups (in AGU)
    // SPEC_WAKE: cancelled speculative wakeups (destinations of latency-1 uops that lost a read port)
    logic  [N_CAN-1:0] can_v;
    logic        ld_wk_v [N_LDU], ld_can_n [N_LDU];   // LD_SPEC_WAKE: wakeup in AGU / its cancel next cycle
    preg_t       ld_wk_p [N_LDU];
    preg_t [N_CAN-1:0] can_p;
    // match vector + reduction OR (an early return in the loop is built as a chain over the ports)
    function automatic logic cancelled(preg_t p, logic [N_CAN-1:0] cv, preg_t [N_CAN-1:0] cp);
        logic [N_CAN-1:0] m;
        for (int k = 0; k < N_CAN; k++) m[k] = cv[k] && cp[k] == p;
        return |m;
    endfunction
    logic  [N_WK-1:0] wk_valid;
    preg_t [N_WK-1:0] wk_preg;
    // BUSY_DLY: last cycle's wakeups, cancels and renamed destinations, applied to the busy table now
    logic  [N_WK-1:0]  wk_vq;
    preg_t [N_WK-1:0]  wk_pq;
    logic  [N_CAN-1:0] can_vq;
    preg_t [N_CAN-1:0] can_pq;
    logic  [PRF_N-1:0] rset_q;

    function automatic logic woken(preg_t p, logic [N_WK-1:0] wv, preg_t [N_WK-1:0] wp);
        logic [N_WK-1:0] m;
        for (int k = 0; k < N_WK; k++) m[k] = wv[k] && wp[k] == p;
        return |m;
    endfunction

    // writeback ports and the registered results of the previous cycle (= bypass sources)
    wb_t         wbp    [N_WB];
    logic        bp_v   [N_WB];
    preg_t       bp_p   [N_WB];
    logic [63:0] bp_val [N_WB];

    function automatic logic [63:0] bypass(preg_t p, logic [63:0] rf_val,
                                           logic bv [N_WB], preg_t bpp [N_WB], logic [63:0] bvl [N_WB]);
        for (int j = 0; j < N_WB; j++) if (bv[j] && bpp[j] == p) return bvl[j];
        return rf_val;
    endfunction

    // WB_STAGE: results of this cycle (forward) and the WB stage (results of the previous cycle,
    // written to the register file this cycle); the write to the register file and the ROB
    wb_t         wbq    [N_WB];
    wb_t         wbw    [N_WB];
    logic        fd_v   [N_WB];
    preg_t       fd_p   [N_WB];
    logic [63:0] fd_val [N_WB];
    logic [63:0] fd_ival [N_WB];     // value seen by integer consumers
    logic [63:0] fex0_cvt_r;         // FCVT_PIPE: FEX0's integer results (FCVT/FCMP/FMV.X) come from EX4
    always_comb
        for (int q = 0; q < N_WB; q++) begin
            fd_v[q]    = wbp[q].v && wbp[q].wen;
            fd_p[q]    = wbp[q].pdest;
            fd_val[q]  = wbp[q].val;
            fd_ival[q] = (FCVT_PIPE && q == WB_FEX0) ? fex0_cvt_r : wbp[q].val;
        end

    // operand at register read (bypass network: forward / bypass of the fixed-latency
    // units, else the register file). A register has one producer in flight, so the hits are
    // one-hot and combined by AND-OR.
    // cls: register files the operand can be in (bit 0 integer, bit 1 FP); only the ports writing
    // them are bypass sources
    function automatic logic [63:0] rr_operand(int cls, preg_t p, logic [63:0] rf_val,
                                               logic fv [N_WB], preg_t fp [N_WB], logic [63:0] fvl [N_WB],
                                               logic bv [N_WB], preg_t bpp [N_WB], logic [63:0] bvl [N_WB]);
        logic [63:0] r;
        logic hit;
        r = '0; hit = 1'b0;
        for (int j = 0; j < N_WB; j++)
            if (wb_fixed(j) && ((cls[0] && wb_writes_int(j)) || (cls[1] && wb_writes_fp(j)))) begin
                if (fv[j] && fp[j] == p)  begin r = r | fvl[j]; hit = 1'b1; end
                if (bv[j] && bpp[j] == p) begin r = r | bvl[j]; hit = 1'b1; end
            end else if (LD_SPEC_WAKE && j >= WB_LDU0 && j < WB_LDU0 + N_LDU) begin
                // a load woken in AGU: its value is in the WB stage register the cycle its consumer is in RR
                if (bv[j] && bpp[j] == p) begin r = r | bvl[j]; hit = 1'b1; end
            end
        return hit ? r : rf_val;
    endfunction

    // =====================================================================
    // Frontend
    // =====================================================================
    fetch_t [DEC_W-1:0] ib_out;
    logic   [DEC_W-1:0] ib_valid;
    logic   [$clog2(DEC_W+1)-1:0] ib_deq;

    logic [DEC_W-1:0]        cu_valid, cu_taken, cu_call, cu_rvc;
    logic [DEC_W-1:0][63:0]  cu_pc, cu_target;
    cfi_t [DEC_W-1:0]        cu_type;
    ftq_ptr_t [DEC_W-1:0]    cu_ftq;
    int                      cu_free;
    logic        cmt_ftq_valid;
    ftq_ptr_t    cmt_ftq;

    logic [63:0] pcm_start [FTQ_N], pcm_target [FTQ_N];   // FTQ PC memory
    // resolved target of the taken CFI of each FTQ block (predictor training at commit; a block
    // commits at most one taken CFI, the block ends there). The oldest writer of a cycle wins.
    logic [63:0] ftq_rtgt [FTQ_N];
`ifndef SYNTHESIS
    logic [63:0] dbg_rob_tgt [ROB_N];
    always_ff @(posedge clk)
        for (int k = 0; k < DEC_W; k++)
            if (BR_MISP_TAKEN && cu_valid[k] && cu_taken[k] && cu_target[k] != dbg_rob_tgt[cmt_idx[k][ROB_PW-2:0]])
                $error("FTQ target %h: pc %h ftq %0d rob %h type %0d", cu_target[k], cu_pc[k], cu_ftq[k],
                       dbg_rob_tgt[cmt_idx[k][ROB_PW-2:0]], cu_type[k]);
`endif
    function automatic logic [63:0] upc(logic [63:0] start, logic [SLOT_W-1:0] off);
        return start + 64'({off, 1'b0});
    endfunction
    // pc of the instruction a redirect re-executes (memory-order violation / MMIO replay), read from the
    // FTQ with the registered redirect (REDIR_PC_LATE)
    logic [63:0] redir_pc;
    assign redir_pc = REDIR_PC_LATE ? upc(pcm_start[redir_q.ftq_idx[FTQ_PW-2:0]], redir_q.off) : redir_q.target;
    function automatic logic [63:0] sximm(logic [31:0] i);
        return {{32{i[31]}}, i};
    endfunction

    frontend #(.RESET_PC(RESET_PC)) fe (
        .clk, .rst_n,
        .imem_wr_en, .imem_wr_addr, .imem_wr_data,
        .be_redir(redir_q),
        .cu_valid, .cu_pc, .cu_target, .cu_taken, .cu_type, .cu_call, .cu_rvc, .cu_ftq, .cu_free,
        .cmt_ftq_valid, .cmt_ftq,
        .pcm_start, .pcm_target,
        .ib_out, .ib_valid, .ib_deq
    );

    // =====================================================================
    // Decode stage: IBuffer -> decode -> DE buffer
    //   The DE buffer keeps what rename did not take (shifted to the front) and is refilled from
    //   the IBuffer. A redirect empties it.
    // =====================================================================
    dec_t   ib_d [DEC_W];
    for (genvar i = 0; i < DEC_W; i++) begin : g_dec
        mm_decode dec (.insn(ib_out[i].insn), .frm, .d(ib_d[i]));
    end
    // DE buffer: circular queue of 2 groups. The IBuffer refills it by the free space at the start
    // of the cycle (registered), so the refill does not wait for this cycle's rename.
    localparam int DQ = 2 * DEC_W;
    localparam int DQW = $clog2(DQ);
    fetch_t de_qf [DQ];
    dec_t   de_qd [DQ];
    logic [DQW-1:0] de_head;
    logic [DQW:0]   de_cnt;
    logic   de_v  [DEC_W];         // rename-stage view: the first DEC_W entries from the head
    fetch_t de_f  [DEC_W];
    dec_t   de_dq [DEC_W];
    int     de_take;
    // rename-stage view of the DE buffer; the dynamic rounding mode is resolved here, where a
    // CSR write to frm blocks younger instructions until it commits
    dec_t   d    [DEC_W];
    fetch_t rn_f [DEC_W];
    always_comb
        for (int i = 0; i < DEC_W; i++) begin
            de_v[i]  = i < int'(de_cnt);
            de_f[i]  = de_qf[(int'(de_head) + i) % DQ];
            de_dq[i] = de_qd[(int'(de_head) + i) % DQ];
            d[i]    = de_dq[i];
            if (de_f[i].insn[14:12] == 3'd7) d[i].rm = frm;
            rn_f[i] = de_f[i];
        end

    // =====================================================================
    // Rename stage: RAT, free lists, ROB / LQ / SQ allocation, snapshots.
    // The renamed group goes to the DP buffer (only when the DP buffer is empty or dispatches all of
    // its uops this cycle).
    // =====================================================================
    logic [$clog2(IQ_MAX+1)-1:0] iq_free [N_IQ];
    // free entries as dispatch sees them: a store needs one in its STA IQ and one in the paired STD IQ
    logic [$clog2(IQ_MAX+1)-1:0] iq_free_d [N_IQ];
    always_comb
        for (int q = 0; q < N_IQ; q++)
            iq_free_d[q] = (STD_SPLIT && q >= IQ_STU0 && q < IQ_STD0 && iq_free[q + N_STU] < iq_free[q]) ?
                           iq_free[q + N_STU] : iq_free[q];
    // free entries known at the start of the cycle: last cycle's count minus last cycle's enqueues
    // (a lower bound: entries issued last cycle show up one cycle later)
    logic [$clog2(IQ_MAX+1)-1:0] iq_free_q [N_IQ];
    int fu_rr [N_FU];        // round-robin start among the issue queues of each class

    // free lists (circular queues): first DEC_W free registers of each class
    localparam int FLI_N = INT_PRF_N - 32, FLF_N = FP_PRF_N - 32;
    // MOVE_ELIM: every register but x0's can be free; the capacity is rounded up to a power of two so that
    // the pointer arithmetic stays a plain wrap (INT_PRF_N - 1 made the head update a modulo adder)
    localparam int FLI_CAP = MOVE_ELIM ? 2 ** $clog2(INT_PRF_N - 1) : FLI_N;
    localparam int FLI_W = $clog2(2 * FLI_CAP), FLF_W = $clog2(2 * FLF_N);
    preg_t alloc_i [DEC_W], alloc_f [DEC_W];
    int    n_alloc_i, n_alloc_f;                 // free registers available
    int    n_wi_acc, n_wf_acc;                   // taken by rename this cycle
    logic [DEC_W-1:0] fr_i_v, fr_f_v;            // commit releases per class
    preg_t fr_p [DEC_W];
    preg_t fr_ip [DEC_W];                        // integer releases (MOVE_ELIM: one cycle after commit)
    int    wb_i, wb_f, fw_i, fw_f;               // backward / forward walk allocations per class
    logic [FLI_W-1:0] fli_head, snap_hi [SNAP_N], snap_hi_new;
    logic [FLF_W-1:0] flf_head, snap_hf [SNAP_N], snap_hf_new;
    logic snap_hit_w;
    int   snap_sel_w;
    mm_freelist #(.N(FLI_CAP), .NI(FLI_N), .BASE(32)) u_fli (
        .clk, .rst_n, .alloc(alloc_i), .avail(n_alloc_i), .n_alloc(n_wi_acc),
        .free_v(fr_i_v), .free_p(fr_ip), .restore(snap_hit_w), .restore_ptr(snap_hi[snap_sel_w]),
        .n_back(wb_i), .n_fwd(fw_i), .head(fli_head));
    mm_freelist #(.N(FLF_N), .BASE(INT_PRF_N + 32)) u_flf (
        .clk, .rst_n, .alloc(alloc_f), .avail(n_alloc_f), .n_alloc(n_wf_acc),
        .free_v(fr_f_v), .free_p(fr_p), .restore(snap_hit_w), .restore_ptr(snap_hf[snap_sel_w]),
        .n_back(wb_f), .n_fwd(fw_f), .head(flf_head));

    logic dp_ready;          // the DP buffer takes a new group this cycle
    logic can_rename;
    assign can_rename = !walking && !fwalk && !redir_q.valid && dp_ready;

    logic [DEC_W-1:0] acc;
    logic [DEC_W-1:0] acc_ref;    // sim check: the per-slot chain gives the same acceptance
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (rst_n && REN_GROUP_ACC && acc != acc_ref) $error("rename acceptance %b / %b", acc, acc_ref);
`endif
    logic [DEC_W-1:0] ren_pa;     // REN_GROUP_ACC: slot i is taken if the group is (valid, no CSR before it)
    uop_t r_uop [DEC_W];
    preg_t r_old [DEC_W];
    int   n_acc, n_ld_acc, n_st_acc;
    int   n_cls_acc [N_FU];
    // debug (performance analysis): why the first not-accepted instruction stalled at rename
    //   0 none, 1 DE buffer empty, 2 redirect / walk, 3 CSR serialization, 4 ROB full,
    //   5 int pregs, 6 FP pregs, 7 LQ full, 8 SQ full, 9 dispatch stage busy
    int   dbg_ren_stall;

    // issue queues of each class sorted by occupancy (most free entries first, ties: lower index)
    int iq_sorted [N_FU][N_IQ];
    always_comb begin
        for (int f = 0; f < N_FU; f++) begin
            for (int q = 0; q < N_IQ; q++) iq_sorted[f][q] = 0;
            for (int q = 0; q < N_IQ; q++) if (iq_has(q, f)) begin
                int rank;                                  // IQs of the class ahead of q
                rank = 0;
                for (int o = 0; o < N_IQ; o++)
                    if (iq_has(o, f) && (iq_free_d[o] > iq_free_d[q] || (iq_free_d[o] == iq_free_d[q] && o < q))) rank++;
                iq_sorted[f][rank] = q;
            end
        end
    end

    // group acceptance (REN_GROUP_ACC): room for the whole DE group in every resource; the group's
    // needs are counted from the DE queue (registers); the LSQ is checked by the group's count
    logic ren_room;
    always_comb begin
        int g_n, g_wi, g_wf, g_ld, g_st;
        g_n = 0; g_wi = 0; g_wf = 0; g_ld = 0; g_st = 0;
        for (int i = 0; i < DEC_W; i++) if (de_v[i]) begin
            g_n++;
            g_wi += int'(d[i].wen && !d[i].ldst[5] && !d[i].mv);
            g_wf += int'(d[i].wen &&  d[i].ldst[5]);
            g_ld += int'(d[i].ld_type != LOAD_DISABLE);
            g_st += int'(d[i].st_type != STORE_DISABLE);
        end
        ren_room = (rob_dist(rob_head, rob_tail) <= ROB_N - g_n) && (n_alloc_i >= g_wi) && (n_alloc_f >= g_wf)
                   && (lq_dist(lq_head, lq_tail) <= LQ_N - g_ld) && (sq_dist(sq_head, sq_tail) <= SQ_N - g_st);
    end
    always_comb begin
        int n_wi, n_wf, n_ld, n_st;
        logic stop, ok, wi, wf, csr_seen;
        int rob_cnt, lq_cnt, sq_cnt;
        rob_cnt = rob_dist(rob_head, rob_tail);
        lq_cnt  = lq_dist(lq_head, lq_tail);
        sq_cnt  = sq_dist(sq_head, sq_tail);
        n_wi = 0; n_wf = 0; n_ld = 0; n_st = 0;
        stop = 1'b0;
        csr_seen = 1'b0;
        acc = '0; acc_ref = '0;
        dbg_ren_stall = de_v[0] ? 0 : 1;
        for (int i = 0; i < DEC_W; i++) begin
            logic pa;
            wi = d[i].wen && !d[i].ldst[5] && !d[i].mv;     // a move allocates nothing
            wf = d[i].wen &&  d[i].ldst[5];
            // REN_GROUP_ACC: the group is taken whole up to a CSR, so whether slot i would be taken (pa) is
            // known from the DE queue alone; pdest / LSQ pointers are indexed by counts over pa (used only when
            // the group is taken), which keeps the free-list count and the room check off those paths
            pa = de_v[i] && !csr_seen;
            ren_pa[i] = pa;
            ok = !stop && can_rename && de_v[i] && !csr_pend && !csr_seen
                 && (REN_GROUP_ACC ? ren_room :
                     ((i < ROB_N - rob_cnt)
                      && (n_wi + int'(wi) <= n_alloc_i)
                      && (n_wf + int'(wf) <= n_alloc_f)
                      && (d[i].ld_type == LOAD_DISABLE  || n_ld < LQ_N - lq_cnt)
                      && (d[i].st_type == STORE_DISABLE || n_st < SQ_N - sq_cnt)));
            if (REN_GROUP_ACC) begin
                // the whole group or nothing: slot i is taken when it would be (pa) and the group is; written
                // without the slot-to-slot stop chain (same value as ok)
                acc[i] = pa && can_rename && !csr_pend && ren_room;
                acc_ref[i] = ok;
                r_uop[i].pdest  = wf ? alloc_f[n_wf] : (wi ? alloc_i[n_wi] : '0);
                r_uop[i].lq_ptr = lq_add(lq_tail, n_ld);
                r_uop[i].sq_ptr = sq_add(sq_tail, n_st);
                if (pa) begin
                    n_wi += int'(wi);
                    n_wf += int'(wf);
                    n_ld += int'(d[i].ld_type != LOAD_DISABLE);
                    n_st += int'(d[i].st_type != STORE_DISABLE);
                    if (d[i].fu == FU_CSR) csr_seen = 1'b1;
                end
                if (!ok && !stop && de_v[i]) begin
                    dbg_ren_stall = !can_rename ? (dp_ready ? 2 : 9) : (csr_pend || csr_seen) ? 3 : 4;
                    stop = 1'b1;
                end
            end else if (ok) begin
                acc[i] = 1'b1;
                r_uop[i].pdest  = wf ? alloc_f[n_wf] : (wi ? alloc_i[n_wi] : '0);
                r_uop[i].lq_ptr = lq_add(lq_tail, n_ld);
                r_uop[i].sq_ptr = sq_add(sq_tail, n_st);
                n_wi += int'(wi);
                n_wf += int'(wf);
                n_ld += int'(d[i].ld_type != LOAD_DISABLE);
                n_st += int'(d[i].st_type != STORE_DISABLE);
                if (d[i].fu == FU_CSR) csr_seen = 1'b1;    // nothing younger in the same group
            end else begin
                if (!stop && de_v[i])
                    dbg_ren_stall = !can_rename ? (dp_ready ? 2 : 9) : (csr_pend || csr_seen) ? 3 : !(i < ROB_N - rob_cnt) ? 4 :
                                    !(n_wi + int'(wi) <= n_alloc_i) ? 5 : !(n_wf + int'(wf) <= n_alloc_f) ? 6 :
                                    !(d[i].ld_type == LOAD_DISABLE || n_ld < LQ_N - lq_cnt) ? 7 : 8;
                stop = 1'b1;
                r_uop[i].pdest  = '0;
                r_uop[i].lq_ptr = '0;
                r_uop[i].sq_ptr = '0;
            end
        end
        if (REN_GROUP_ACC) begin
            // totals of the taken slots (acc is all of pa or nothing)
            n_wi_acc = 0; n_wf_acc = 0; n_ld_acc = 0; n_st_acc = 0;
            for (int i = 0; i < DEC_W; i++) if (acc[i]) begin
                n_wi_acc += int'(d[i].wen && !d[i].ldst[5] && !d[i].mv);
                n_wf_acc += int'(d[i].wen &&  d[i].ldst[5]);
                n_ld_acc += int'(d[i].ld_type != LOAD_DISABLE);
                n_st_acc += int'(d[i].st_type != STORE_DISABLE);
            end
        end else begin
            n_wi_acc = can_rename ? n_wi : 0;
            n_wf_acc = can_rename ? n_wf : 0;
            n_ld_acc = n_ld; n_st_acc = n_st;
        end
        n_acc = 0;
        for (int i = 0; i < DEC_W; i++) n_acc += int'(acc[i]);

        // register renaming with intra-group bypass
        for (int i = 0; i < DEC_W; i++) begin
            r_uop[i].psrc1 = d[i].use1 ? rat[d[i].lsrc1] : '0;
            r_uop[i].psrc2 = d[i].use2 ? rat[d[i].lsrc2] : '0;
            r_uop[i].psrc3 = d[i].use3 ? rat[d[i].lsrc3] : '0;
            r_old[i] = rat[d[i].ldst];
            for (int j = 0; j < i; j++) begin
                // (REN_GROUP_ACC: by pa, so the room checks are not on the bypass; equal to acc when i is taken)
                if ((REN_GROUP_ACC ? ren_pa[j] : acc[j]) && d[j].wen) begin
                    if (d[i].use1 && d[j].ldst == d[i].lsrc1) r_uop[i].psrc1 = r_uop[j].pdest;
                    if (d[i].use2 && d[j].ldst == d[i].lsrc2) r_uop[i].psrc2 = r_uop[j].pdest;
                    if (d[i].use3 && d[j].ldst == d[i].lsrc3) r_uop[i].psrc3 = r_uop[j].pdest;
                    if (d[j].ldst == d[i].ldst) r_old[i] = r_uop[j].pdest;
                end
            end
            if (d[i].mv) r_uop[i].pdest = r_uop[i].psrc1;      // MOVE_ELIM: the source's register

            r_uop[i].imm         = d[i].imm[31:0];
            r_uop[i].alu_code    = d[i].alu_code;
            r_uop[i].op1_pc      = d[i].op1_pc;
            r_uop[i].op2_imm     = d[i].op2_imm;
            r_uop[i].fu          = d[i].fu;
            r_uop[i].lat         = d[i].lat;
            r_uop[i].rf_wen      = d[i].wen;
            r_uop[i].ld_type     = d[i].ld_type;
            r_uop[i].st_type     = d[i].st_type;
            r_uop[i].ld_fp32     = d[i].ld_fp32;
            r_uop[i].fop         = d[i].fop;
            r_uop[i].fmt         = d[i].fmt;
            r_uop[i].rm          = d[i].rm;
            r_uop[i].ityp        = d[i].ityp;
            r_uop[i].mdfn        = d[i].mdfn;
            r_uop[i].word        = d[i].word;
            r_uop[i].is_call     = d[i].is_call;
            r_uop[i].is_ret      = d[i].is_ret;
            r_uop[i].pred_taken  = rn_f[i].pred_taken;
            r_uop[i].ftq_idx     = rn_f[i].ftq_idx;
            r_uop[i].off         = rn_f[i].off;
            r_uop[i].rob_idx     = rob_add(rob_tail, i);
            if (MDP_STORESET) begin
                // StoreSet: wait for the youngest older store of the same set (this group first, then LFST)
                logic [7:0] si;
                si = ssit_idx(rn_f[i].pc);
                r_uop[i].ld_wait = 1'b0;
                r_uop[i].ld_wsq  = '0;
                r_uop[i].ld_wrob = '0;
                if (d[i].fu == FU_LDU && ssit_v[si]) begin
                    if (lfst_v[ssit_id[si]]) begin
                        r_uop[i].ld_wait = 1'b1; r_uop[i].ld_wsq = lfst_sq[ssit_id[si]];
                        r_uop[i].ld_wrob = lfst_rob[ssit_id[si]];
                    end
                    for (int j = 0; j < i; j++) begin
                        logic [7:0] sj;
                        sj = ssit_idx(rn_f[j].pc);
                        if (acc[j] && d[j].fu == FU_STU && ssit_v[sj] && ssit_id[sj] == ssit_id[si]) begin
                            r_uop[i].ld_wait = 1'b1; r_uop[i].ld_wsq = r_uop[j].sq_ptr;
                            r_uop[i].ld_wrob = r_uop[j].rob_idx;
                        end
                    end
                end
            end else begin
                r_uop[i].ld_wait = (d[i].fu == FU_LDU) && lwt[lwt_idx(rn_f[i].pc)];
                r_uop[i].ld_wsq  = '0;
                r_uop[i].ld_wrob = '0;
            end
            r_uop[i].rvc         = rn_f[i].rvc;
        end
    end

    // issue queue of each renamed uop, chosen here and kept with the DP group (registered when the
    // group enters dispatch, from the occupancy of last cycle)
    // The rank of a uop among the earlier uops of its class is kept modulo the class's IQ count by a
    // wrap at a constant compare per class (ncls[f] % class_n(f) with f known only at run time is a
    // divider: 107 levels in Vivado).
    localparam int NCW = $clog2(N_IQ + 1);
    function automatic logic [NCW-1:0] ncls_inc(logic [NCW-1:0] c, int k);
        return (int'(c) + 1 >= class_n(k)) ? '0 : c + 1'b1;
    endfunction
    int rn_q [DEC_W];
    always_comb begin
        logic [NCW-1:0] ncls [N_FU];
        int ncla [N_FU];
        int f;
        logic cs;
        for (int k = 0; k < N_FU; k++) ncls[k] = '0;
        for (int k = 0; k < N_FU; k++) ncla[k] = 0;
        cs = 1'b0;
        for (int i = 0; i < DEC_W; i++) begin
            f = int'(d[i].fu);
            rn_q[i] = 0;
            for (int k = 0; k < N_FU; k++)
                if (f == k && class_n(k) > 0)
                    rn_q[i] = IQ_BALANCE ? iq_sorted[k][ncls[k]] : class_iq(k, (fu_rr[k] + int'(ncls[k])) % class_n(k));
            // REN_GROUP_ACC: counted over the slots that would be taken (see above), not over acc
            if (REN_GROUP_ACC ? (de_v[i] && !cs) : acc[i])
                for (int k = 0; k < N_FU; k++) if (f == k) ncls[k] = ncls_inc(ncls[k], k);
            if (de_v[i] && d[i].fu == FU_CSR) cs = 1'b1;
            if (acc[i]) ncla[f]++;
        end
        for (int k = 0; k < N_FU; k++) n_cls_acc[k] = can_rename ? ncla[k] : 0;
    end

    // DE buffer refill (free space at the start of the cycle) and release (rename)
    always_comb begin
        de_take = 0;
        for (int i = 0; i < DEC_W; i++)
            if (de_take == i && i < DQ - int'(de_cnt) && ib_valid[i] && !redir_q.valid) de_take = i + 1;
    end
    assign ib_deq = ($clog2(DEC_W+1))'(de_take);
    always_ff @(posedge clk) begin
        if (!rst_n || redir_q.valid) begin
            de_head <= '0;
            de_cnt  <= '0;
        end else begin
            de_head <= DQW'(int'(de_head) + n_acc);
            de_cnt  <= (DQW+1)'(int'(de_cnt) + de_take - n_acc);
        end
    end
    // MV_NOCHAIN: a move whose source is written by a move among the DEC_W - 1 instructions before it
    // (a superset of the earlier moves of its rename group) is kept as an ordinary op; decided here
    // from the decoded fields so rename starts from the registered bit. The last DEC_W - 1 entered
    // instructions are kept (moves and their destinations); a redirect clears them
    localparam int NH = (DEC_W > 1) ? DEC_W - 1 : 1;
    logic       mh_v [NH];
    logic [5:0] mh_d [NH];
    dec_t       ib_dm [DEC_W];
    always_comb
        for (int j = 0; j < DEC_W; j++) begin
            ib_dm[j] = ib_d[j];
            if (MV_NOCHAIN && ib_d[j].mv) begin
                for (int h = 0; h < NH; h++)
                    if (mh_v[h] && mh_d[h] == ib_d[j].lsrc1) ib_dm[j].mv = 1'b0;
                for (int i = 0; i < j; i++)
                    if (ib_d[i].mv && ib_d[i].ldst == ib_d[j].lsrc1) ib_dm[j].mv = 1'b0;
            end
        end
    always_ff @(posedge clk) begin
        if (!rst_n || redir_q.valid) begin
            for (int h = 0; h < NH; h++) mh_v[h] <= 1'b0;
        end else begin
            // the instructions entered so far, oldest first: the kept ones, then this cycle's
            logic       lv [NH + DEC_W];
            logic [5:0] ld [NH + DEC_W];
            for (int h = 0; h < NH; h++) begin lv[h] = mh_v[h]; ld[h] = mh_d[h]; end
            for (int j = 0; j < DEC_W; j++) begin lv[NH + j] = ib_d[j].mv; ld[NH + j] = ib_d[j].ldst; end
            for (int h = 0; h < NH; h++) begin
                mh_v[h] <= lv[h + de_take];
                mh_d[h] <= ld[h + de_take];
            end
        end
    end
    for (genvar k = 0; k < DQ; k++) begin : g_de
        always_ff @(posedge clk) begin
            int j;
            j = (k - int'(de_head) - int'(de_cnt) + 2 * DQ) % DQ;    // k is the j-th slot after the tail
            if (j < de_take) begin
                de_qf[k] <= ib_out[j % DEC_W];
                de_qd[k] <= ib_dm[j % DEC_W];
            end
        end
    end
`ifndef SYNTHESIS
    // the rename group holds no eliminated move whose source an earlier move of the group writes
    always_ff @(posedge clk)
        if (rst_n && MV_NOCHAIN)
            for (int i = 0; i < DEC_W; i++)
                for (int j = 0; j < i; j++)
                    if (de_v[i] && de_v[j] && d[i].mv && d[j].mv && d[j].ldst == d[i].lsrc1)
                        $error("MV_NOCHAIN: move chain in the rename group (slots %0d -> %0d)", j, i);
`endif

    // =====================================================================
    // Dispatch stage: the DP group is enqueued in order into the issue queues
    // chosen at rename; a uop goes out when its queue has a free entry and an enqueue port (the
    // earlier remaining uops of the group bound to the same queue take the first ports).
    // Operand readiness is read from the busy table here.
    // =====================================================================
    // register cache (declared here for the dispatch lookup and the issue queues; see REGCACHE below)
    logic [N_RC-1:0]       rc_rd_ok;               // entry valid and kept: readable next cycle
    logic [N_RCW-1:0]      rcw_v;                  // cache writer k writes preg rcw_p[k] into entry rcw_i[k]
    preg_t [N_RCW-1:0]     rcw_p;
    logic [N_RCW-1:0]      rcw_vi;                 // ... to the issue queues (RC_TRK_NOKILL: before the kill)
    logic [N_RCW-1:0][RC_IW-1:0] rcw_i;
    logic [N_RC-1:0]       rc_tag_hit [DEC_W][3];  // dispatch lookup (register cache tags)
    logic [2:1]            dp_rcu [DEC_W];
    logic [2:1][RC_IW-1:0] dp_rci [DEC_W];
    logic [2:1]            iq_rcu [N_IQ][2];       // RC_TRACK: the selected uops' sources in the cache
    logic [2:1][RC_IW-1:0] iq_rci [N_IQ][2];
    logic dp_v [DEC_W];
    uop_t dp_u [DEC_W];
    int   dp_q [DEC_W];
    logic [DEC_W-1:0] dacc;
    int   slot_q [DEC_W];
    int   slot_e [DEC_W];
    logic r_rdy1 [DEC_W];
    logic r_rdy2 [DEC_W];
    logic r_rdy3 [DEC_W];
    // pregs written by a fixed-latency unit's wakeup last cycle (their consumers dispatched now and
    // issued next cycle take the value from the bypass network: no register-file read port)
    logic [PRF_N-1:0] fresh_p;
    always_ff @(posedge clk) begin
        logic [PRF_N-1:0] f;
        f = '0;
        for (int k = 0; k < N_WK; k++) if (wk_valid[k] && WK_FIXED[k]) f[wk_preg[k]] = 1'b1;
        fresh_p <= f;
    end
    int   dbg_dp_stall;      // 0 none, 1 issue queue full, 2 IQ enqueue ports (2 / cycle)
    int   dbg_dp_stall_fu;   // class of the first uop that could not be dispatched
    always_comb begin
        logic [DEC_W-1:0] blk;     // a valid uop that cannot go this cycle (its own condition only)
        logic stop;
        logic bz;      // the busy bit as the direct update would have it this cycle (BUSY_DLY: last cycle's
                       // renamed destination sets it, else a registered wakeup clears it, else a registered
                       // cancel sets it)
        int e;
        stop = 1'b0;
        dacc = '0;
        dbg_dp_stall = 0; dbg_dp_stall_fu = 0;
        // each uop's condition does not depend on the earlier ones going: a uop goes when no earlier
        // one is blocked (prefix OR), and the group is out when none is (one wide AND, not a chain
        // through the slots: dp_ready feeds the rename acceptance)
        for (int i = 0; i < DEC_W; i++) begin
            e = 0;
            for (int j = 0; j < i; j++) if (dp_v[j] && dp_q[j] == dp_q[i]) e++;
            slot_q[i] = dp_q[i];
            slot_e[i] = e;
            blk[i] = dp_v[i] && !(!redir_q.valid && (e < IQ_ENQ) && (e < int'(iq_free_q[dp_q[i]])));
        end
        for (int i = 0; i < DEC_W; i++) begin
            dacc[i] = dp_v[i] && !blk[i] && (i == 0 || (blk & ((DEC_W)'(1) << i) - 1'b1) == '0);
            if (blk[i] && !stop) begin
                dbg_dp_stall = (slot_e[i] < IQ_ENQ) ? 1 : 2;
                dbg_dp_stall_fu = int'(dp_u[i].fu);
                stop = 1'b1;
            end
            bz = busy[dp_u[i].psrc1];
            if (BUSY_DLY) bz = rset_q[dp_u[i].psrc1] || (!woken(dp_u[i].psrc1, wk_vq, wk_pq) &&
                                (bz || cancelled(dp_u[i].psrc1, can_vq, can_pq)));
            r_rdy1[i] = (!bz && !cancelled(dp_u[i].psrc1, can_v, can_p)) ||
                          (!ENQ_DELAY && woken(dp_u[i].psrc1, wk_valid, wk_preg));
            bz = busy[dp_u[i].psrc2];
            if (BUSY_DLY) bz = rset_q[dp_u[i].psrc2] || (!woken(dp_u[i].psrc2, wk_vq, wk_pq) &&
                                (bz || cancelled(dp_u[i].psrc2, can_vq, can_pq)));
            r_rdy2[i] = (!bz && !cancelled(dp_u[i].psrc2, can_v, can_p)) ||
                          (!ENQ_DELAY && woken(dp_u[i].psrc2, wk_valid, wk_preg));
            bz = busy[dp_u[i].psrc3];
            if (BUSY_DLY) bz = rset_q[dp_u[i].psrc3] || (!woken(dp_u[i].psrc3, wk_vq, wk_pq) &&
                                (bz || cancelled(dp_u[i].psrc3, can_vq, can_pq)));
            r_rdy3[i] = (!bz && !cancelled(dp_u[i].psrc3, can_v, can_p)) ||
                          (!ENQ_DELAY && woken(dp_u[i].psrc3, wk_valid, wk_preg));
        end
        dp_ready = blk == '0;              // every valid uop of the group is dispatched now
    end
    for (genvar q = 0; q < N_IQ; q++) begin : g_iqfree
        always_ff @(posedge clk) begin
            int n;
            n = 0;
            for (int i = 0; i < DEC_W; i++) if (dacc[i] && slot_q[i] == q) n++;
            if (!rst_n) iq_free_q[q] <= '0;
            else        iq_free_q[q] <= ($clog2(IQ_MAX+1))'(int'(iq_free_d[q]) - n);
        end
    end
    // a blocked group re-selects the issue queues of its remaining uops (re-computed while the group
    // is waiting)
    int dp_rsel [DEC_W];
    always_comb begin
        logic [NCW-1:0] ncls [N_FU];
        int f;
        for (int k = 0; k < N_FU; k++) ncls[k] = '0;
        for (int i = 0; i < DEC_W; i++) begin
            f = int'(dp_u[i].fu);
            dp_rsel[i] = IQ_BALANCE ? 0 : dp_q[i];
            if (IQ_BALANCE)
                for (int k = 0; k < N_FU; k++) if (f == k && class_n(k) > 0) dp_rsel[i] = iq_sorted[k][ncls[k]];
            if (dp_v[i] && !dacc[i])
                for (int k = 0; k < N_FU; k++) if (f == k) ncls[k] = ncls_inc(ncls[k], k);
        end
    end
    for (genvar k = 0; k < DEC_W; k++) begin : g_dp
        always_ff @(posedge clk) begin
            if (!rst_n || redir_q.valid) dp_v[k] <= 1'b0;
            else if (dp_ready) begin
                dp_v[k] <= acc[k] && !d[k].mv;     // MOVE_ELIM: done at rename
                dp_u[k] <= r_uop[k];
                dp_q[k] <= rn_q[k];
            end else begin
                if (dacc[k]) dp_v[k] <= 1'b0;
                dp_q[k] <= dp_rsel[k];
            end
        end
    end

    // issue queue enqueue ports
    logic [IQ_ENQ-1:0] iq_enq_v    [N_IQ];
    uop_t [IQ_ENQ-1:0] iq_enq_uop  [N_IQ];
    logic [IQ_ENQ-1:0] iq_enq_r1   [N_IQ];
    logic [IQ_ENQ-1:0] iq_enq_r2   [N_IQ];
    logic [IQ_ENQ-1:0] iq_enq_r3   [N_IQ];
    logic [IQ_ENQ-1:0][3:1] iq_enq_fr [N_IQ];
    logic [IQ_ENQ-1:0][2:1] iq_enq_ru [N_IQ];
    logic [IQ_ENQ-1:0][2:1][RC_IW-1:0] iq_enq_ri [N_IQ];
    // per issue queue / enqueue port: pick the renamed slot routed there (constant indices)
    for (genvar q = 0; q < N_IQ; q++) begin : g_enq
        for (genvar ep = 0; ep < IQ_ENQ; ep++) begin : g_port
            // STD_SPLIT: an STD IQ takes the stores of its STA IQ (SQI) on the same port
            localparam int SQI = (STD_SPLIT && q >= IQ_STD0 && q < IQ_FEX0) ? q - N_STU : q;
            always_comb begin
                iq_enq_v[q][ep]   = 1'b0;
                iq_enq_uop[q][ep] = dp_u[0];
                iq_enq_r1[q][ep]  = 1'b0;
                iq_enq_r2[q][ep]  = 1'b0;
                iq_enq_r3[q][ep]  = 1'b0;
                iq_enq_fr[q][ep]  = '0;
                iq_enq_ru[q][ep]  = '0;
                iq_enq_ri[q][ep]  = '0;
                for (int i = 0; i < DEC_W; i++) begin
                    if (dacc[i] && slot_q[i] == SQI && slot_e[i] == ep) begin
                        iq_enq_v[q][ep]   = 1'b1;
                        iq_enq_uop[q][ep] = dp_u[i];
                        iq_enq_r1[q][ep]  = r_rdy1[i];
                        iq_enq_r2[q][ep]  = r_rdy2[i];
                        iq_enq_r3[q][ep]  = r_rdy3[i];
                        iq_enq_fr[q][ep]  = {fresh_p[dp_u[i].psrc3], fresh_p[dp_u[i].psrc2], fresh_p[dp_u[i].psrc1]};
                        iq_enq_ru[q][ep]  = dp_rcu[i];
                        iq_enq_ri[q][ep]  = dp_rci[i];
                    end
                end
                if (STD_SPLIT && q >= IQ_STU0 && q < IQ_STD0) begin      // STA: no data operand
                    iq_enq_uop[q][ep].psrc2 = '0;
                    iq_enq_r2[q][ep]  = 1'b1;
                    iq_enq_fr[q][ep][2] = 1'b0;
                    iq_enq_ru[q][ep][2] = 1'b0;
                end
                if (STD_SPLIT && q >= IQ_STD0 && q < IQ_FEX0) begin      // STD: no address operand
                    iq_enq_uop[q][ep].psrc1 = '0;
                    iq_enq_r1[q][ep]  = 1'b1;
                    iq_enq_fr[q][ep][1] = 1'b0;
                    iq_enq_ru[q][ep][1] = 1'b0;
                end
            end
        end
    end

    // =====================================================================
    // Memory dependence predictor: load wait table (indexed by load PC)
    //   a load that caused a memory-order violation is marked; later instances
    //   wait in the issue queue until every older store has its address.
    // =====================================================================
    logic [LWT_N-1:0] lwt;
    // StoreSet tables
    logic [SSIT_N-1:0]  ssit_v;
    logic [SSID_W-1:0]  ssit_id [SSIT_N];
    logic [(1<<SSID_W)-1:0] lfst_v;
    sq_ptr_t            lfst_sq [1 << SSID_W];
    rob_ptr_t           lfst_rob [1 << SSID_W];
    rob_ptr_t           sq_rob [SQ_N];   // ROB index of the store in each SQ entry
    rob_ptr_t [SQ_N-1:0] sq_rob_vec;
    always_comb for (int i = 0; i < SQ_N; i++) sq_rob_vec[i] = sq_rob[i];
    logic [15:0]        ssit_clear_cnt;
    function automatic logic [7:0] ssit_idx(logic [63:0] pc);
        return pc[1 +: 8] ^ pc[9 +: 8];
    endfunction
    logic [SQ_N-1:0] sq_addrv_vec;
    // (StoreSet: a load waits until the store has its address and, with STD_SPLIT, its data)
    always_comb for (int i = 0; i < SQ_N; i++) sq_addrv_vec[i] = sq_addrv[i] && (!STD_SPLIT || sq_dv[i]);
    function automatic logic [$clog2(LWT_N)-1:0] lwt_idx(logic [63:0] pc);
        return pc[2 +: $clog2(LWT_N)] ^ $clog2(LWT_N)'(pc[1]);
    endfunction
    logic [$clog2(LWT_N)-1:0] lwt_set;
    assign lwt_set = lwt_idx(redir_pc);
    logic [11:0]      lwt_clear_cnt;
    sq_ptr_t          sq_rdy_ptr;        // first older store without an address (or SQ tail)
    always_comb begin
        logic found;
        found = 1'b0;
        sq_rdy_ptr = sq_tail;
        for (int i = 0; i < SQ_N; i++) begin
            sq_ptr_t p;
            p = sq_add(sq_head, i);
            if (!found && p != sq_tail && !sq_addrv_vec[p[SQ_PW-2:0]]) begin
                found = 1'b1;
                sq_rdy_ptr = p;
            end
            if (p == sq_tail) found = 1'b1;
        end
    end

    // =====================================================================
    // Issue queues
    // =====================================================================
    logic iq_iss_v [N_IQ];                // issued: selected and won its read ports
    uop_t iq_iss   [N_IQ];
    logic iq_iss2_v [N_IQ];               // BJU port (BJU_PORT, IQ 0..N_BJU-1)
    uop_t iq_iss2   [N_IQ];
    logic iq_sel_v [N_IQ], iq_sel2_v [N_IQ];     // selected by the issue queue
    logic iq_l1 [N_IQ], iq_l12 [N_IQ];           // IQ_WK_FAST: selected, latency 1, writes a register
    logic iq_sw_v [N_IQ], iq_sw2_v [N_IQ];       // ... before the squash (speculative wakeup, IQ_KILL_LATE)
    logic [3:1] iq_fr [N_IQ], iq_fr2 [N_IQ];     // operands taken from the bypass network
    logic iq_ok [N_IQ], iq_ok2 [N_IQ];           // won the integer read ports
    logic rp_go [N_LDU];                          // LD_REPLAY: a replayed load takes the pipe (holds back the LDU IQ)
    logic [N_FU-1:0] iq_blk [N_IQ];      // classes that may not issue (iterative unit busy)
    logic div_pend;                      // a DIV is between issue and writeback
    logic div_blk;                       // DIV_OVL: the divider takes no start two cycles from now
    logic fdiv_pend [N_FDIV];
    logic fdiv_blk [N_FDIV];             // FDIV_OVL: the FDIV engine takes no start two cycles from now
    always_comb begin
        for (int q = 0; q < N_IQ; q++) iq_blk[q] = '0;
        iq_blk[DIV_IQ][FU_DIV] = (DIV_SRT && DIV_OVL) ? div_blk : div_pend;
        for (int j = 0; j < N_FDIV; j++) iq_blk[IQ_FEX0 + 1 + j][FU_FDIV] = (FDIV_SRT && FDIV_OVL) ? fdiv_blk[j] : fdiv_pend[j];
    end

    for (genvar k = 0; k < N_IQ; k++) begin : g_iq
        localparam int QN = (k < N_BJU) ? IQ_N_BJU : (k < N_ALU) ? IQ_N_ALU : (k < IQ_STU0) ? IQ_N_LDU :
                            (k < IQ_FEX0) ? IQ_N_STU : IQ_N_FEX;     // (STD IQs: the STA IQs' size)
        issue_queue #(.N(QN), .DUAL(BJU_PORT && k < N_BJU), .CSR(iq_has(k, FU_CSR))) iq (
            .clk, .rst_n, .redir(redir_q),
            .enq_valid(iq_enq_v[k]), .enq_uop(iq_enq_uop[k]),
            .enq_rdy1(iq_enq_r1[k]), .enq_rdy2(iq_enq_r2[k]), .enq_rdy3(iq_enq_r3[k]), .enq_fresh(iq_enq_fr[k]),
            .free_cnt(iq_free[k]),
            .sq_head, .sq_tail, .sq_rdy_ptr, .sq_addrv(sq_addrv_vec), .sq_rob(sq_rob_vec),
            .blk(iq_blk[k]),
            .rob_head,
            .wk_valid, .wk_preg,
            .iss_valid(iq_sel_v[k]), .iss_sv(iq_sw_v[k]), .iss2_sv(iq_sw2_v[k]), .iss_uop(iq_iss[k]), .iss_fresh(iq_fr[k]), .iss_ok(iq_ok[k]),
            .iss_l1(iq_l1[k]), .iss2_l1(iq_l12[k]),
            .iss2_valid(iq_sel2_v[k]), .iss2_uop(iq_iss2[k]), .iss2_fresh(iq_fr2[k]), .iss2_ok(iq_ok2[k]),
            .wk_fixed(WK_FIXED), .wk_lds(WK_LDS),
            .cancel_v(can_v), .cancel_p(can_p),
            .enq_rcu(iq_enq_ru[k]), .enq_rci(iq_enq_ri[k]),
            .rc_ok(rc_rd_ok), .rcw_v(rcw_vi), .rcw_p, .rcw_i,
            .iss_rcu(iq_rcu[k][0]), .iss_rci(iq_rci[k][0]), .iss2_rcu(iq_rcu[k][1]), .iss2_rci(iq_rci[k][1])
        );
        assign iq_iss_v[k]  = iq_sel_v[k] && iq_ok[k];
        assign iq_iss2_v[k] = iq_sel2_v[k] && iq_ok2[k];
    end

    // ---------------------------------------------------------------------
    // Integer register-file read ports (IRP_ARB, arbitrated at IS): every register operand of a
    // selected uop that is not taken from the bypass network requests its fixed read port; per port
    // the highest-priority request wins. A uop with a losing operand is not issued this cycle (it stays
    // in its issue queue: no wakeup, no write-port reservation). The winners' addresses are registered
    // and the register file is read with them in RR.
    // ---------------------------------------------------------------------
    function automatic logic irp_has(int q, int d, int src);    // operand slot exists
        if (q >= IQ_FEX0) return 1'b0;
        if (d == 1 && !(BJU_PORT && q < N_BJU)) return 1'b0;
        if (q >= IQ_LDU0 && q < IQ_STU0 && src == 2) return 1'b0;
        if (STD_SPLIT && q >= IQ_STU0 && q < IQ_STD0 && src == 2) return 1'b0;   // STA: address only
        if (STD_SPLIT && q >= IQ_STD0 && q < IQ_FEX0 && src == 1) return 1'b0;   // STD: data only
        return 1'b1;
    endfunction
    logic        irp_rq   [N_IQ][2][3];
    logic        irp_lose [N_IQ][2][3];
    preg_t       irp_a    [N_IQ][2][3];
    preg_t       rp_addr_n [N_IRP];
    preg_t       rp_addr   [N_IRP];
    logic [63:0] rp_data   [N_IRP];

    // ---------------------------------------------------------------------
    // Register cache (REGCACHE): each ALU / load writeback port owns RC_DI / RC_DM
    // entries filled round-robin with its integer results, written in the same cycle as the register
    // file (so an entry is readable exactly when the register file is). An entry is dropped when its
    // preg comes up for allocation. At IS an operand that hits an entry not being
    // overwritten this cycle makes no read-port request; the hit is registered and RR reads the entry.
    // ---------------------------------------------------------------------
    function automatic int rc_port(int e);      // writeback port of entry e
        if (e < N_ALU * RC_DI) return e / RC_DI;
        if (e < N_RCI)         return WB_BJU0 + (e - N_ALU * RC_DI) / RC_DB;
        return WB_LDU0 + (e - N_RCI) / RC_DM;
    endfunction
    function automatic int rc_nd(int q);        // entries of writeback port q
        return (q < N_ALU) ? RC_DI : (q >= WB_BJU0) ? RC_DB : RC_DM;
    endfunction
    function automatic int rc_base(int q);      // first entry of writeback port q
        if (q < N_ALU)    return q * RC_DI;
        if (q >= WB_BJU0) return N_ALU * RC_DI + (q - WB_BJU0) * RC_DB;
        return N_RCI + (q - WB_LDU0) * RC_DM;
    endfunction
    function automatic int rc_slot(int e);      // position of entry e among its port's entries
        return e - rc_base(rc_port(e));
    endfunction
    logic [N_RC-1:0] rc_v;
    preg_t           rc_tag [N_RC];
    logic [63:0]     rc_dat [N_RC];
    logic [N_RC-1:0] rc_wr;                     // written at the end of this cycle
    localparam int RC_PW = $clog2((RC_DI > RC_DM) ? RC_DI : RC_DM);    // RC_DB <= both
    logic [RC_PW-1:0] rc_ptr [N_WB];            // next entry of each writing port
    logic [N_RC-1:0] rc_oh   [N_IQ][2][3];      // IS: entry hit by the operand
    logic [N_RC-1:0] rc_oh_q [N_IQ][2][3];      // RR
    function automatic logic rc_wb(int q);      // writeback port q fills the cache
        return REGCACHE && (q < N_ALU || (q >= WB_LDU0 && q < WB_FEX0) || (q >= WB_BJU0 && RC_DB > 0));
    endfunction
    function automatic logic rc_wb_now(int q, wb_t w);
        return rc_wb(q) && w.v && w.wen && w.pdest != '0 && w.pdest < preg_t'(INT_PRF_N);
    endfunction
    // replacement (RC_REPL, a read keeps an entry young): second chance
    // within the port's entries. A write or a hit sets the entry's reference bit; the victim is the first entry
    // from the pointer that is invalid or unreferenced, and the referenced entries passed over lose
    // their bit. 0: round-robin
    logic [N_RC-1:0] rc_ref;
    logic [N_RC-1:0] rc_hit;                    // hit by a selected uop's operand this cycle
    logic [N_RC-1:0] rc_skip;                   // passed over by this cycle's victim search
    logic [RC_PW-1:0] rc_vic [N_WB];            // victim of each writing port
    always_comb begin
        rc_skip = '0;
        for (int q = 0; q < N_WB; q++) begin
            rc_vic[q] = rc_ptr[q];
            if (rc_wb(q) && RC_REPL) begin
                int nd;
                logic found;
                nd = rc_nd(q);
                found = 1'b0;
                for (int k = 0; k < nd; k++) begin
                    int s;
                    s = (int'(rc_ptr[q]) + k) % nd;
                    if (!found) begin
                        if (!rc_v[rc_base(q) + s] || !rc_ref[rc_base(q) + s]) begin
                            rc_vic[q] = RC_PW'(s);
                            found = 1'b1;
                        end else rc_skip[rc_base(q) + s] = rc_wb_now(q, wbw[q]);
                    end
                end
                if (!found) rc_vic[q] = rc_ptr[q];      // all referenced: the pointer's entry
            end
        end
    end
    always_comb
        for (int e = 0; e < N_RC; e++) begin
            rc_wr[e]    = rc_wb_now(rc_port(e), wbw[rc_port(e)]) && int'(rc_vic[rc_port(e)]) == rc_slot(e);
            rc_rd_ok[e] = rc_v[e] && !rc_wr[e];
        end
    always_comb
        for (int k = 0; k < N_RCW; k++) begin
            rcw_v[k] = rc_wb_now(rc_wport(k), wbw[rc_wport(k)]);
            begin
                wb_t w;
                w = wbw[rc_wport(k)];
                if (WB_STAGE) w.v = wbq[rc_wport(k)].v;
                rcw_vi[k] = RC_TRK_NOKILL ? rc_wb_now(rc_wport(k), w) : rcw_v[k];
            end
            rcw_p[k] = wbw[rc_wport(k)].pdest;
            rcw_i[k] = RC_IW'(rc_base(rc_wport(k)) + int'(rc_vic[rc_wport(k)]));
        end
    // dispatch: sources found in the cache next cycle (kept entries, or written this cycle)
    always_comb
        for (int i = 0; i < DEC_W; i++)
            for (int s = 1; s <= 2; s++) begin
                preg_t p;
                p = (s == 1) ? dp_u[i].psrc1 : dp_u[i].psrc2;
                for (int e = 0; e < N_RC; e++)
                    rc_tag_hit[i][s][e] = REGCACHE && RC_TRACK &&
                                          (rc_rd_ok[e] && rc_tag[e] == p || rc_wr[e] && wbw[rc_port(e)].pdest == p);
                dp_rcu[i][s] = rc_tag_hit[i][s] != '0;
                dp_rci[i][s] = '0;
                for (int b = 0; b < RC_IW; b++) begin
                    logic [N_RC-1:0] col;
                    for (int e = 0; e < N_RC; e++) col[e] = ((e >> b) & 1) != 0;
                    dp_rci[i][s][b] = |(rc_tag_hit[i][s] & col);
                end
            end
    for (genvar e = 0; e < N_RC; e++) begin : g_rc
        always_ff @(posedge clk) begin
            logic al;
            al = 1'b0;
            for (int k = 0; k < DEC_W; k++) if (alloc_i[k] == rc_tag[e]) al = 1'b1;
            if (rc_wr[e]) begin
                rc_tag[e] <= wbw[rc_port(e)].pdest;
                rc_dat[e] <= wbw[rc_port(e)].val;
            end
            if (!rst_n || !REGCACHE || al) rc_v[e] <= 1'b0;
            else if (rc_wr[e])             rc_v[e] <= 1'b1;
            // a new entry starts referenced (a write makes the entry the youngest)
            if (!rst_n)                      rc_ref[e] <= 1'b0;
            else if (rc_wr[e] || rc_hit[e])  rc_ref[e] <= 1'b1;
            else if (rc_skip[e])             rc_ref[e] <= 1'b0;
        end
    end
    always_ff @(posedge clk)
        for (int q = 0; q < N_WB; q++)
            if (!rst_n) rc_ptr[q] <= '0;
            else if (rc_wb_now(q, wbw[q]))
                rc_ptr[q] <= (int'(rc_vic[q]) == rc_nd(q) - 1) ? '0 : rc_vic[q] + 1'b1;
    // RC_TRACK: the issue queues' register cache state of the selected uops' sources
    logic                  rc_use [N_IQ][2][3];     // IS: the operand is read from the cache
    logic [N_RC-1:0]       rc_sel [N_IQ][2][3];     // ... from this entry
    always_ff @(posedge clk) rc_oh_q <= rc_sel;

    always_comb begin
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++)
                for (int src = 1; src <= 2; src++) begin
                    logic v;
                    logic fr;
                    preg_t a;
                    v  = (d == 0) ? iq_sel_v[q] : iq_sel2_v[q];
                    a  = (d == 0) ? ((src == 1) ? iq_iss[q].psrc1 : iq_iss[q].psrc2)
                                  : ((src == 1) ? iq_iss2[q].psrc1 : iq_iss2[q].psrc2);
                    fr = (d == 0) ? iq_fr[q][src] : iq_fr2[q][src];
                    irp_a[q][d][src]  = a;
                    // RC_TRACK = 0: tag compare after the select. An entry written this cycle is read in
                    // RR with its new value
                    for (int e = 0; e < N_RC; e++)
                        rc_oh[q][d][src][e] = REGCACHE && irp_has(q, d, src) &&
                                              (rc_rd_ok[e] && rc_tag[e] == a || rc_wr[e] && wbw[rc_port(e)].pdest == a);
                    if (RC_TRACK) begin
                        rc_use[q][d][src] = REGCACHE && irp_has(q, d, src) && iq_rcu[q][d][src];
                        for (int e = 0; e < N_RC; e++)
                            rc_sel[q][d][src][e] = rc_use[q][d][src] && int'(iq_rci[q][d][src]) == e;
                    end else begin
                        rc_use[q][d][src] = rc_oh[q][d][src] != '0;
                        rc_sel[q][d][src] = rc_oh[q][d][src];
                    end
                    irp_rq[q][d][src] = IRP_ARB && irp_has(q, d, src) && v && a != '0 && a < preg_t'(INT_PRF_N) && !fr &&
                                        !rc_use[q][d][src];
                end
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++) begin
                rc_use[q][d][0] = 1'b0;
                rc_sel[q][d][0] = '0;
            end
        rc_hit = '0;
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++)
                for (int src = 1; src <= 2; src++)
                    if ((d == 0) ? iq_sel_v[q] : iq_sel2_v[q]) rc_hit = rc_hit | rc_sel[q][d][src];
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++)
                for (int src = 1; src <= 2; src++) begin
                    irp_lose[q][d][src] = 1'b0;
                    if (irp_has(q, d, src))
                        for (int q2 = 0; q2 < N_IQ; q2++)
                            for (int d2 = 0; d2 < 2; d2++)
                                for (int s2 = 1; s2 <= 2; s2++)
                                    if (irp_has(q2, d2, s2) && irp_slot(q2, d2, s2) / 4 == irp_slot(q, d, src) / 4 &&
                                        irp_slot(q2, d2, s2) % 4 < irp_slot(q, d, src) % 4 && irp_rq[q2][d2][s2])
                                        irp_lose[q][d][src] = 1'b1;
                end
        for (int q = 0; q < N_IQ; q++) begin
            iq_ok[q]  = !(irp_rq[q][0][1] && irp_lose[q][0][1]) && !(irp_rq[q][0][2] && irp_lose[q][0][2]);
            iq_ok2[q] = !(irp_rq[q][1][1] && irp_lose[q][1][1]) && !(irp_rq[q][1][2] && irp_lose[q][1][2]);
        end
        for (int m = 0; m < N_LDU; m++) if (rp_go[m]) iq_ok[IQ_LDU0 + m] = 1'b0;
        // address of each port: its winning request (AND-OR, one winner)
        for (int p = 0; p < N_IRP; p++) rp_addr_n[p] = '0;
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++)
                for (int src = 1; src <= 2; src++)
                    if (irp_has(q, d, src))
                        for (int p = 0; p < N_IRP; p++)
                            if (irp_slot(q, d, src) / 4 == p && irp_rq[q][d][src] && !irp_lose[q][d][src])
                                rp_addr_n[p] = rp_addr_n[p] | irp_a[q][d][src];
    end
    always_ff @(posedge clk) rp_addr <= rp_addr_n;
    // SPEC_WAKE: destinations of latency-1 uops that woke their consumers when selected but lost a read
    // port; cancelled in the issue queues and the busy table the next cycle
    always_ff @(posedge clk) begin
        for (int k = 0; k < N_CAN; k++) begin
            logic sv, ok;
            uop_t u;
            if (k < N_ALU + (BJU_PORT ? N_BJU : 0)) begin
                sv = (k < N_ALU) ? iq_sw_v[k] : iq_sw2_v[k - N_ALU];
                ok = (k < N_ALU) ? iq_ok[k]    : iq_ok2[k - N_ALU];
                u  = (k < N_ALU) ? iq_iss[k]   : iq_iss2[k - N_ALU];
                can_v[k] <= rst_n && SPEC_WAKE && sv && !ok && u.lat == 3'd1 && u.rf_wen;
                can_p[k] <= u.pdest;
            end else begin
                // LD_SPEC_WAKE: a load woken in AGU that will not complete in MEM
                can_v[k] <= rst_n && ld_can_n[k - N_ALU - (BJU_PORT ? N_BJU : 0)];
                can_p[k] <= ld_wk_p[k - N_ALU - (BJU_PORT ? N_BJU : 0)];
            end
        end
    end

    always_comb for (int p = 0; p < N_IRP; p++) rp_data[p] = prf_i[rp_addr[p]];
    // RR value of each register operand: the register cache entry it hit at IS (AND-OR), else its
    // read port
    logic [63:0] ir_val [N_IQ][2][3];
    logic [N_RC-1:0] rc_col [64];               // bit b of every entry (AND-OR as reduction ORs)
    always_comb
        for (int e = 0; e < N_RC; e++)
            for (int b = 0; b < 64; b++) rc_col[b][e] = rc_dat[e][b];
    always_comb
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++)
                for (int src = 0; src < 3; src++) begin
                    logic [63:0] r;
                    r = '0;
                    if (irp_has(q, d, src) && src != 0) begin
                        if (rc_oh_q[q][d][src] == '0) r = rp_data[irp_slot(q, d, src) / 4];
                        else for (int b = 0; b < 64; b++) r[b] = |(rc_oh_q[q][d][src] & rc_col[b]);
                    end
                    ir_val[q][d][src] = r;
                end
`ifndef SYNTHESIS
    // RC_TRACK: the issue queues' state of every selected register operand is exactly the tag compare's
    always_ff @(posedge clk)
        if (rst_n && REGCACHE && RC_TRACK)
            for (int q = 0; q < N_IQ; q++)
                for (int d = 0; d < 2; d++)
                    for (int src = 1; src <= 2; src++)
                        if (((d == 0) ? iq_sel_v[q] : iq_sel2_v[q]) && irp_has(q, d, src) && irp_a[q][d][src] != '0 &&
                            irp_a[q][d][src] < preg_t'(INT_PRF_N) && rc_sel[q][d][src] != rc_oh[q][d][src])
                            $error("RC_TRACK iq %0d port %0d src %0d preg %0d: tracked %h compare %h", q, d, src,
                                   irp_a[q][d][src], rc_sel[q][d][src], rc_oh[q][d][src]);
    // the register cache holds exactly the register file's value of every valid entry
    always_ff @(posedge clk)
        if (rst_n)
            for (int e = 0; e < N_RC; e++)
                if (rc_v[e] && rc_dat[e] != prf_i[rc_tag[e]])
                    $error("REGCACHE entry %0d: preg %0d %h vs register file %h", e, rc_tag[e], rc_dat[e], prf_i[rc_tag[e]]);
`endif
    // RR value of operand src of issue queue q's port d (x0: 0; an operand taken from the bypass
    // network gets its value in rr_operand)
    function automatic logic [63:0] irp_val(int q, int d, int src, preg_t a, logic [63:0] irv [N_IQ][2][3]);
        if (a == '0) return '0;
        return irv[q][d][src];
    endfunction

    // =====================================================================
    // Integer pipelines : IS -> RR -> EX1 (-> EX2 -> EX3 for MUL / I2F)
    //   ALU / BJU in EX1; MUL and I2F computed in EX1 and written at EX3; DIV started in EX1
    // =====================================================================
    logic        a_rr_v [N_ALU];  uop_t a_rr [N_ALU];
    logic        a_ex_v [N_ALU];  uop_t a_ex [N_ALU];
    logic [63:0] a_ex_s1 [N_ALU], a_ex_s2 [N_ALU];
    logic [63:0] a_ex_pc [N_ALU], a_ex_ptgt [N_ALU];     // read from the PC memory in RR

    logic [63:0] a_src1  [N_ALU];     // bypassed rs1 value in EX (CSR source operand)
    logic [63:0] a_res   [N_ALU];
    logic [63:0] a_res1  [N_ALU];     // a_res of the latency-1 classes
    logic        a_live  [N_ALU];
    logic        a_taken [N_ALU];
    logic [63:0] a_tgt   [N_ALU];
    logic        a_misp  [N_ALU];
    logic [63:0] a_next  [N_ALU];
    // branch resolution of BJU k (from the ALU pipe, or from the BJU pipe when BJU_PORT)
    logic        br_live  [N_BJU];
    logic        br_lraw  [N_BJU];   // br_live without the kill by redir_q (REDIR_KILL_LATE)
    uop_t        br_ex    [N_BJU];
    logic        br_taken [N_BJU], br_misp [N_BJU];
    logic [63:0] br_tgt   [N_BJU], br_next [N_BJU], br_pc [N_BJU];

    // branch outcome of a BJU uop with operand s1 (rs1) and compare result brt
    function automatic logic [63:0] br_target(uop_t u, logic [63:0] pc, logic [63:0] s1);
        return (u.alu_code == ALU_JALR) ? ((s1 + sximm(u.imm)) & ~64'd1) : (pc + sximm(u.imm));
    endfunction
    function automatic logic [63:0] fall_through(uop_t u, logic [63:0] pc);
        return pc + (u.rvc ? 64'd2 : 64'd4);
    endfunction

    for (genvar k = 0; k < N_ALU; k++) begin : g_alu
        logic [63:0] s1, s2, op1, op2, res, mres, ires, cres;
        logic [4:0]  iflags;
        logic brt;
        assign s1  = WB_STAGE ? a_ex_s1[k] : bypass(a_ex[k].psrc1, a_ex_s1[k], bp_v, bp_p, bp_val);
        assign a_src1[k] = s1;
        assign s2  = WB_STAGE ? a_ex_s2[k] : bypass(a_ex[k].psrc2, a_ex_s2[k], bp_v, bp_p, bp_val);
        assign op1 = a_ex[k].op1_pc  ? a_ex_pc[k] : s1;
        assign op2 = a_ex[k].op2_imm ? sximm(a_ex[k].imm) : s2;
        alu alu_i (.alu_code(a_ex[k].alu_code), .op1(op1), .op2(op2), .alu_result(res), .br_taken(brt));
        logic [63:0] mul_late;           // MUL_PIPE: the product in its write cycle (EX3)
        logic        mul_v2, mul_v3;
        if (iq_has(k, FU_MUL) && MUL_PIPE) begin : g_mulp
            mm_mul_pipe u_mul (.clk, .fn(a_ex[k].mdfn), .word(a_ex[k].word), .a(s1), .b(s2), .y(mul_late));
            always_ff @(posedge clk) begin
                mul_v2 <= rst_n && a_ex_v[k] && a_ex[k].fu == FU_MUL;
                mul_v3 <= rst_n && mul_v2;
            end
            assign mres = '0;
`ifndef SYNTHESIS
            logic [63:0] chk2, chk3;
            always_ff @(posedge clk) begin
                chk2 <= mul_result(a_ex[k].mdfn, a_ex[k].word, s1, s2);
                chk3 <= chk2;
                if (rst_n && mul_v3 && mul_late !== chk3)
                    $error("mm_mul_pipe mismatch: %h vs %h", mul_late, chk3);
            end
`endif
        end else if (iq_has(k, FU_MUL)) begin : g_mul
            assign mres = mul_result(a_ex[k].mdfn, a_ex[k].word, s1, s2);
            assign mul_late = '0; assign mul_v2 = 1'b0; assign mul_v3 = 1'b0;
        end else begin : g_nomul
            assign mres = '0;
            assign mul_late = '0; assign mul_v2 = 1'b0; assign mul_v3 = 1'b0;
        end
        logic [63:0] i2f_late;           // I2F_PIPE: the I2F result in its write cycle (EX3)
        logic [4:0]  i2f_late_f;
        if (iq_has(k, FU_I2F) && I2F_PIPE) begin : g_i2fp
            // I2F (piped): EX1 normalization, EX2 rounding, EX3 write (wbpipe late entry)
            logic [63:0] r2;
            logic [4:0]  f2;
            fp_i2f_pipe u_i2f (.clk, .fop(a_ex[k].fop), .fmt(a_ex[k].fmt), .rm(a_ex[k].rm), .ityp(a_ex[k].ityp),
                               .x(s1), .res(r2), .flags(f2));
            always_ff @(posedge clk) begin i2f_late <= r2; i2f_late_f <= f2; end
            assign ires = '0;
            assign iflags = '0;
        end else if (iq_has(k, FU_I2F)) begin : g_i2f
            fp_i2f u_i2f (.fop(a_ex[k].fop), .fmt(a_ex[k].fmt), .rm(a_ex[k].rm), .ityp(a_ex[k].ityp), .x(s1),
                          .res(ires), .flags(iflags));
            assign i2f_late = '0; assign i2f_late_f = '0;
        end else begin : g_noi2f
            assign ires = '0;
            assign iflags = '0;
            assign i2f_late = '0; assign i2f_late_f = '0;
        end
        if (k == 0) begin : g_csr
            assign cres = csr_old;
        end else begin : g_nocsr
            assign cres = '0;
        end
        // latency-1 result (ALU / CSR / link): the forward source of this pipe
        always_comb begin
            if (a_ex[k].fu == FU_CSR) a_res1[k] = cres;
            else a_res1[k] = (a_ex[k].rvc && (a_ex[k].alu_code == ALU_JAL || a_ex[k].alu_code == ALU_JALR))
                             ? a_ex_pc[k] + 64'd2 : res;
        end
        always_comb begin
            unique case (a_ex[k].fu)
                FU_MUL:  a_res[k] = mres;
                FU_I2F:  a_res[k] = ires;
                FU_CSR:  a_res[k] = cres;
                default: a_res[k] = (a_ex[k].rvc && (a_ex[k].alu_code == ALU_JAL || a_ex[k].alu_code == ALU_JALR))
                                    ? a_ex_pc[k] + 64'd2 : res;     // link of a compressed jump
            endcase
        end
        assign a_live[k] = a_ex_v[k] && !killed_by(redir_q, a_ex[k].rob_idx);
        if (k < N_BJU && !BJU_PORT) begin : g_bju
            assign a_taken[k] = brt;
            assign a_tgt[k]   = br_target(a_ex[k], a_ex_pc[k], s1);
            assign a_next[k]  = brt ? a_tgt[k] : fall_through(a_ex[k], a_ex_pc[k]);
            // mispredict = predicted taken ^ taken, or a wrong target
            // (a taken CFI always ends its fetch block, even if it jumps to the next instruction)
            assign a_misp[k]  = (a_ex[k].fu == FU_BJU) &&
                                (BR_MISP_TAKEN ? (brt != a_ex[k].pred_taken || (brt && a_tgt[k] != a_ex_ptgt[k]))
                                               : a_next[k] != (a_ex[k].pred_taken ? a_ex_ptgt[k] : fall_through(a_ex[k], a_ex_pc[k])));
            assign br_live[k] = a_live[k] && a_ex[k].fu == FU_BJU;
            assign br_lraw[k] = br_live[k];
            assign br_ex[k]   = a_ex[k];
            assign br_taken[k] = a_taken[k]; assign br_tgt[k] = a_tgt[k]; assign br_pc[k] = a_ex_pc[k];
            assign br_next[k]  = a_next[k];  assign br_misp[k] = a_misp[k];
        end else begin : g_nobju
            assign a_taken[k] = 1'b0;
            assign a_tgt[k]   = '0;
            assign a_next[k]  = '0;
            assign a_misp[k]  = 1'b0;
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                a_rr_v[k] <= 1'b0; a_ex_v[k] <= 1'b0;
            end else begin
                a_rr_v[k]  <= iq_iss_v[k];
                a_rr[k]    <= iq_iss[k];
                a_ex_v[k]  <= a_rr_v[k] && !killed_by(redir_q, a_rr[k].rob_idx);
                a_ex[k]    <= a_rr[k];
                a_ex_s1[k] <= WB_STAGE ? rr_operand(1, a_rr[k].psrc1, IRP_ARB ? irp_val(k, 0, 1, a_rr[k].psrc1, ir_val) : prf_i[a_rr[k].psrc1], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                       : prf_i[a_rr[k].psrc1];
                a_ex_s2[k] <= WB_STAGE ? rr_operand(1, a_rr[k].psrc2, IRP_ARB ? irp_val(k, 0, 2, a_rr[k].psrc2, ir_val) : prf_i[a_rr[k].psrc2], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                       : prf_i[a_rr[k].psrc2];
                a_ex_pc[k]   <= upc(pcm_start[a_rr[k].ftq_idx[FTQ_PW-2:0]], a_rr[k].off);
                a_ex_ptgt[k] <= pcm_target[a_rr[k].ftq_idx[FTQ_PW-2:0]];
            end
        end

        mm_wbpipe u_wb (
            .clk, .rst_n, .redir(redir_q),
            .iss_v(SPEC_WAKE ? iq_sw_v[k] : iq_iss_v[k]), .iss_l1(SPEC_WAKE ? iq_l1[k] : iq_iss_v[k] && iq_iss[k].lat == 3'd1 && iq_iss[k].rf_wen),
            .iss(iq_iss[k]),
            .rr_v(a_rr_v[k] && !killed_by(redir_q, a_rr[k].rob_idx)), .rr(a_rr[k]),
            .ex_v(a_live[k]), .ex(a_ex[k]), .ex_val(a_res[k]), .ex_val1(a_res1[k]), .ex_flags((a_ex[k].fu == FU_I2F) ? iflags : 5'd0),
            .ex_late((I2F_PIPE && iq_has(k, FU_I2F) && a_ex[k].fu == FU_I2F) || (MUL_PIPE && iq_has(k, FU_MUL) && a_ex[k].fu == FU_MUL)),
            .late_val(mul_v3 ? mul_late : i2f_late), .late_flags(mul_v3 ? 5'd0 : i2f_late_f),
            .port(wbp[k]), .wk_v(wk_valid[k]), .wk_p(wk_preg[k])
        );

        // dedicated BJU pipeline : IS -> RR -> EX (branch resolve, link register write)
        if (k < N_BJU && BJU_PORT) begin : g_bjp
            logic        j_rr_v, j_ex_v;
            uop_t        j_rr, j_ex;
            logic [63:0] j_s1q, j_s2q, j_s1, j_s2, j_res, j_pc, j_ptgt;
            logic        j_brt;
            assign j_s1 = WB_STAGE ? j_s1q : bypass(j_ex.psrc1, j_s1q, bp_v, bp_p, bp_val);
            assign j_s2 = WB_STAGE ? j_s2q : bypass(j_ex.psrc2, j_s2q, bp_v, bp_p, bp_val);
            alu alu_j (.alu_code(j_ex.alu_code), .op1(j_ex.op1_pc ? j_pc : j_s1), .op2(j_ex.op2_imm ? sximm(j_ex.imm) : j_s2),
                       .alu_result(), .br_taken(j_brt));
            assign j_res       = fall_through(j_ex, j_pc);              // link value (JAL / JALR)
            assign br_live[k]  = j_ex_v && !killed_by(redir_q, j_ex.rob_idx);
            assign br_lraw[k]  = j_ex_v;
            assign br_ex[k]    = j_ex;
            assign br_taken[k] = j_brt;
            assign br_tgt[k]   = br_target(j_ex, j_pc, j_s1);
            assign br_next[k]  = j_brt ? br_tgt[k] : fall_through(j_ex, j_pc);
            assign br_pc[k]    = j_pc;
            assign br_misp[k]  = BR_MISP_TAKEN ? (j_brt != j_ex.pred_taken || (j_brt && br_tgt[k] != j_ptgt))
                                               : br_next[k] != (j_ex.pred_taken ? j_ptgt : fall_through(j_ex, j_pc));
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    j_rr_v <= 1'b0; j_ex_v <= 1'b0;
                end else begin
                    j_rr_v <= iq_iss2_v[k];
                    j_rr   <= iq_iss2[k];
                    j_ex_v <= j_rr_v && !killed_by(redir_q, j_rr.rob_idx);
                    j_ex   <= j_rr;
                    j_s1q  <= WB_STAGE ? rr_operand(1, j_rr.psrc1, IRP_ARB ? irp_val(k, 1, 1, j_rr.psrc1, ir_val) : prf_i[j_rr.psrc1], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                       : prf_i[j_rr.psrc1];
                    j_s2q  <= WB_STAGE ? rr_operand(1, j_rr.psrc2, IRP_ARB ? irp_val(k, 1, 2, j_rr.psrc2, ir_val) : prf_i[j_rr.psrc2], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                       : prf_i[j_rr.psrc2];
                    j_pc   <= upc(pcm_start[j_rr.ftq_idx[FTQ_PW-2:0]], j_rr.off);
                    j_ptgt <= pcm_target[j_rr.ftq_idx[FTQ_PW-2:0]];
                end
            end
            mm_wbpipe u_wbj (
                .clk, .rst_n, .redir(redir_q),
                .iss_v(SPEC_WAKE ? iq_sw2_v[k] : iq_iss2_v[k]),
                .iss_l1(SPEC_WAKE ? iq_l12[k] : iq_iss2_v[k] && iq_iss2[k].lat == 3'd1 && iq_iss2[k].rf_wen), .iss(iq_iss2[k]),
                .rr_v(j_rr_v && !killed_by(redir_q, j_rr.rob_idx)), .rr(j_rr),
                .ex_v(br_live[k]), .ex(j_ex), .ex_val(j_res), .ex_val1(j_res), .ex_flags(5'd0),
                .ex_late(1'b0), .late_val('0), .late_flags('0),
                .port(wbp[WB_BJU0 + k]), .wk_v(wk_valid[WB_BJU0 + k]), .wk_p(wk_preg[WB_BJU0 + k])
            );
        end

        // iterative divider (own writeback port)
        if (k == DIV_IQ) begin : g_div
            logic        dv_start, dv_kill, dv_busy, dv_done, dv_post, dv_acc2;
            logic [63:0] dv_y;
            wb_t         dv_tag, dv_ftag, dv_otag;          // operation in the iteration engine / in the result stage / written
            logic [1:0]  dv_isd;                            // a DIV issued one / two cycles ago
            rob_ptr_t    pend_rob;
            assign dv_start = a_live[k] && a_ex[k].fu == FU_DIV;
            assign dv_kill  = dv_busy && killed_by(redir_q, dv_tag.rob);
            if (DIV_SRT) begin : g_srt
                mm_div_srt #(.U(DIV_U), .PRE1(DIV_PRE1), .POST1(DIV_POST1), .OVL(DIV_OVL)) u_div (
                    .clk, .rst_n, .start(dv_start), .kill(dv_kill), .fn(a_ex[k].mdfn), .word(a_ex[k].word),
                    .a(s1), .b(s2), .busy(dv_busy), .post(dv_post), .acc2(dv_acc2), .done(dv_done), .y(dv_y)
                );
            end else begin : g_rst
                mm_div #(.U(DIV_U)) u_div (
                    .clk, .rst_n, .start(dv_start), .kill(dv_kill), .fn(a_ex[k].mdfn), .word(a_ex[k].word),
                    .a(s1), .b(s2), .busy(dv_busy), .done(dv_done), .y(dv_y)
                );
                assign dv_post = 1'b0;
                assign dv_acc2 = 1'b0;
            end
            assign div_blk = !dv_acc2 || dv_isd != '0;
            assign dv_otag = DIV_SRT ? dv_ftag : dv_tag;
            always_ff @(posedge clk) begin
                if (dv_start) begin
                    dv_tag.wen   <= a_ex[k].rf_wen;
                    dv_tag.pdest <= a_ex[k].pdest;
                    dv_tag.rob   <= a_ex[k].rob_idx;
                end
                if (dv_post) dv_ftag <= dv_tag;
                if (!rst_n) dv_isd <= '0;
                else        dv_isd <= {dv_isd[0], iq_iss_v[k] && iq_iss[k].fu == FU_DIV};
                if (!rst_n) div_pend <= 1'b0;
                else if (iq_iss_v[k] && iq_iss[k].fu == FU_DIV) begin
                    div_pend <= 1'b1;
                    pend_rob <= iq_iss[k].rob_idx;
                end else if (dv_done || killed_by(redir_q, pend_rob)) div_pend <= 1'b0;
            end
            always_comb begin
                wbp[WB_DIV]       = dv_otag;
                wbp[WB_DIV].v     = dv_done && !killed_by(redir_q, dv_otag.rob);
                wbp[WB_DIV].val   = dv_y;
                wbp[WB_DIV].fflags = '0;
                wk_valid[WB_DIV]  = wbp[WB_DIV].v && dv_otag.wen;
                wk_preg[WB_DIV]   = dv_otag.pdest;
            end
        end
    end

    // =====================================================================
    // FP pipelines : IS -> RR -> EX1 .. EX4 (FALU 2, FMA 3, FCVT 4 cycles); FDIV started in EX1
    // =====================================================================
    logic        f_rr_v [N_FEX];  uop_t f_rr [N_FEX];
    logic        f_ex_v [N_FEX];  uop_t f_ex [N_FEX];
    logic [63:0] f_ex_s1 [N_FEX], f_ex_s2 [N_FEX], f_ex_s3 [N_FEX];
    logic        f_live [N_FEX];
    logic [63:0] f_res  [N_FEX];

    for (genvar f = 0; f < N_FEX; f++) begin : g_fex
        localparam int Q = IQ_FEX0 + f;
        logic [63:0] s1, s2, s3, r_fma, r_misc;
        logic [4:0]  fl_fma, fl_misc;
        assign s1 = WB_STAGE ? f_ex_s1[f] : bypass(f_ex[f].psrc1, f_ex_s1[f], bp_v, bp_p, bp_val);
        assign s2 = WB_STAGE ? f_ex_s2[f] : bypass(f_ex[f].psrc2, f_ex_s2[f], bp_v, bp_p, bp_val);
        assign s3 = WB_STAGE ? f_ex_s3[f] : bypass(f_ex[f].psrc3, f_ex_s3[f], bp_v, bp_p, bp_val);
        // FMA pipeline: FADD/FSUB valid in EX2, FMUL/FMADD/... in EX3; the write
        // pipe takes the value in the write cycle (ex_late)
        logic fma_cls;
        logic [63:0] r_fma1;
        logic [4:0]  fl_fma1;
        assign fma_cls = f_ex[f].fop <= FOP_NMADD;
        if (FMA_PIPE) begin : g_fmap
            fp_fma_unit_pipe u_fma (
                .clk, .fma_start(f_ex_v[f] && fma_cls && f_ex[f].fop != FOP_ADD && f_ex[f].fop != FOP_SUB),
                .add_mode(f_ex_v[f] && (f_ex[f].fop == FOP_ADD || f_ex[f].fop == FOP_SUB)),
                .fop(f_ex[f].fop), .fmt(f_ex[f].fmt), .rm(f_ex[f].rm), .a(s1), .b(s2), .c(s3), .res(r_fma), .flags(fl_fma));
            assign r_fma1 = '0; assign fl_fma1 = '0;
        end else begin : g_fmac
            fp_fma_unit u_fma (.fop(f_ex[f].fop), .fmt(f_ex[f].fmt), .rm(f_ex[f].rm), .a(s1), .b(s2), .c(s3),
                               .res(r_fma1), .flags(fl_fma1));
            assign r_fma = '0; assign fl_fma = '0;
        end
        fp_misc #(.HAS_CVT(!FCVT_PIPE && iq_has(Q, FU_FCVT))) u_misc (
            .fop(f_ex[f].fop), .fmt(f_ex[f].fmt), .rm(f_ex[f].rm), .ityp(f_ex[f].ityp), .a(s1), .b(s2), .res(r_misc),
            .flags(fl_misc)
        );
        // FCVT pipeline: EX1 registers the operands, EX2 computes, the result waits
        // for the write in EX4 (wbpipe late entry)
        logic        cvt_cls;
        logic        c2_v, c3_v, c4_v;
        logic [63:0] c4_r;
        logic [4:0]  c4_f;
        assign cvt_cls = FCVT_PIPE && iq_has(Q, FU_FCVT) && f_ex[f].fu == FU_FCVT;
        if (FCVT_PIPE && iq_has(Q, FU_FCVT)) begin : g_cvtp
            fop_t        c2_fop;
            logic        c2_fmt;
            logic [2:0]  c2_rm;
            logic [1:0]  c2_ityp;
            logic [63:0] c2_a, c2_b, c2_r, c3_r;
            logic [4:0]  c2_f, c3_f;
            fp_mu_t      c1_u, c2_u;
            // EX1: unpack (fp_misc_unpack), EX2: compare / classify / convert (fp_misc_core)
            // (FCVT_PIPE2: the conversions span EX2 and EX3, fp_cvt_pipe)
            fp_misc_unpack u_cvt_unp (.a(s1), .b(s2), .u(c1_u));
            logic [63:0] c3_rc;
            logic [4:0]  c3_fc;
            if (FCVT_PIPE2) begin : g_cvt2
                fp_cvt_pipe u_cvt (
                    .clk, .fop(c2_fop), .fmt(c2_fmt), .rm(c2_rm), .ityp(c2_ityp), .a(c2_a), .b(c2_b), .u(c2_u),
                    .u1(c1_u), .fmt1(f_ex[f].fmt), .res(c3_rc), .flags(c3_fc)
                );
                assign c2_r = '0; assign c2_f = '0;
            end else begin : g_cvt1
                fp_misc_core #(.HAS_CVT(1'b1)) u_cvt (
                    .fop(c2_fop), .fmt(c2_fmt), .rm(c2_rm), .ityp(c2_ityp), .a(c2_a), .b(c2_b), .u(c2_u),
                    .res(c2_r), .flags(c2_f)
                );
                assign c3_rc = c3_r; assign c3_fc = c3_f;
            end
            always_ff @(posedge clk) begin
                c2_v <= f_ex_v[f] && cvt_cls;
                c2_fop <= f_ex[f].fop; c2_fmt <= f_ex[f].fmt; c2_rm <= f_ex[f].rm; c2_ityp <= f_ex[f].ityp;
                c2_a <= s1; c2_b <= s2; c2_u <= c1_u;
                c3_v <= c2_v; c3_r <= c2_r; c3_f <= c2_f;
                c4_v <= c3_v; c4_r <= c3_rc; c4_f <= c3_fc;
            end
            if (f == 0) begin : g_cvtr
                assign fex0_cvt_r = c4_r;
            end
        end else begin : g_nocvtp
            assign c4_v = 1'b0; assign c4_r = '0; assign c4_f = '0;
            if (f == 0) begin : g_cvtr0
                assign fex0_cvt_r = '0;
            end
        end
        assign f_res[f]  = (!FMA_PIPE && fma_cls) ? r_fma1 : r_misc;
        assign f_live[f] = f_ex_v[f] && !killed_by(redir_q, f_ex[f].rob_idx);

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                f_rr_v[f] <= 1'b0; f_ex_v[f] <= 1'b0;
            end else begin
                f_rr_v[f]  <= iq_iss_v[Q];
                f_rr[f]    <= iq_iss[Q];
                f_ex_v[f]  <= f_rr_v[f] && !killed_by(redir_q, f_rr[f].rob_idx);
                f_ex[f]    <= f_rr[f];
                f_ex_s1[f] <= WB_STAGE ? rr_operand(2, f_rr[f].psrc1, prf_f[f_rr[f].psrc1 - preg_t'(INT_PRF_N)],
                                                    fd_v, fd_p, fd_val, bp_v, bp_p, bp_val)
                                       : prf_f[f_rr[f].psrc1 - preg_t'(INT_PRF_N)];
                f_ex_s2[f] <= WB_STAGE ? rr_operand(2, f_rr[f].psrc2, prf_f[f_rr[f].psrc2 - preg_t'(INT_PRF_N)],
                                                    fd_v, fd_p, fd_val, bp_v, bp_p, bp_val)
                                       : prf_f[f_rr[f].psrc2 - preg_t'(INT_PRF_N)];
                f_ex_s3[f] <= WB_STAGE ? rr_operand(2, f_rr[f].psrc3, prf_f[f_rr[f].psrc3 - preg_t'(INT_PRF_N)],
                                                    fd_v, fd_p, fd_val, bp_v, bp_p, bp_val)
                                       : prf_f[f_rr[f].psrc3 - preg_t'(INT_PRF_N)];
            end
        end

        mm_wbpipe #(.L1(!WBP_FEX_NOL1)) u_wb (
            .clk, .rst_n, .redir(redir_q),
            .iss_v(iq_iss_v[Q]), .iss_l1(iq_iss_v[Q] && iq_iss[Q].lat == 3'd1 && iq_iss[Q].rf_wen), .iss(iq_iss[Q]),
            .rr_v(f_rr_v[f] && !killed_by(redir_q, f_rr[f].rob_idx)), .rr(f_rr[f]),
            .ex_v(f_live[f]), .ex(f_ex[f]), .ex_val(f_res[f]), .ex_val1(f_res[f]), .ex_flags((!FMA_PIPE && fma_cls) ? fl_fma1 : fl_misc),
            .ex_late((FMA_PIPE && fma_cls) || cvt_cls), .late_val(c4_v ? c4_r : r_fma), .late_flags(c4_v ? c4_f : fl_fma),
            .port(wbp[WB_FEX0 + f]), .wk_v(wk_valid[WB_FEX0 + f]), .wk_p(wk_preg[WB_FEX0 + f])
        );

        if (iq_has(Q, FU_FDIV)) begin : g_fdiv
            localparam int J = f - 1;
            logic        fd_start, fd_kill, fd_busy, fd_done, fd_post, fd_acc2;
            logic [63:0] fd_y;
            logic [4:0]  fd_fl;
            wb_t         fd_tag, fd_ftag, fd_otag;          // operation in the engine / in FIN / written
            logic [1:0]  fd_isd;                            // an FDIV issued one / two cycles ago
            rob_ptr_t    pend_rob;
            assign fd_start = f_live[f] && f_ex[f].fu == FU_FDIV;
            assign fd_kill  = fd_busy && killed_by(redir_q, fd_tag.rob);
            fp_divsqrt #(.U(FDIV_U), .OVL(FDIV_OVL)) u_fdiv (
                .clk, .rst_n, .start(fd_start), .kill(fd_kill), .is_sqrt(f_ex[f].fop == FOP_SQRT),
                .fmt(f_ex[f].fmt), .rm(f_ex[f].rm), .a(s1), .b(s2), .busy(fd_busy), .post(fd_post), .acc2(fd_acc2),
                .done(fd_done), .res(fd_y), .flags(fd_fl)
            );
            assign fdiv_blk[J] = !fd_acc2 || fd_isd != '0;
            assign fd_otag = (FDIV_SRT && FDIV_OVL) ? fd_ftag : fd_tag;
            always_ff @(posedge clk) begin
                if (fd_start) begin
                    fd_tag.wen   <= f_ex[f].rf_wen;
                    fd_tag.pdest <= f_ex[f].pdest;
                    fd_tag.rob   <= f_ex[f].rob_idx;
                end
                if (fd_post) fd_ftag <= fd_tag;
                if (!rst_n) fd_isd <= '0;
                else        fd_isd <= {fd_isd[0], iq_iss_v[Q] && iq_iss[Q].fu == FU_FDIV};
                if (!rst_n) fdiv_pend[J] <= 1'b0;
                else if (iq_iss_v[Q] && iq_iss[Q].fu == FU_FDIV) begin
                    fdiv_pend[J] <= 1'b1;
                    pend_rob     <= iq_iss[Q].rob_idx;
                end else if (fd_done || killed_by(redir_q, pend_rob)) fdiv_pend[J] <= 1'b0;
            end
            always_comb begin
                wbp[WB_FDIV0 + J]       = fd_otag;
                wbp[WB_FDIV0 + J].v     = fd_done && !killed_by(redir_q, fd_otag.rob);
                wbp[WB_FDIV0 + J].val   = fd_y;
                wbp[WB_FDIV0 + J].fflags = fd_fl;
                wk_valid[WB_FDIV0 + J]  = wbp[WB_FDIV0 + J].v && fd_otag.wen;
                wk_preg[WB_FDIV0 + J]   = fd_otag.pdest;
            end
        end
    end

    // =====================================================================
    // Load pipelines : IS -> RR -> AGU -> MEM
    // =====================================================================
    logic        l_rr_v [N_LDU];  uop_t l_rr [N_LDU];
    logic        l_ag_v [N_LDU];  uop_t l_ag [N_LDU];  logic [63:0] l_ag_base [N_LDU];
    logic        l_m_v  [N_LDU];  uop_t l_m  [N_LDU];  logic [63:0] l_m_addr  [N_LDU];
    logic        l_live [N_LDU];
    logic [7:0]  l_mask [N_LDU];
    logic [63:0] l_data [N_LDU];

    logic        l_mmio [N_LDU];
    // store pipeline stages (see the store pipelines below)
    logic        s_rr_v [N_STU]; uop_t s_rr [N_STU];
    logic        s_ag_v [N_STU]; uop_t s_ag [N_STU];
    logic [63:0] s_ag_base [N_STU], s_ag_data [N_STU];
    logic [63:0] s_addr [N_STU], s_data [N_STU];
    logic [7:0]  s_mask [N_STU];
    logic        s_live [N_STU];
    // LD_REPLAY
    logic            l_m_pff [N_LDU];     // predicted in AGU: an older matching store has no data (registered)
    logic            l_m_prw [N_LDU];     // RAWQ: needs a RAW entry and may find none: replayed
    logic            l_m_rwn [N_LDU];     // RAWQ: an older store had no address at AGU: takes a RAW entry
    logic            l_m_rp  [N_LDU];     // replayed (either cause)
    logic            l_m_kd  [N_LDU];     //   waits for the stores' addresses rather than their data
    logic [SQ_N-1:0] sq_av_vec;           // SQ entries with their address
    sq_ptr_t         raw_ardy;            // RAWQ: first SQ entry from the head without an address (registered)
    int              raw_free_q;          // RAWQ: free RAW entries (registered)
    logic [SQ_N-1:0] l_m_pm  [N_LDU];     //   those stores
    logic            l_rr_rp [N_LDU];     // RR holds a replayed load: the address comes from the replay queue
    logic [63:0]     l_rr_ra [N_LDU];
    logic            l_rep   [N_LDU];     // MEM: the load goes into the replay queue
    logic            lrq_full [N_LDU];
    uop_t            lrq_ru  [N_LDU];     // the replay entering RR next cycle
    logic [63:0]     lrq_ra  [N_LDU];
    logic [SQ_N-1:0] sq_dv_vec;
    always_comb for (int i = 0; i < SQ_N; i++) sq_dv_vec[i] = sq_dv[i];

    function automatic logic [63:0] ld_format(logic [63:0] dw, logic [2:0] off, logic [2:0] t, logic fp32);
        logic [63:0] sh;
        sh = dw >> {off, 3'b000};
        if (fp32) return {32'hffffffff, sh[31:0]};          // FLW: NaN-boxed
        unique case (t)
            LOAD_LB:  return {{56{sh[7]}},  sh[7:0]};
            LOAD_LH:  return {{48{sh[15]}}, sh[15:0]};
            LOAD_LW:  return {{32{sh[31]}}, sh[31:0]};
            LOAD_LBU: return {56'd0, sh[7:0]};
            LOAD_LHU: return {48'd0, sh[15:0]};
            LOAD_LWU: return {32'd0, sh[31:0]};
            default:  return sh;
        endcase
    endfunction

    function automatic logic [7:0] size_mask(logic [2:0] t);
        unique case (t)
            LOAD_LB, LOAD_LBU: return 8'h01;
            LOAD_LH, LOAD_LHU: return 8'h03;
            LOAD_LW, LOAD_LWU: return 8'h0f;
            default:           return 8'hff;
        endcase
    endfunction

    logic l_ffail [N_LDU];               // STD_SPLIT: forward from a store without data (replay the load)
    logic [SQ_N-1:0] l_ffoh [N_LDU];     //   FWD_ONEHOT: that store as a one-hot SQ vector
    // highest set bit as a one-hot vector: x & ~(OR of the higher bits), the suffix OR in log2(SQ_N) levels
    function automatic logic [SQ_N-1:0] hi1_sq(logic [SQ_N-1:0] x);
        logic [SQ_N-1:0] p;
        p = x >> 1;
        for (int k = 1; k < SQ_N; k = k * 2) p = p | (p >> k);
        return x & ~p;
    endfunction
    int   l_ffsq  [N_LDU];               //   that store's SQ entry
    redirect_t lf_s [N_LDU], lf_q [N_LDU];
    ftq_ptr_t          lf_sftq [N_LDU], lf_sftq_q [N_LDU];   // LF_STPC_LATE: the store's FTQ entry / slot
    logic [SLOT_W-1:0] lf_soff [N_LDU], lf_soff_q [N_LDU];
    always_comb
        for (int m = 0; m < N_LDU; m++) begin
            lf_s[m] = '0;
            if (FWD_ONEHOT) begin
                // (per bit as a reduction OR over the entries: an accumulating loop is built as a chain)
                for (int t = 0; t < FTQ_PW; t++) begin
                    logic [SQ_N-1:0] col;
                    for (int i = 0; i < SQ_N; i++) col[i] = sq_ftq[i][t];
                    lf_sftq[m][t] = |(l_ffoh[m] & col);
                end
                for (int t = 0; t < SLOT_W; t++) begin
                    logic [SQ_N-1:0] col;
                    for (int i = 0; i < SQ_N; i++) col[i] = sq_off[i][t];
                    lf_soff[m][t] = |(l_ffoh[m] & col);
                end
            end else begin
                lf_sftq[m] = sq_ftq[l_ffsq[m]];
                lf_soff[m] = sq_off[l_ffsq[m]];
            end
            // (LD_REPLAY: only a fail not predicted in AGU, or one the replay queue has no room for)
            if (STD_SPLIT && l_live[m] && !l_mmio[m] && (l_m_rp[m] ? lrq_full[m] : l_ffail[m])) begin
                lf_s[m].valid      = 1'b1;
                lf_s[m].rob_idx    = l_m[m].rob_idx;
                lf_s[m].flush_self = 1'b1;
                lf_s[m].target     = REDIR_PC_LATE ? '0 : upc(pcm_start[l_m[m].ftq_idx[FTQ_PW-2:0]], l_m[m].off);
                lf_s[m].off        = l_m[m].off;
                lf_s[m].ftq_idx    = l_m[m].ftq_idx;
                lf_s[m].lq_ptr     = l_m[m].lq_ptr;
                lf_s[m].sq_ptr     = l_m[m].sq_ptr;
                lf_s[m].mdp_train  = l_ffail[m] && !l_m_prw[m];   // StoreSet: the load waits for this store from now on
                lf_s[m].st_pc      = LF_STPC_LATE ? '0 : upc(pcm_start[lf_sftq[m][FTQ_PW-2:0]], lf_soff[m]);
            end
        end
    // registered before the redirect selection (as VIOL_REG)
    always_ff @(posedge clk)
        for (int m = 0; m < N_LDU; m++) begin
            lf_q[m] <= lf_s[m];
            lf_sftq_q[m] <= lf_sftq[m]; lf_soff_q[m] <= lf_soff[m];
            // (lf_s is only valid for a live load, already not killed by this redirect: FWD_FAIL_ANY drops
            // the repeated check from the end of the path)
            if (!rst_n || (!FWD_FAIL_ANY && killed_by(redir_q, lf_s[m].rob_idx))) lf_q[m].valid <= 1'b0;
        end
    for (genvar m = 0; m < N_LDU; m++) begin : g_ldu
        logic [63:0] base, agu_addr;
        assign base     = WB_STAGE ? l_ag_base[m] : bypass(l_ag[m].psrc1, l_ag_base[m], bp_v, bp_p, bp_val);
        assign agu_addr = base + sximm(l_ag[m].imm);
        assign l_live[m] = l_m_v[m] && !killed_by(redir_q, l_m[m].rob_idx);
        assign l_mask[m] = size_mask(l_m[m].ld_type) << l_m_addr[m][2:0];
        assign l_mmio[m] = is_mmio(l_m_addr[m]);
        assign dm_raddr[m] = l_m_addr[m];
        assign dm_raddr_n[m] = agu_addr;

        // LD_REPLAY: older stores (by the then-SQ) matching the address without data, registered for MEM
        logic [SQ_N-1:0] pm_n;
        // RAWQ: an older store without an address (by the registered ready pointer: one cycle late, so
        // conservative), and those stores (what a RAW-full replay waits for)
        logic            rwn_n;
        logic [SQ_N-1:0] pmr_n;
        always_comb begin
            logic same;
            int hidx, lidx;
            rwn_n = RAWQ && sq_dist(sq_head, raw_ardy) < sq_dist(sq_head, l_ag[m].sq_ptr);
            hidx  = int'(sq_head[SQ_PW-2:0]);
            lidx  = int'(l_ag[m].sq_ptr[SQ_PW-2:0]);
            same  = sq_head[SQ_PW-1] == l_ag[m].sq_ptr[SQ_PW-1];
            for (int i = 0; i < SQ_N; i++)
                pmr_n[i] = RAWQ && (same ? (i >= hidx && i < lidx) : (i >= hidx || i < lidx)) && !sq_addrv[i];
        end
        always_comb begin
            logic [7:0] am;
            logic same;
            int hidx, lidx;
            am   = size_mask(l_ag[m].ld_type) << agu_addr[2:0];
            hidx = int'(sq_head[SQ_PW-2:0]);
            lidx = int'(l_ag[m].sq_ptr[SQ_PW-2:0]);
            same = sq_head[SQ_PW-1] == l_ag[m].sq_ptr[SQ_PW-1];
            for (int i = 0; i < SQ_N; i++)
                pm_n[i] = LD_REPLAY && (same ? (i >= hidx && i < lidx) : (i >= hidx || i < lidx)) &&
                          sq_addrv[i] && !sq_dv[i] && sq_addr[i][63:3] == agu_addr[63:3] && (sq_mask[i] & am) != 8'h00;
            // the stores in AGU this cycle write the SQ at its end, seen by this load in MEM: compared here
            // with their AGU address (as VIOL_CAM_AGU does the other way)
            for (int u = 0; u < N_STU; u++) begin
                int si;
                si = int'(s_ag[u].sq_ptr[SQ_PW-2:0]);
                if (LD_REPLAY && s_live[u] && (same ? (si >= hidx && si < lidx) : (si >= hidx || si < lidx)) &&
                    !sq_dv[si] && s_addr[u][63:3] == agu_addr[63:3] && (s_mask[u] & am) != 8'h00)
                    pm_n[si] = 1'b1;
            end
        end

        // store-to-load forwarding from older stores + memory read (older stores = [sq_head, load's
        // sq_ptr) from the pointer flags, youngest match per byte by a priority encoder)
        always_comb begin
            logic [63:0] merged;
            logic [SQ_N-1:0] older, below, match;
            logic same;
            int hidx, lidx;
            l_ffail[m] = 1'b0;
            l_ffsq[m]  = 0;
            l_ffoh[m]  = '0;
            hidx = int'(sq_head[SQ_PW-2:0]);
            lidx = int'(l_m[m].sq_ptr[SQ_PW-2:0]);
            same = sq_head[SQ_PW-1] == l_m[m].sq_ptr[SQ_PW-1];
            for (int i = 0; i < SQ_N; i++) begin
                below[i] = i < lidx;
                older[i] = same ? (i >= hidx && i < lidx) : (i >= hidx || i < lidx);
                match[i] = older[i] && sq_addrv[i] && sq_addr[i][63:3] == l_m_addr[m][63:3];
            end
            merged = dm_rdata[m];
            // SBUFFER: committed stores still in the buffer (older than every store in the SQ)
            if (SBUFFER) begin
                logic [SB_N-1:0] sh;
                for (int e = 0; e < SB_N; e++) sh[e] = sb_v[e] && sb_tag[e] == l_m_addr[m][63:4];
                // (a line being written out and a newer entry for the same line: the newer one on top)
                for (int pass = 0; pass < 2; pass++)
                    for (int b = 0; b < 8; b++) begin
                        logic [SB_N-1:0] mb;
                        logic [7:0] by;
                        by = '0;
                        for (int e = 0; e < SB_N; e++) begin
                            mb[e] = sh[e] && (sb_infl[e] == (pass == 0)) && sb_mask[e][8 * l_m_addr[m][3] + b];
                            by = by | ({8{mb[e]}} & sb_data[e][64 * l_m_addr[m][3] + 8 * b +: 8]);
                        end
                        if (mb != '0) merged[8*b +: 8] = by;
                    end
            end
            for (int b = 0; b < 8; b++) if (FWD_ONEHOT) begin
                // the youngest matching store of byte b as a one-hot vector (the highest one below the
                // load's pointer, else the highest of the wrapped part); data and the fail by AND-OR
                logic [SQ_N-1:0] cand, cb, oh;
                logic [7:0] by;
                for (int i = 0; i < SQ_N; i++) cand[i] = match[i] && sq_mask[i][b] && l_mask[m][b];
                cb = cand & below;
                oh = (cb != '0) ? hi1_sq(cb) : hi1_sq(cand);
                for (int t = 0; t < 8; t++) begin
                    logic [SQ_N-1:0] col;
                    for (int i = 0; i < SQ_N; i++) col[i] = sq_data[i][8*b + t];
                    by[t] = |(oh & col);
                end
                if (cand != '0) merged[8*b +: 8] = by;
                if (STD_SPLIT && !FWD_FAIL_ANY && (oh & ~sq_dv_vec) != '0) begin
                    l_ffail[m] = 1'b1;
                    l_ffoh[m]  = oh;
                end
            end else begin
                logic [SQ_N-1:0] cand;
                int sel;
                for (int i = 0; i < SQ_N; i++) cand[i] = match[i] && sq_mask[i][b] && l_mask[m][b];
                // youngest: highest index below the load's pointer, else highest of the wrapped part
                sel = 0;
                for (int i = 0; i < SQ_N; i++) if (cand[i]) sel = i;
                for (int i = 0; i < SQ_N; i++) if (cand[i] && below[i]) sel = i;
                if (cand != '0) merged[8*b +: 8] = sq_data[sel][8*b +: 8];
                // STD_SPLIT: the youngest matching store has no data yet (forward fail)
                if (STD_SPLIT && cand != '0 && !sq_dv[sel]) begin
                    l_ffail[m] = 1'b1;
                    l_ffsq[m]  = sel;
                end
            end
            // FWD_FAIL_ANY: the fail from any older matching store without data (a reduction OR); the
            // youngest of them only names the store for StoreSet training
            if (STD_SPLIT && FWD_ONEHOT && FWD_FAIL_ANY) begin
                logic [SQ_N-1:0] fv, fb;
                for (int i = 0; i < SQ_N; i++) fv[i] = match[i] && (sq_mask[i] & l_mask[m]) != 8'h00 && !sq_dv[i];
                fb = fv & below;
                l_ffail[m] = fv != '0;
                l_ffoh[m]  = (fb != '0) ? hi1_sq(fb) : hi1_sq(fv);
            end
            l_data[m] = ld_format(merged, l_m_addr[m][2:0], l_m[m].ld_type, l_m[m].ld_fp32);
        end

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                l_rr_v[m] <= 1'b0; l_ag_v[m] <= 1'b0; l_m_v[m] <= 1'b0; l_m_pff[m] <= 1'b0; l_rr_rp[m] <= 1'b0;
                l_m_prw[m] <= 1'b0; l_m_rwn[m] <= 1'b0;
            end else begin
                l_rr_v[m]    <= iq_iss_v[IQ_LDU0 + m] || (rp_go[m] && !killed_by(redir_q, lrq_ru[m].rob_idx));
                l_rr[m]      <= rp_go[m] ? lrq_ru[m] : iq_iss[IQ_LDU0 + m];
                l_rr_rp[m]   <= rp_go[m];
                l_rr_ra[m]   <= lrq_ra[m];
                l_ag_v[m]    <= l_rr_v[m] && !killed_by(redir_q, l_rr[m].rob_idx);
                l_ag[m]      <= l_rr[m];
                l_ag_base[m] <= l_rr_rp[m] ? l_rr_ra[m] : WB_STAGE ? rr_operand(1, l_rr[m].psrc1, IRP_ARB ? irp_val(IQ_LDU0 + m, 0, 1, l_rr[m].psrc1, ir_val) : prf_i[l_rr[m].psrc1], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                         : prf_i[l_rr[m].psrc1];
                l_m_v[m]     <= l_ag_v[m] && !killed_by(redir_q, l_ag[m].rob_idx);
                l_m[m]       <= l_ag[m];
                l_m_addr[m]  <= agu_addr;
                l_m_pm[m]    <= (pm_n != '0) ? pm_n : pmr_n;
                l_m_pff[m]   <= pm_n != '0;
                l_m_prw[m]   <= pm_n == '0 && rwn_n && raw_free_q < 2 * N_LDU;
                l_m_rwn[m]   <= rwn_n;
                l_m_kd[m]    <= pm_n == '0;
            end
        end
        assign l_m_rp[m] = l_m_pff[m] || l_m_prw[m];
        assign l_rep[m] = LD_REPLAY && l_live[m] && !l_mmio[m] && l_m_rp[m] && !lrq_full[m];
        // LD_SPEC_WAKE: wakeup in AGU; cancelled next cycle when MEM will not complete the load: a predicted
        // fail or a full RAW queue (the replay queue), or MMIO (a forward fail found in MEM flushes the
        // consumers with the load)
        assign ld_wk_v[m]  = LD_SPEC_WAKE && l_ag_v[m] && !killed_by(redir_q, l_ag[m].rob_idx) && l_ag[m].rf_wen;
        assign ld_wk_p[m]  = l_ag[m].pdest;
        assign ld_can_n[m] = ld_wk_v[m] && (pm_n != '0 || (rwn_n && raw_free_q < 2 * N_LDU) || is_mmio(agu_addr));

        // writeback + wakeup at MEM (MMIO loads go to the uncached load unit instead)
        always_comb begin
            // (a forward fail does not complete: the load is replayed. Its wakeup is not held back, so the
            // SQ search stays off the wakeup path; the consumers are younger and are flushed with it)
            // (LD_REPLAY: a predicted fail neither completes nor wakes up; it is replayed)
            wbp[WB_LDU0 + m].v     = l_live[m] && !l_mmio[m] && !l_ffail[m] && !l_m_rp[m];
            wbp[WB_LDU0 + m].wen   = l_m[m].rf_wen;
            wbp[WB_LDU0 + m].pdest = l_m[m].pdest;
            wbp[WB_LDU0 + m].rob   = l_m[m].rob_idx;
            wbp[WB_LDU0 + m].val   = l_data[m];
            wbp[WB_LDU0 + m].fflags = '0;
            wk_valid[WB_LDU0 + m]  = LD_SPEC_WAKE ? ld_wk_v[m] : l_live[m] && !l_mmio[m] && l_m[m].rf_wen && !l_m_rp[m];
            wk_preg[WB_LDU0 + m]   = LD_SPEC_WAKE ? ld_wk_p[m] : l_m[m].pdest;
        end
    end

    // =====================================================================
    // Load replay queue (LD_REPLAY, for forward fails): LRQ_N entries per load pipe with the
    // uop, the address and the stores it waits for. A store's bit is dropped once its data is in (a store
    // only leaves the SQ after that, so a reused SQ entry is never waited for); the entry is ready when no
    // bit is left (registered). The first ready entry enters RR the next cycle with its
    // address (imm 0), and the LDU issue queue does not issue that cycle (as a lost read port)
    // =====================================================================
    for (genvar m = 0; m < N_LDU; m++) begin : g_lrq
        logic [LRQ_N-1:0] v, rdy, go;
        uop_t             u  [LRQ_N];
        logic [63:0]      a  [LRQ_N];
        logic [SQ_N-1:0]  pm [LRQ_N];
        logic [LRQ_N-1:0] kd;               // waits for the stores' data or addresses
        logic [LRQ_N-1:0] fr;               // first free entry (one-hot)
        always_comb begin
            logic seen;
            seen = 1'b0;
            for (int e = 0; e < LRQ_N; e++) begin
                go[e] = v[e] && rdy[e] && !seen;
                seen  = seen || (v[e] && rdy[e]);
            end
            seen = 1'b0;
            for (int e = 0; e < LRQ_N; e++) begin
                fr[e] = !v[e] && !seen;
                seen  = seen || !v[e];
            end
            rp_go[m]    = LD_REPLAY && go != '0;
            lrq_full[m] = !seen;
            lrq_ru[m]   = '0;
            lrq_ra[m]   = '0;
            for (int e = 0; e < LRQ_N; e++)
                if (go[e]) begin
                    lrq_ru[m] = lrq_ru[m] | u[e];
                    lrq_ra[m] = lrq_ra[m] | a[e];
                end
            lrq_ru[m].imm   = '0;
            lrq_ru[m].psrc1 = '0;
        end
        for (genvar e = 0; e < LRQ_N; e++) begin : g_e
            always_ff @(posedge clk) begin
                if (!rst_n || !LD_REPLAY) begin
                    v[e] <= 1'b0; rdy[e] <= 1'b0;
                end else if (l_rep[m] && fr[e]) begin
                    v[e]   <= 1'b1;
                    u[e]   <= l_m[m];
                    a[e]   <= l_m_addr[m];
                    kd[e]  <= l_m_kd[m] && l_m_prw[m];
                    pm[e]  <= l_m_pm[m] & ~((l_m_kd[m] && l_m_prw[m]) ? sq_av_vec : sq_dv_vec);
                    rdy[e] <= (l_m_pm[m] & ~((l_m_kd[m] && l_m_prw[m]) ? sq_av_vec : sq_dv_vec)) == '0;
                end else begin
                    if (go[e] || killed_by(redir_q, u[e].rob_idx)) v[e] <= 1'b0;
                    pm[e]  <= pm[e] & ~(kd[e] ? sq_av_vec : sq_dv_vec);
                    rdy[e] <= (pm[e] & ~(kd[e] ? sq_av_vec : sq_dv_vec)) == '0;
                end
            end
        end
    end

    // =====================================================================
    // RAW queue (RAWQ): loads that executed while an older store had no address,
    // with the address the store check compares. An entry is freed once the address-ready pointer has
    // passed the load's SQ position (every older store has its address) or on a flush. Up to N_LDU loads
    // enter per cycle (lowest free entries); the AGU stage only lets a load in when at least 2 x N_LDU were
    // free at its start (registered), so the entries it needs in MEM are there
    // =====================================================================
    logic [RAW_N-1:0] rw_v, rw_vn;
    logic [63:3]      rw_a  [RAW_N];
    logic [7:0]       rw_m  [RAW_N];
    lq_ptr_t          rw_lq [RAW_N];
    logic [LQ_N-1:0]  rw_lqoh [RAW_N];     // RAW_LQOH: the load's LQ entry as a one-hot vector
    sq_ptr_t          rw_sq [RAW_N];
    rob_ptr_t         rw_rb [RAW_N];
    logic [RAW_N-1:0] rw_al [N_LDU];      // entry taken by load pipe m this cycle (one-hot)
    logic [N_LDU-1:0] rw_in;              // load pipe m enters the RAW queue this cycle
    always_comb for (int i = 0; i < SQ_N; i++) sq_av_vec[i] = sq_addrv[i];
    // address-ready pointer: first entry in [sq_head, sq_tail) without an address,
    // else sq_tail; registered (a stale value only keeps more loads tracked, and longer)
    if (RAWQ) begin : g_raw
        always_ff @(posedge clk) begin
            logic [SQ_N-1:0] inv, up, hi, lo, g;
            logic same, gh;
            int hidx, tidx, sel;
            hidx = int'(sq_head[SQ_PW-2:0]);
            tidx = int'(sq_tail[SQ_PW-2:0]);
            same = sq_head[SQ_PW-1] == sq_tail[SQ_PW-1];
            for (int i = 0; i < SQ_N; i++) begin
                up[i]  = i >= hidx;
                inv[i] = (same ? (i >= hidx && i < tidx) : (i >= hidx || i < tidx)) && !sq_addrv[i];
            end
            hi = inv & up;
            lo = inv & ~up;
            // lowest set bit of the upper part, else of the wrapped part (prefix OR in log2 levels)
            begin
                logic [SQ_N-1:0] x, p;
                x = (hi != '0) ? hi : lo;
                p = x << 1;
                for (int k = 1; k < SQ_N; k = k * 2) p = p | (p << k);
                g = x & ~p;
            end
            sel = 0;
            for (int i = 0; i < SQ_N; i++) if (g[i]) sel = sel | i;
            gh = hi != '0;
            if (!rst_n)          raw_ardy <= '0;
            else if (inv == '0)  raw_ardy <= sq_tail;
            else                 raw_ardy <= {gh ? sq_head[SQ_PW-1] : ~sq_head[SQ_PW-1], (SQ_PW-1)'(sel)};
        end
        always_comb begin
            logic [RAW_N-1:0] taken;
            taken = '0;
            for (int m = 0; m < N_LDU; m++) begin
                logic seen;
                rw_in[m] = l_live[m] && !l_mmio[m] && !l_m_rp[m] && l_m_rwn[m];
                seen = 1'b0;
                for (int r = 0; r < RAW_N; r++) begin
                    rw_al[m][r] = rw_in[m] && !rw_v[r] && !taken[r] && !seen;
                    seen = seen || (!rw_v[r] && !taken[r]);
                end
                taken = taken | rw_al[m];
            end
        end
        for (genvar r = 0; r < RAW_N; r++) begin : g_e
            always_ff @(posedge clk) begin
                for (int m = 0; m < N_LDU; m++)
                    if (rw_al[m][r]) begin
                        rw_a[r]  <= l_m_addr[m][63:3];
                        rw_m[r]  <= l_mask[m];
                        rw_lq[r] <= l_m[m].lq_ptr;
                        rw_lqoh[r] <= LQ_N'(1) << l_m[m].lq_ptr[LQ_PW-2:0];
                        rw_sq[r] <= l_m[m].sq_ptr;
                        rw_rb[r] <= l_m[m].rob_idx;
                    end
                rw_v[r] <= rst_n && rw_vn[r];
            end
            always_comb begin
                logic al;
                al = 1'b0;
                for (int m = 0; m < N_LDU; m++) al = al | rw_al[m][r];
                rw_vn[r] = al || (rw_v[r] && !(killed_by(redir_q, rw_rb[r]) ||
                                               !(sq_dist(sq_head, raw_ardy) < sq_dist(sq_head, rw_sq[r]))));
            end
        end
        // free entries after this cycle's updates: a load in AGU now finds at least that many at the start
        // of its MEM cycle less the other pipes' entries this cycle, so 2 x N_LDU covers both cycles
        always_ff @(posedge clk) begin
            int n;
            n = 0;
            for (int r = 0; r < RAW_N; r++) n += int'(!rw_vn[r]);
            raw_free_q <= rst_n ? n : RAW_N;
        end
`ifndef SYNTHESIS
        always_ff @(posedge clk)
            for (int m = 0; m < N_LDU; m++)
                if (rst_n && rw_in[m] && rw_al[m] == '0) $error("RAWQ: no free entry for load pipe %0d", m);
`endif
    end else begin : g_noraw
        assign raw_ardy = '0;
        assign raw_free_q = RAW_N;
        assign rw_v = '0;
        always_comb for (int m = 0; m < N_LDU; m++) begin rw_in[m] = 1'b0; rw_al[m] = '0; end
    end

    // =====================================================================
    // Uncached (MMIO) loads: an MMIO load leaves the load pipeline
    // into a one-entry buffer and is performed when it is the oldest instruction and every
    // committed store has been written out, so device registers are read exactly once, in order.
    // A second MMIO load arriving while the buffer is busy is replayed (flushed and refetched).
    // =====================================================================
    logic        unc_v;
    uop_t        unc_u;
    logic [63:0] unc_addr;
    logic        unc_go;
    redirect_t   unc_replay;
    logic [N_LDU-1:0] unc_take;
    always_comb begin
        logic taken;
        taken = unc_v;
        unc_replay = '0;
        for (int m = 0; m < N_LDU; m++) begin
            unc_take[m] = 1'b0;
            if (l_live[m] && l_mmio[m]) begin
                if (!taken) begin
                    unc_take[m] = 1'b1; taken = 1'b1;
                end else if (!unc_replay.valid || rob_older(l_m[m].rob_idx, unc_replay.rob_idx)) begin
                    unc_replay.valid      = 1'b1;
                    unc_replay.rob_idx    = l_m[m].rob_idx;
                    unc_replay.flush_self = 1'b1;
                    unc_replay.target     = REDIR_PC_LATE ? '0 : upc(pcm_start[l_m[m].ftq_idx[FTQ_PW-2:0]], l_m[m].off);
                    unc_replay.off        = l_m[m].off;
                    unc_replay.ftq_idx    = l_m[m].ftq_idx;
                    unc_replay.lq_ptr     = l_m[m].lq_ptr;
                    unc_replay.sq_ptr     = l_m[m].sq_ptr;
                end
            end
        end
        unc_go   = unc_v && !killed_by(redir_q, unc_u.rob_idx) && unc_u.rob_idx == rob_head && sq_head == sq_cmt && sb_empty &&
                    !(SBUFFER && MMIO_WREG && mmio_wq);
        io_re    = unc_go;
        io_raddr = unc_addr;
        wbp[WB_UNC].v      = unc_go;
        wbp[WB_UNC].wen    = unc_u.rf_wen;
        wbp[WB_UNC].pdest  = unc_u.pdest;
        wbp[WB_UNC].rob    = unc_u.rob_idx;
        wbp[WB_UNC].val    = ld_format(io_rdata, unc_addr[2:0], unc_u.ld_type, unc_u.ld_fp32);
        wbp[WB_UNC].fflags = '0;
        wk_valid[WB_UNC]   = unc_go && unc_u.rf_wen;
        wk_preg[WB_UNC]    = unc_u.pdest;
    end
    always_ff @(posedge clk) begin
        if (!rst_n) unc_v <= 1'b0;
        else begin
            if (unc_go || (unc_v && killed_by(redir_q, unc_u.rob_idx))) unc_v <= 1'b0;
            for (int m = 0; m < N_LDU; m++)
                if (unc_take[m]) begin
                    unc_v    <= 1'b1;
                    unc_u    <= l_m[m];
                    unc_addr <= l_m_addr[m];
                end
        end
    end

    // =====================================================================
    // Store pipelines : IS -> RR -> AGU (write SQ) -> SC (memory-order violation check, ROB done)
    //   ST_CHECK_STAGE = 0: the check and ROB done in AGU
    // =====================================================================
    // (s_* are declared with the load pipelines, whose AGU looks at the stores in AGU)
    redirect_t   viol_s [N_STU];
    // VIOL_REG (the selected rollback is registered and checked against the redirect again before it
    // is sent): the violation redirect reaches the redirect selection one cycle later
    redirect_t   viol_q [N_STU];
    logic [LQ_N-1:0] lq_kv;             // VIOL_KILL_OH: LQ entries killed by the redirect being applied
    always_comb for (int i = 0; i < LQ_N; i++) lq_kv[i] = killed_by(redir_q, lq_rob[i]);
    // with VIOL_REG the store completes in the ROB in the same cycle as its violation redirect is selected,
    // so a violating load (younger) cannot commit before it is flushed
    logic        sd_v   [N_STU];
    rob_ptr_t    sd_rob [N_STU];
    logic        sd_live [N_STU];
    always_ff @(posedge clk)
        for (int u = 0; u < N_STU; u++) begin
            sd_v[u]   <= rst_n && c_live[u];
            sd_rob[u] <= c_u[u].rob_idx;
        end
    always_comb for (int u = 0; u < N_STU; u++) sd_live[u] = sd_v[u] && !killed_by(redir_q, sd_rob[u]);
    always_ff @(posedge clk)
        for (int u = 0; u < N_STU; u++) begin
            viol_q[u] <= viol_s[u];
            if (!rst_n || !(VIOL_KILL_OH && VIOL_LQMASK && ST_CHECK_STAGE) && killed_by(redir_q, viol_s[u].rob_idx))
                viol_q[u].valid <= 1'b0;
        end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        for (int u = 0; u < N_STU; u++)
            if (rst_n && viol_s[u].valid && killed_by(redir_q, viol_s[u].rob_idx))
                $error("VIOL_KILL_OH: violation of a killed load (rob %0d)", viol_s[u].rob_idx);
`endif
    // store seen by the violation check (SC stage, or AGU without ST_CHECK_STAGE)
    logic        c_v    [N_STU]; uop_t c_u [N_STU];
    logic [63:0] c_addr [N_STU];
    logic [7:0]  c_mask [N_STU];
    logic        c_live [N_STU];
    logic [LQ_N-1:0] c_cam [N_STU];     // VIOL_CAM_AGU: address hits against the LQ, made in the AGU stage

    for (genvar u = 0; u < N_STU; u++) begin : g_stu
        logic [63:0] s_rf_data;     // store data from the int or the FP register file
        assign s_rf_data = (s_rr[u].psrc2 >= preg_t'(INT_PRF_N)) ? prf_f[s_rr[u].psrc2 - preg_t'(INT_PRF_N)]
                                                                 : IRP_ARB ? irp_val(IQ_STU0 + u, 0, 2, s_rr[u].psrc2, ir_val)
                                                                           : prf_i[s_rr[u].psrc2];
        assign s_live[u] = s_ag_v[u] && !killed_by(redir_q, s_ag[u].rob_idx);
        assign s_addr[u] = (WB_STAGE ? s_ag_base[u] : bypass(s_ag[u].psrc1, s_ag_base[u], bp_v, bp_p, bp_val)) +
                           sximm(s_ag[u].imm);
        assign s_data[u] = (WB_STAGE ? s_ag_data[u] : bypass(s_ag[u].psrc2, s_ag_data[u], bp_v, bp_p, bp_val)) <<
                           {s_addr[u][2:0], 3'b000};
        always_comb begin
            unique case (s_ag[u].st_type)
                STORE_SB: s_mask[u] = 8'h01 << s_addr[u][2:0];
                STORE_SH: s_mask[u] = 8'h03 << s_addr[u][2:0];
                STORE_SW: s_mask[u] = 8'h0f << s_addr[u][2:0];
                default:  s_mask[u] = 8'hff;
            endcase
        end

        if (ST_CHECK_STAGE) begin : g_sc
            logic        sc_v;
            uop_t        sc_u;
            logic [63:0] sc_addr;
            logic [7:0]  sc_mask;
            always_ff @(posedge clk) begin
                if (!rst_n) sc_v <= 1'b0;
                else        sc_v <= s_live[u];
                sc_u <= s_ag[u]; sc_addr <= s_addr[u]; sc_mask <= s_mask[u];
            end
            assign c_v[u] = sc_v; assign c_u[u] = sc_u; assign c_addr[u] = sc_addr; assign c_mask[u] = sc_mask;
            // VIOL_CAM_AGU: the address / byte-mask compare against the executed LQ entries is made in the
            // AGU stage and registered; the loads in MEM during the AGU cycle (marked executed at its end) are
            // compared with their MEM-stage address. In SC the hits are ANDed with the then-executed entries (an
            // entry reallocated meanwhile is not executed) and the store's younger range
            logic [LQ_N-1:0] cam_a;
            // RAWQ: the compare is against the RAW entries (and the loads entering them now), registered per
            // entry; in SC the hits of entries still held are put at their loads' LQ positions
            logic [RAW_N-1:0] rcam_a, rcam_q;
            always_comb begin
                for (int i = 0; i < LQ_N; i++)
                    cam_a[i] = lq_exec[i] && lq_addr[i][63:3] == s_addr[u][63:3] && (lq_mask[i] & s_mask[u]) != 8'h00;
                for (int m = 0; m < N_LDU; m++)
                    if (l_live[m] && !l_mmio[m] && l_m_addr[m][63:3] == s_addr[u][63:3] && (l_mask[m] & s_mask[u]) != 8'h00)
                        cam_a[l_m[m].lq_ptr[LQ_PW-2:0]] = 1'b1;
                for (int r = 0; r < RAW_N; r++) begin
                    logic hm;
                    hm = 1'b0;
                    for (int m = 0; m < N_LDU; m++)
                        hm = hm | (rw_al[m][r] && l_m_addr[m][63:3] == s_addr[u][63:3] && (l_mask[m] & s_mask[u]) != 8'h00);
                    rcam_a[r] = RAWQ && (rw_v[r] && rw_a[r] == s_addr[u][63:3] && (rw_m[r] & s_mask[u]) != 8'h00 || hm);
                end
            end
            always_ff @(posedge clk) rcam_q <= rcam_a;
            if (RAWQ) begin : g_rsc
                always_comb
                    for (int i = 0; i < LQ_N; i++) begin
                        logic [RAW_N-1:0] h;
                        for (int r = 0; r < RAW_N; r++)
                            h[r] = rcam_q[r] && rw_v[r] && (RAW_LQOH ? rw_lqoh[r][i] : int'(rw_lq[r][LQ_PW-2:0]) == i);
                        c_cam[u][i] = |h;
                    end
            end else begin : g_lsc
                always_ff @(posedge clk) c_cam[u] <= cam_a;
            end
        end else begin : g_nosc
            assign c_v[u] = s_ag_v[u]; assign c_u[u] = s_ag[u]; assign c_addr[u] = s_addr[u]; assign c_mask[u] = s_mask[u];
            assign c_cam[u] = '0;
        end
        assign c_live[u] = c_v[u] && !killed_by(redir_q, c_u[u].rob_idx);

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                s_rr_v[u] <= 1'b0; s_ag_v[u] <= 1'b0;
            end else begin
                s_rr_v[u]    <= iq_iss_v[IQ_STU0 + u];
                s_rr[u]      <= iq_iss[IQ_STU0 + u];
                s_ag_v[u]    <= s_rr_v[u] && !killed_by(redir_q, s_rr[u].rob_idx);
                s_ag[u]      <= s_rr[u];
                s_ag_base[u] <= WB_STAGE ? rr_operand(1, s_rr[u].psrc1, IRP_ARB ? irp_val(IQ_STU0 + u, 0, 1, s_rr[u].psrc1, ir_val) : prf_i[s_rr[u].psrc1], fd_v, fd_p, fd_ival, bp_v, bp_p, bp_val)
                                         : prf_i[s_rr[u].psrc1];
                s_ag_data[u] <= WB_STAGE ? rr_operand(3, s_rr[u].psrc2, s_rf_data, fd_v, fd_p, fd_val, bp_v, bp_p, bp_val)
                                         : s_rf_data;
            end
        end

        // lowest set bit as a one-hot vector: x & ~(OR of the lower bits), the prefix OR in log2(LQ_N) levels
        function automatic logic [LQ_N-1:0] first1_lq(logic [LQ_N-1:0] x);
            logic [LQ_N-1:0] p;
            p = x << 1;                                  // p[i]: OR of x[0..i-1] after the levels below
            for (int k = 1; k < LQ_N; k = k * 2) p = p | (p << k);
            return x & ~p;
        endfunction
        // memory-order violation: a younger load to an overlapping address already executed
        // (oldest violating load: the first hit from lq_head, by a priority encoder)
        always_comb begin
            logic [LQ_N-1:0] hit;
            logic same;
            int hidx, tidx, sel;
            viol_s[u] = '0;
            hidx = int'(lq_head[LQ_PW-2:0]);
            tidx = int'(lq_tail[LQ_PW-2:0]);
            same = lq_head[LQ_PW-1] == lq_tail[LQ_PW-1];
            // (the redirect being applied is checked on the selected load only: it is the oldest hit, so
            // if it is killed, every younger hit is too)
            if (VIOL_LQMASK) begin
                // the loads younger than the store are the LQ entries from the store's
                // lq_ptr (the LQ tail when it was renamed) to the tail, a mask from the pointers instead of
                // per-entry ROB-order compares; the oldest hit is taken as a one-hot vector (the hits at or
                // above the store's index first, then the wrapped part) and its fields by AND-OR
                logic [LQ_N-1:0] up, h_hi, h_lo, g;
                logic sm;
                int sidx;
                rob_ptr_t   g_rob;
                logic [SLOT_W-1:0] g_off;
                ftq_ptr_t   g_ftq;
                sq_ptr_t    g_sq;
                logic       g_hi;
                sidx = int'(c_u[u].lq_ptr[LQ_PW-2:0]);
                sm   = c_u[u].lq_ptr[LQ_PW-1] == lq_tail[LQ_PW-1];
                for (int i = 0; i < LQ_N; i++) begin
                    up[i]  = i >= sidx;
                    hit[i] = (sm ? (i >= sidx && i < tidx) : (i >= sidx || i < tidx)) && (RAWQ || lq_exec[i]) &&
                             ((VIOL_CAM_AGU && ST_CHECK_STAGE) ? c_cam[u][i] :
                              (lq_addr[i][63:3] == c_addr[u][63:3] && (lq_mask[i] & c_mask[u]) != 8'h00));
                end
                h_hi = hit & up;
                h_lo = hit & ~up;
                g    = (h_hi != '0) ? first1_lq(h_hi) : first1_lq(h_lo);
                g_rob = '0; g_off = '0; g_ftq = '0; g_sq = '0; sel = 0; g_hi = 1'b0;
                for (int i = 0; i < LQ_N; i++) if (g[i]) begin
                    g_rob = g_rob | lq_rob[i]; g_off = g_off | lq_off[i]; g_ftq = g_ftq | lq_ftq[i];
                    g_sq = g_sq | lq_sqptr[i]; sel = sel | i; g_hi = g_hi | (i >= hidx);
                end
                if (c_live[u] && hit != '0 && !(VIOL_KILL_OH ? |(g & lq_kv) : killed_by(redir_q, g_rob))) begin
                    viol_s[u].valid      = 1'b1;
                    viol_s[u].rob_idx    = g_rob;
                    viol_s[u].flush_self = 1'b1;
                    viol_s[u].target     = REDIR_PC_LATE ? '0 : upc(pcm_start[g_ftq[FTQ_PW-2:0]], g_off);
                    viol_s[u].off        = g_off;
                    viol_s[u].ftq_idx    = g_ftq;
                    viol_s[u].lq_ptr     = {g_hi ? lq_head[LQ_PW-1] : ~lq_head[LQ_PW-1], (LQ_PW-1)'(sel)};
                    viol_s[u].sq_ptr     = g_sq;
                    viol_s[u].mdp_train  = 1'b1;
                    viol_s[u].st_pc      = upc(pcm_start[c_u[u].ftq_idx[FTQ_PW-2:0]], c_u[u].off);
                end
            end else begin
            for (int i = 0; i < LQ_N; i++)
                hit[i] = (same ? (i >= hidx && i < tidx) : (i >= hidx || i < tidx)) && lq_exec[i] &&
                         rob_older(c_u[u].rob_idx, lq_rob[i]) &&
                         (VIOL_KILL_LATE || !killed_by(redir_q, lq_rob[i])) &&
                         lq_addr[i][63:3] == c_addr[u][63:3] && (lq_mask[i] & c_mask[u]) != 8'h00;
            sel = 0;
            for (int i = LQ_N - 1; i >= 0; i--) if (hit[i]) sel = i;
            for (int i = LQ_N - 1; i >= 0; i--) if (hit[i] && i >= hidx) sel = i;
            if (c_live[u] && hit != '0 && !(VIOL_KILL_LATE && killed_by(redir_q, lq_rob[sel]))) begin
                viol_s[u].valid      = 1'b1;
                viol_s[u].rob_idx    = lq_rob[sel];
                viol_s[u].flush_self = 1'b1;
                viol_s[u].target     = REDIR_PC_LATE ? '0 : upc(pcm_start[lq_ftq[sel][FTQ_PW-2:0]], lq_off[sel]);
                viol_s[u].off        = lq_off[sel];
                viol_s[u].ftq_idx    = lq_ftq[sel];
                viol_s[u].lq_ptr     = {(sel >= hidx) ? lq_head[LQ_PW-1] : ~lq_head[LQ_PW-1], (LQ_PW-1)'(sel)};
                viol_s[u].sq_ptr     = lq_sqptr[sel];
                viol_s[u].mdp_train  = 1'b1;
                viol_s[u].st_pc      = upc(pcm_start[c_u[u].ftq_idx[FTQ_PW-2:0]], c_u[u].off);
            end
            end
            // loads in the MEM stage this very cycle did not see this store (with the SC stage, they
            // were in MEM during AGU and are in the LQ now; loads in MEM now see the store in the SQ)
            if (!ST_CHECK_STAGE && s_live[u]) begin
                for (int m = 0; m < N_LDU; m++) begin
                    if (l_live[m] && !l_mmio[m] && rob_older(s_ag[u].rob_idx, l_m[m].rob_idx) &&
                        l_m_addr[m][63:3] == s_addr[u][63:3] && (l_mask[m] & s_mask[u]) != 8'h00 &&
                        (!viol_s[u].valid || rob_older(l_m[m].rob_idx, viol_s[u].rob_idx))) begin
                        viol_s[u].valid      = 1'b1;
                        viol_s[u].rob_idx    = l_m[m].rob_idx;
                        viol_s[u].flush_self = 1'b1;
                        viol_s[u].target     = REDIR_PC_LATE ? '0 : upc(pcm_start[l_m[m].ftq_idx[FTQ_PW-2:0]], l_m[m].off);
                        viol_s[u].off        = l_m[m].off;
                        viol_s[u].ftq_idx    = l_m[m].ftq_idx;
                        viol_s[u].lq_ptr     = l_m[m].lq_ptr;
                        viol_s[u].sq_ptr     = l_m[m].sq_ptr;
                        viol_s[u].mdp_train  = 1'b1;
                        viol_s[u].st_pc      = upc(pcm_start[s_ag[u].ftq_idx[FTQ_PW-2:0]], s_ag[u].off);
                    end
                end
            end
        end
    end

    // =====================================================================
    // Bypass registers: results written in the previous cycle
    // =====================================================================
    // (WB_STAGE: the WB stage registers, which write the register file and the ROB)
    for (genvar q = 0; q < N_WB; q++) begin : g_bp
        always_ff @(posedge clk) begin
            if (!rst_n) wbq[q].v <= 1'b0;
            else        wbq[q].v <= wbp[q].v;
            wbq[q].wen    <= wbp[q].wen;
            wbq[q].pdest  <= wbp[q].pdest;
            wbq[q].rob    <= wbp[q].rob;
            wbq[q].val    <= wbp[q].val;
            wbq[q].fflags <= wbp[q].fflags;
        end
        assign bp_v[q]   = wbq[q].v && wbq[q].wen;
        assign bp_p[q]   = wbq[q].pdest;
        assign bp_val[q] = wbq[q].val;
        always_comb begin
            wbw[q] = wbp[q];
            if (WB_STAGE) begin
                wbw[q]   = wbq[q];
                wbw[q].v = wbq[q].v && !killed_by(redir_q, wbq[q].rob);
            end
        end
    end

    // branch results recorded in the ROB / FTQ (WB_STAGE: in the WB stage)
    logic     brw_live  [N_BJU];
    logic     brw_taken [N_BJU];
    rob_ptr_t brw_rob   [N_BJU];
    ftq_ptr_t brw_ftq   [N_BJU];
    logic [63:0] brw_tgt [N_BJU];
    for (genvar k = 0; k < N_BJU; k++) begin : g_brw
        if (WB_STAGE) begin : g_q
            logic     q_live, q_taken;
            rob_ptr_t q_rob;
            ftq_ptr_t q_ftq;
            logic [63:0] q_tgt;
            always_ff @(posedge clk) begin
                if (!rst_n) q_live <= 1'b0;
                else        q_live <= br_live[k];
                q_taken <= br_taken[k]; q_rob <= br_ex[k].rob_idx; q_ftq <= br_ex[k].ftq_idx; q_tgt <= br_tgt[k];
            end
            assign brw_live[k] = q_live && !killed_by(redir_q, q_rob);
            assign brw_taken[k] = q_taken; assign brw_rob[k] = q_rob; assign brw_ftq[k] = q_ftq; assign brw_tgt[k] = q_tgt;
        end else begin : g_c
            assign brw_live[k] = br_live[k];
            assign brw_taken[k] = br_taken[k]; assign brw_rob[k] = br_ex[k].rob_idx; assign brw_ftq[k] = br_ex[k].ftq_idx;
            assign brw_tgt[k] = br_tgt[k];
        end
    end

    // =====================================================================
    // Redirect selection (oldest of: BJU mispredicts, memory-order violation)
    // =====================================================================
    redirect_t redir_sel;
    // REDIR_PAR (the oldest of the sources by parallel age compares): candidate i wins
    // when it is strictly older than every earlier valid candidate and no later one is strictly older
    // than it (an earlier candidate wins a tie, as the serial scan did)
    localparam int NRC = 1 + N_STU + N_BJU + (STD_SPLIT ? N_LDU : 0);
    redirect_t rc [NRC];
    redirect_t unc_rq;                  // REDIR_KILL_LATE: MMIO replay candidate, registered
    always_ff @(posedge clk) begin
        if (!rst_n) unc_rq <= '0;
        else        unc_rq <= unc_replay;
    end
    always_comb begin
        rc[0] = REDIR_KILL_LATE ? unc_rq : unc_replay;
        for (int u = 0; u < N_STU; u++) begin
            rc[1 + u] = VIOL_REG ? viol_q[u] : viol_s[u];
            if (VIOL_REG && !REDIR_KILL_LATE && killed_by(redir_q, viol_q[u].rob_idx)) rc[1 + u].valid = 1'b0;
        end
        for (int k = 0; k < N_BJU; k++) begin
            redirect_t b;
            b = '0;
            b.valid      = (REDIR_KILL_LATE ? br_lraw[k] : br_live[k]) && br_misp[k];
            b.rob_idx    = br_ex[k].rob_idx;
            b.flush_self = 1'b0;
            b.target     = br_next[k];
            b.ftq_idx    = br_ex[k].ftq_idx;
            b.lq_ptr     = br_ex[k].lq_ptr;
            b.sq_ptr     = br_ex[k].sq_ptr;
            b.is_call    = br_ex[k].is_call;
            b.is_ret     = br_ex[k].is_ret;
            b.link       = br_pc[k] + (br_ex[k].rvc ? 64'd2 : 64'd4);
            b.rvc        = br_ex[k].rvc;
            b.taken      = br_taken[k];
            rc[1 + N_STU + k] = b;
        end
        for (int m = 0; m < (STD_SPLIT ? N_LDU : 0); m++) begin
            rc[1 + N_STU + N_BJU + m] = lf_q[m];
            // LF_STPC_LATE: the store's pc from the FTQ after the register (the store has no data yet,
            // so it cannot have committed and its FTQ entry is still valid)
            if (LF_STPC_LATE) rc[1 + N_STU + N_BJU + m].st_pc = upc(pcm_start[lf_sftq_q[m][FTQ_PW-2:0]], lf_soff_q[m]);
            if (!REDIR_KILL_LATE && killed_by(redir_q, lf_q[m].rob_idx)) rc[1 + N_STU + N_BJU + m].valid = 1'b0;
        end
    end
    if (REDIR_PAR) begin : g_rsel
        always_comb begin
            logic [NRC-1:0] win;
            for (int i = 0; i < NRC; i++) begin
                win[i] = rc[i].valid;
                for (int j = 0; j < NRC; j++) begin
                    if (j < i && rc[j].valid && !rob_older(rc[i].rob_idx, rc[j].rob_idx)) win[i] = 1'b0;
                    if (j > i && rc[j].valid &&  rob_older(rc[j].rob_idx, rc[i].rob_idx)) win[i] = 1'b0;
                end
            end
            redir_sel = '0;
            for (int i = 0; i < NRC; i++) if (win[i]) redir_sel = redir_sel | rc[i];   // one-hot AND-OR
            if (REDIR_KILL_LATE && killed_by(redir_q, redir_sel.rob_idx)) redir_sel.valid = 1'b0;
        end
    end else begin : g_rser
        always_comb begin
            redir_sel = rc[0];
            for (int i = 1; i < NRC; i++)
                if (rc[i].valid && (!redir_sel.valid || rob_older(rc[i].rob_idx, redir_sel.rob_idx))) redir_sel = rc[i];
            if (REDIR_KILL_LATE && killed_by(redir_q, redir_sel.rob_idx)) redir_sel.valid = 1'b0;
        end
    end
`ifndef SYNTHESIS
    // REDIR_KILL_LATE: same redirect as selecting among the candidates that survive redir_q
    always_ff @(posedge clk)
        if (rst_n && REDIR_KILL_LATE) begin
            redirect_t r;
            r = '0;
            for (int i = 0; i < NRC; i++)
                if (rc[i].valid && !killed_by(redir_q, rc[i].rob_idx) && (!r.valid || rob_older(rc[i].rob_idx, r.rob_idx)))
                    r = rc[i];
            if (r.valid != redir_sel.valid || (r.valid && (r.rob_idx != redir_sel.rob_idx || r.flush_self != redir_sel.flush_self)))
                $error("REDIR_KILL_LATE: redirect differs from the early-kill selection");
        end
`endif

    // =====================================================================
    // Commit
    // =====================================================================
    logic [DEC_W-1:0] cmt_v;
    rob_ptr_t cmt_idx [DEC_W];
    always_comb begin
        int cnt;
        logic go;
        logic [DEC_W:0] room;            // room[j]: j more CFIs fit in the training queue
        int pre;                         // CFIs in the slots before k (they all commit when slot k does)
        cnt = rob_dist(rob_head, rob_tail);
        for (int j = 0; j <= DEC_W; j++) room[j] = j < cu_free;
        go = 1'b1; pre = 0;
        // every slot's condition is independent of the others; only the final AND is a prefix
        for (int k = 0; k < DEC_W; k++) begin
            logic [ROB_PW-2:0] e;
            cmt_idx[k] = rob_add(rob_head, k);
            e = cmt_idx[k][ROB_PW-2:0];
            go = go && (k < cnt) && rob_done[e]
                    && !killed_by(redir_q, cmt_idx[k])
                    && !(walking && !rob_older(cmt_idx[k], walk_target))
                    && !(fwalk && !rob_older(cmt_idx[k], fw_ptr))     // not yet re-applied
                    && !(rob_is_cfi[e] && !room[pre]);                 // training queue space
            cmt_v[k] = go;
            if (rob_is_cfi[e]) pre++;
        end
    end

    logic [63:0] dbg_cmt_pc [DEC_W];     // debug: pc of each commit slot
    always_comb for (int k = 0; k < DEC_W; k++)
        dbg_cmt_pc[k] = upc(pcm_start[rob_ftq[cmt_idx[k][ROB_PW-2:0]][FTQ_PW-2:0]], rob_off[cmt_idx[k][ROB_PW-2:0]]);

    // BTB training + FTQ release from the committed group
    always_comb begin
        cu_valid = '0; cu_pc = '0; cu_target = '0; cu_taken = '0; cu_type = '0; cu_call = '0; cu_ftq = '0; cu_rvc = '0;
        cmt_ftq_valid = 1'b0; cmt_ftq = '0;
        for (int k = 0; k < DEC_W; k++) begin
            logic [ROB_PW-2:0] e;
            e = cmt_idx[k][ROB_PW-2:0];
            if (cmt_v[k]) begin
                cmt_ftq_valid = 1'b1;
                cmt_ftq = rob_ftq[e];
                if (rob_is_cfi[e]) begin
                    cu_valid[k]  = 1'b1;
                    cu_pc[k]     = upc(pcm_start[rob_ftq[e][FTQ_PW-2:0]], rob_off[e]);
                    cu_target[k] = ftq_rtgt[rob_ftq[e][FTQ_PW-2:0]];
                    cu_taken[k]  = rob_taken[e];
                    cu_type[k]   = rob_cfi[e];
                    cu_call[k]   = rob_call[e];
                    cu_rvc[k]    = rob_rvc[e];
                    cu_ftq[k]    = rob_ftq[e];
                end
            end
        end
    end

    // =====================================================================
    // Store drain: committed stores are written to memory, 2 per cycle (to different banks)
    // =====================================================================
    if (!SBUFFER) begin : g_nosb
    always_comb begin
        sq_ptr_t h;
        logic    w0, b0;
        h = sq_head;
        w0 = 1'b0; b0 = 1'b0;
        for (int dd = 0; dd < 2; dd++) begin
            // the data RAM has two banks (address bit 3) with one write port each
            dm_we[dd]    = (h != sq_cmt) && !(dd == 1 && w0 && sq_addr[h[SQ_PW-2:0]][3] == b0);
            dm_waddr[dd] = sq_addr[h[SQ_PW-2:0]];
            dm_wdata[dd] = sq_data[h[SQ_PW-2:0]];
            dm_wmask[dd] = sq_mask[h[SQ_PW-2:0]];
            if (dd == 0) begin w0 = dm_we[0]; b0 = sq_addr[h[SQ_PW-2:0]][3]; end
            if (dm_we[dd]) h = sq_add(h, 1);
        end
        sq_head_next = h;
    end
    end else begin : g_sb
    // =====================================================================
    // Committed-store buffer (SBUFFER): up to 2 committed stores per cycle leave the SQ
    // head in order into 16 B line entries (merged into a line held, else a free entry; two stores to one
    // new line share it). One line per cycle is written to memory (one dword per bank) when the active
    // count reached SB_THRESH (registered), on a timeout, or to drain for MMIO; the
    // victim by a valid-aware tree PLRU, updated by every write into a line and by
    // the eviction. A line being written out takes no merge. An MMIO store leaves the SQ head only when
    // the buffer is empty, written to its device directly
    // =====================================================================
        localparam int SBW = $clog2(SB_N);
        logic [SB_N-1:1]  plru;                 // tree node n: 1 = the victim is in the upper half
        logic [20:0]      tcnt [SB_N];
        logic             ev_q;                 // registered: active count >= SB_THRESH
        logic [SB_N-1:0]  vic, ev_oh, tmo, m0, m1, f0, f1, t0, t1, cand;
        logic             ev, drain, enq0, enq1, mmio_w, same01;
        // eviction in two stages: s0 picks the victim (registered), s1 reads the
        // line from its entry, writes it to memory and drops the entry (it takes no merge in s1; a store to
        // that line gets a new entry, which forwarding puts over the one being written)
        logic             ev1;
        logic [SB_N-1:0]  vic1;
        logic [59:0]      ev1_tag;
        logic [127:0]     ev1_data;
        logic [15:0]      ev1_mask;
        assign sb_infl = ev1 ? vic1 : '0;
        logic [59:0]      tg0, tg1;
        sq_ptr_t          h0, h1;
        int               ncmt;
        // SB_MATCH_PRE: registered matches of the next head positions 0 / 1 (mq0 / mq1, before the candidate
        // mask) and whether they are one line (sameq)
        logic [SB_N-1:0]  mq0, mq1, mq0_n, mq1_n;
        logic             sameq, sameq_n;
        // MMIO_WREG: the MMIO store leaves the SQ in the cycle it is chosen and is written from registers the next
        // cycle (the buffer is empty then, so no line is in s1); an MMIO load also waits for it
        logic [63:0]      mmio_wa, mmio_wd;
        logic [7:0]       mmio_wm;
        always_ff @(posedge clk) begin
            mmio_wq <= rst_n && mmio_w;
            mmio_wa <= sq_addr[h0[SQ_PW-2:0]];
            mmio_wd <= sq_data[h0[SQ_PW-2:0]];
            mmio_wm <= sq_mask[h0[SQ_PW-2:0]];
        end
        always_comb begin
            int node;
            logic seen;
            // victim: walk the tree, leaving a half without candidates (valid, not being written)
            cand = sb_v & ~sb_infl;
            node = 1;
            for (int l = 0; l < SBW; l++) begin
                logic [SB_N-1:0] lo, hi;
                int start, half;
                half  = SB_N >> (l + 1);
                start = (node - (1 << l)) * (SB_N >> l);
                for (int i = 0; i < SB_N; i++) begin
                    lo[i] = i >= start && i < start + half;
                    hi[i] = i >= start + half && i < start + 2 * half;
                end
                if (plru[node] ? (cand & hi) != '0 : (cand & lo) == '0) node = 2 * node + 1;
                else node = 2 * node;
            end
            vic = '0;
            vic[node - SB_N] = 1'b1;
            for (int e = 0; e < SB_N; e++) tmo[e] = cand[e] && int'(tcnt[e]) >= SB_TIMEOUT - 1;
            if (tmo != '0) begin                 // a timed-out line first (the lowest)
                seen = 1'b0;
                for (int e = 0; e < SB_N; e++) begin vic[e] = tmo[e] && !seen; seen = seen || tmo[e]; end
            end
            ncmt  = sq_dist(sq_head, sq_cmt);
            h0    = sq_head;
            h1    = sq_add(sq_head, 1);
            drain = unc_v || (ncmt > 0 && is_mmio(sq_addr[h0[SQ_PW-2:0]]));
            ev    = cand != '0 && (drain || ev_q || tmo != '0);
            ev_oh = ev ? vic : '0;
            // enqueue
            tg0 = sq_addr[h0[SQ_PW-2:0]][63:4];
            tg1 = sq_addr[h1[SQ_PW-2:0]][63:4];
            for (int e = 0; e < SB_N; e++) begin
                m0[e] = cand[e] && (SB_MATCH_PRE ? mq0[e] : sb_tag[e] == tg0);   // (a line picked in s0 still takes
                m1[e] = cand[e] && (SB_MATCH_PRE ? mq1[e] : sb_tag[e] == tg1);   //  merges: s1 reads it from the entry)
            end
            seen = 1'b0;
            for (int e = 0; e < SB_N; e++) begin f0[e] = !sb_v[e] && !seen; seen = seen || !sb_v[e]; end
            f1 = '0;
            seen = 1'b0;
            for (int e = 0; e < SB_N; e++) begin f1[e] = !sb_v[e] && !f0[e] && !seen; seen = seen || (!sb_v[e] && !f0[e]); end
            same01 = SB_MATCH_PRE ? sameq : tg1 == tg0;
            t0   = (m0 != '0) ? m0 : f0;
            enq0 = ncmt > 0 && !is_mmio(sq_addr[h0[SQ_PW-2:0]]) && t0 != '0;
            t1   = same01 ? t0 : (m1 != '0) ? m1 : (m0 == '0) ? f1 : f0;
            enq1 = enq0 && ncmt > 1 && !is_mmio(sq_addr[h1[SQ_PW-2:0]]) && t1 != '0;
            mmio_w = ncmt > 0 && is_mmio(sq_addr[h0[SQ_PW-2:0]]) && sb_v == '0;
            // memory write ports: the line in s1 (read from its entry by the registered one-hot), else an
            // MMIO store
            ev1_tag = '0; ev1_data = '0; ev1_mask = '0;
            for (int e = 0; e < SB_N; e++) begin
                ev1_tag  = ev1_tag  | ({60{sb_infl[e]}}  & sb_tag[e]);
                ev1_data = ev1_data | ({128{sb_infl[e]}} & sb_data[e]);
                ev1_mask = ev1_mask | ({16{sb_infl[e]}}  & sb_mask[e]);
            end
            for (int dd = 0; dd < 2; dd++) begin
                dm_we[dd]    = ev1 && ev1_mask[8*dd +: 8] != '0;
                dm_waddr[dd] = {ev1_tag, (dd == 1) ? 4'h8 : 4'h0};
                dm_wdata[dd] = ev1_data[64*dd +: 64];
                dm_wmask[dd] = ev1_mask[8*dd +: 8];
            end
            if (MMIO_WREG ? mmio_wq : mmio_w) begin
                dm_we[0]    = 1'b1;
                dm_waddr[0] = MMIO_WREG ? mmio_wa : sq_addr[h0[SQ_PW-2:0]];
                dm_wdata[0] = MMIO_WREG ? mmio_wd : sq_data[h0[SQ_PW-2:0]];
                dm_wmask[0] = MMIO_WREG ? mmio_wm : sq_mask[h0[SQ_PW-2:0]];
            end
            sq_head_next = sq_add(sq_head, int'(enq0) + int'(enq1) + int'(mmio_w));
        end
        // SB_MATCH_PRE: the head moves by adv = 0..2, so the next positions 0 / 1 are among the 4 ahead. Their
        // matches against the tags the entries hold next cycle (the line written into an entry this cycle,
        // else its tag) are computed for all 4 and selected by adv
        always_comb begin
            logic [59:0]     L  [4];
            logic [SB_N-1:0] nx [4];
            logic [3:0]      e0, e1;
            logic [2:0]      sn;
            int              adv;
            sq_ptr_t         h2, h3;
            h2 = sq_add(sq_head, 2);
            h3 = sq_add(sq_head, 3);
            L[0] = tg0; L[1] = tg1;
            L[2] = sq_addr[h2[SQ_PW-2:0]][63:4];
            L[3] = sq_addr[h3[SQ_PW-2:0]][63:4];
            for (int k = 0; k < 4; k++) begin
                e0[k] = L[k] == tg0;
                e1[k] = L[k] == tg1;
                for (int e = 0; e < SB_N; e++)
                    nx[k][e] = (enq0 && t0[e]) ? e0[k] : (enq1 && t1[e]) ? e1[k] : sb_tag[e] == L[k];
            end
            for (int k = 0; k < 3; k++) sn[k] = L[k] == L[k + 1];
            adv     = int'(enq0) + int'(enq1) + int'(mmio_w);
            mq0_n   = nx[adv];
            mq1_n   = nx[adv + 1];
            sameq_n = sn[adv];
        end
        always_ff @(posedge clk) begin
            mq0 <= mq0_n; mq1 <= mq1_n; sameq <= sameq_n;
        end
`ifndef SYNTHESIS
        // the registered matches equal the compares of the head stores that leave the SQ
        always_ff @(posedge clk)
            if (rst_n && SB_MATCH_PRE) begin
                logic [SB_N-1:0] r0, r1;
                for (int e = 0; e < SB_N; e++) begin r0[e] = sb_tag[e] == tg0; r1[e] = sb_tag[e] == tg1; end
                if (ncmt > 0 && !is_mmio(sq_addr[h0[SQ_PW-2:0]]) && (cand & mq0) != (cand & r0))
                    $error("SB_MATCH_PRE: head 0 match differs");
                if (ncmt > 1 && !is_mmio(sq_addr[h1[SQ_PW-2:0]]) && ((cand & mq1) != (cand & r1) || sameq != (tg0 == tg1)))
                    $error("SB_MATCH_PRE: head 1 match differs");
            end
`endif
        for (genvar e = 0; e < SB_N; e++) begin : g_e
            always_ff @(posedge clk) begin
                logic w0, w1;
                logic [127:0] d;
                logic [15:0]  m;
                w0 = enq0 && t0[e];
                w1 = enq1 && t1[e];
                d  = sb_v[e] ? sb_data[e] : '0;
                m  = sb_v[e] ? sb_mask[e] : '0;
                if (w0) begin
                    for (int b = 0; b < 8; b++)
                        if (sq_mask[h0[SQ_PW-2:0]][b]) d[64*sq_addr[h0[SQ_PW-2:0]][3] + 8*b +: 8] = sq_data[h0[SQ_PW-2:0]][8*b +: 8];
                    m = m | (16'(sq_mask[h0[SQ_PW-2:0]]) << (8 * sq_addr[h0[SQ_PW-2:0]][3]));
                end
                if (w1) begin
                    for (int b = 0; b < 8; b++)
                        if (sq_mask[h1[SQ_PW-2:0]][b]) d[64*sq_addr[h1[SQ_PW-2:0]][3] + 8*b +: 8] = sq_data[h1[SQ_PW-2:0]][8*b +: 8];
                    m = m | (16'(sq_mask[h1[SQ_PW-2:0]]) << (8 * sq_addr[h1[SQ_PW-2:0]][3]));
                end
                if (!rst_n) begin
                    sb_v[e] <= 1'b0;
                    tcnt[e] <= '0;
                end else if (w0 || w1) begin
                    sb_v[e]    <= 1'b1;
                    sb_tag[e]  <= w0 ? tg0 : tg1;
                    sb_data[e] <= d;
                    sb_mask[e] <= m;
                    tcnt[e]    <= '0;
                end else begin
                    if (sb_infl[e]) sb_v[e] <= 1'b0;
                    if (sb_v[e] && int'(tcnt[e]) < SB_TIMEOUT - 1) tcnt[e] <= tcnt[e] + 1'b1;
                end
            end
        end
        always_ff @(posedge clk) begin
            logic [SB_N-1:1] p;
            int n;
            if (!rst_n) begin
                plru <= '0;
                ev_q <= 1'b0;
                ev1  <= 1'b0;
            end else begin
                ev1  <= ev;
                vic1 <= ev_oh;
                n = 0;
                for (int e = 0; e < SB_N; e++) n += int'(sb_v[e]);
                ev_q <= n >= SB_THRESH;
                p = plru;
                // accesses in order: the two writes into lines, then the line written out in s1 (point away
                // from each; the s1 access keeps the victim choice off the enqueue path)
                for (int a = 0; a < 3; a++) begin
                    logic [SB_N-1:0] oh;
                    logic act;
                    int leaf, node;
                    oh  = (a == 0) ? t0 : (a == 1) ? t1 : vic1;
                    act = (a == 0) ? enq0 : (a == 1) ? enq1 : ev1;
                    leaf = 0;
                    for (int e = 0; e < SB_N; e++) if (oh[e]) leaf = e;
                    if (act) begin
                        node = 1;
                        for (int l = SBW - 1; l >= 0; l--) begin
                            p[node] = !leaf[l];          // the accessed leaf is in the lower half: victim upper
                            node = 2 * node + int'(leaf[l]);
                        end
                    end
                end
                plru <= p;
            end
        end
    end

    for (genvar f = 0; f < FTQ_N; f++) begin : g_rtgt
        always_ff @(posedge clk) begin
            int w;
            w = -1;
            for (int k = 0; k < N_BJU; k++)
                if (brw_live[k] && brw_taken[k] && brw_ftq[k][FTQ_PW-2:0] == ($clog2(FTQ_N))'(f) &&
                    (w < 0 || rob_older(brw_rob[k], brw_rob[w]))) w = k;
            if (w >= 0) ftq_rtgt[f] <= brw_tgt[w];
        end
    end

    // debug writeback outputs
    always_comb begin
        for (int q = 0; q < N_WB; q++) begin
            dbg_wb_valid[q] = wbp[q].v && wbp[q].wen;
            dbg_wb_value[q] = wbp[q].val;
        end
    end

    // =====================================================================
    // Walk / commit bookkeeping (combinational)
    // =====================================================================
    logic [DEC_W-1:0]  walk_v;
    logic [ROB_PW-2:0] walk_e [DEC_W];
    rob_ptr_t          walk_tail_next;
    logic [DEC_W-1:0]  walk_v_c;
    logic [ROB_PW-2:0] walk_e_c [DEC_W];
    rob_ptr_t          walk_tail_next_c;
    always_comb begin
        rob_ptr_t t;
        t = rob_tail;
        for (int j = 0; j < DEC_W; j++) begin
            walk_v_c[j] = walking && !redir_q.valid && (t != walk_target);
            if (walk_v_c[j]) t = rob_sub1(t);
            walk_e_c[j] = t[ROB_PW-2:0];
        end
        walk_tail_next_c = t;
    end
    if (WALK_PAR) begin : g_walk_par
        // entries left to undo (walk_target is never younger than rob_tail while walking); every slot's
        // entry is rob_tail - 1 - j, and the next tail is picked from the DEC_W + 1 candidates by the count
        int       walk_rem;
        rob_ptr_t walk_t [DEC_W + 1];
        assign walk_rem = rob_dist(walk_target, rob_tail);
        always_comb begin
            walk_t[0] = rob_tail;
            for (int j = 0; j < DEC_W; j++) walk_t[j + 1] = rob_sub1(walk_t[j]);
            walk_tail_next = rob_tail;
            for (int j = 0; j < DEC_W; j++) begin
                walk_v[j] = walking && !redir_q.valid && walk_rem > j;
                walk_e[j] = walk_t[j + 1][ROB_PW-2:0];
            end
            for (int j = 0; j < DEC_W; j++)
                if (walk_v[j]) walk_tail_next = walk_t[j + 1];
        end
`ifndef SYNTHESIS
        always_ff @(posedge clk)
            if (rst_n && (walk_v != walk_v_c || walk_tail_next != walk_tail_next_c))
                $error("WALK_PAR mismatch: v %b/%b tail %h/%h", walk_v, walk_v_c, walk_tail_next, walk_tail_next_c);
`endif
    end else begin : g_walk_ser
        always_comb begin
            walk_v = walk_v_c; walk_e = walk_e_c; walk_tail_next = walk_tail_next_c;
        end
    end

    always_comb begin
        wb_i = 0; wb_f = 0; fw_i = 0; fw_f = 0;
        for (int k = 0; k < DEC_W; k++) begin
            fr_ic_v[k] = cmt_v[k] && rob_wen[cmt_e[k]] && !rob_ldst[cmt_e[k]][5];
            fr_f_v[k]  = cmt_v[k] && rob_wen[cmt_e[k]] &&  rob_ldst[cmt_e[k]][5];
            fr_p[k]    = rob_old[cmt_e[k]];
            // (a move allocated nothing: the walks do not give back or take a register for it)
            if (walk_v[k] && rob_wen[walk_e[k]] && !rob_mv[walk_e[k]]) begin if (rob_ldst[walk_e[k]][5]) wb_f++; else wb_i++; end
            if (!FW_PIPE && fw_v[k] && fw_wen[k] && !fw_mv[k])         begin if (fw_ldst[k][5])          fw_f++; else fw_i++; end
        end
        if (FW_PIPE && fw_v[0]) begin fw_i = int'(fw_b_ni); fw_f = int'(fw_b_nf); end
    end
`ifndef SYNTHESIS
    // a register taken from the free list is mapped by no architectural register (speculative or committed)
    always_ff @(posedge clk)
        if (rst_n && can_rename)
            for (int i = 0; i < DEC_W; i++)
                if (acc[i] && d[i].wen && !d[i].mv && !d[i].ldst[5])
                    for (int r = 1; r < 32; r++)
                        if (rat[r] == r_uop[i].pdest || arch_rat[r] == r_uop[i].pdest)
                            $error("free list gave preg %0d still mapped by x%0d (rat %0d arch %0d)",
                                   r_uop[i].pdest, r, rat[r], arch_rat[r]);
`endif
    // integer releases: with MOVE_ELIM a register may be mapped by several architectural registers, so the
    // old mapping is registered at commit and released the next cycle only if the committed table (now
    // updated with that commit group) no longer holds it, once per group
    logic [DEC_W-1:0] fr_ic_v, fr_iq_v;
    preg_t            fr_iq_p [DEC_W];
    always_ff @(posedge clk)
        for (int k = 0; k < DEC_W; k++) begin
            fr_iq_v[k] <= rst_n && MOVE_ELIM && fr_ic_v[k];
            fr_iq_p[k] <= fr_p[k];
        end
    always_comb begin
        if (MOVE_ELIM) begin
            for (int k = 0; k < DEC_W; k++) begin
                logic held;
                held = 1'b0;
                for (int r = 0; r < 32; r++) if (arch_rat[r] == fr_iq_p[k]) held = 1'b1;
                for (int j = 0; j < k; j++) if (fr_iq_v[j] && fr_iq_p[j] == fr_iq_p[k]) held = 1'b1;
                fr_i_v[k] = fr_iq_v[k] && !held;
                fr_ip[k]  = fr_iq_p[k];
            end
        end else begin
            fr_i_v = fr_ic_v;
            fr_ip  = fr_p;
        end
    end

    logic [ROB_PW-2:0] cmt_e [DEC_W];
    int cmt_n, cmt_nl, cmt_ns;
    logic [4:0] cmt_fflags;
    always_comb begin
        cmt_n = 0; cmt_nl = 0; cmt_ns = 0; cmt_fflags = '0;
        for (int k = 0; k < DEC_W; k++) begin
            cmt_e[k] = cmt_idx[k][ROB_PW-2:0];
            if (cmt_v[k]) begin
                cmt_n++;
                cmt_nl += int'(rob_is_ld[cmt_e[k]]);
                cmt_ns += int'(rob_is_st[cmt_e[k]]);
                cmt_fflags |= rob_fflags[cmt_e[k]];
            end
        end
    end

    // =====================================================================
    // StoreSet training (memory-order violation) and LFST update (store rename)
    // =====================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ssit_v <= '0; lfst_v <= '0; ssit_clear_cnt <= '0;
        end else if (MDP_STORESET) begin
            ssit_clear_cnt <= ssit_clear_cnt + 1'b1;
            if (ssit_clear_cnt == '1) ssit_v <= '0;                       // periodic reset
            else if (redir_q.valid && redir_q.mdp_train) begin
                logic [7:0] li, si;
                logic [SSID_W-1:0] id;
                li = ssit_idx(redir_pc);                            // the replayed load
                si = ssit_idx(redir_q.st_pc);
                if (ssit_v[li] && ssit_v[si]) id = (ssit_id[li] < ssit_id[si]) ? ssit_id[li] : ssit_id[si];
                else if (ssit_v[li]) id = ssit_id[li];
                else if (ssit_v[si]) id = ssit_id[si];
                else id = li[SSID_W-1:0] ^ li[7:8-SSID_W];
                ssit_v[li] <= 1'b1; ssit_id[li] <= id;
                ssit_v[si] <= 1'b1; ssit_id[si] <= id;
            end
            // LFST: last renamed store of each set (in program order: the youngest wins)
            if (can_rename)
                for (int i = 0; i < DEC_W; i++) begin
                    logic [7:0] sj;
                    sj = ssit_idx(rn_f[i].pc);
                    if (acc[i] && d[i].fu == FU_STU && ssit_v[sj]) begin
                        lfst_v[ssit_id[sj]]  <= 1'b1;
                        lfst_sq[ssit_id[sj]] <= r_uop[i].sq_ptr;
                        lfst_rob[ssit_id[sj]] <= r_uop[i].rob_idx;
                    end
                end
        end
    end

    // =====================================================================
    // Rename snapshots
    // =====================================================================
    logic                 snap_v    [SNAP_N];
    rob_ptr_t             snap_rob  [SNAP_N];
    preg_t                snap_rat  [SNAP_N][64];
    logic                 snap_take, snap_cand, snap_hit, snap_exact;
    int                   snap_slot, snap_sel;
    logic                 last_snap_v;
    rob_ptr_t             last_snap_rob, redir_keep, redir_keep1;
    localparam int        SNAP_W = (SNAP_N > 1) ? $clog2(SNAP_N) : 1;
    logic [DEC_W-1:0]     fw_v;
    logic [ROB_PW-2:0]    fw_e [DEC_W];
    rob_ptr_t             fw_ptr_next;
    // forward-walk batch applied this cycle (fw_v): ROB fields of its entries
    logic                 fw_wen [DEC_W], fw_mv [DEC_W];
    logic [5:0]           fw_ldst [DEC_W];
    preg_t                fw_pdest [DEC_W];
    // FW_PIPE: registered batch starting at fw_ptr and ending at fw_b_end, with its allocation counts
    logic [DEC_W-1:0]     fw_b_v;
    logic                 fw_b_wen [DEC_W], fw_b_mv [DEC_W];
    logic [5:0]           fw_b_ldst [DEC_W];
    preg_t                fw_b_pdest [DEC_W];
    rob_ptr_t             fw_b_end;
    logic [$clog2(DEC_W+1)-1:0] fw_b_ni, fw_b_nf;
    preg_t                snap_rat_new [64];
    rob_ptr_t             snap_rob_new;
    always_comb begin
        int j;
        // youngest accepted conditional branch / JALR of this rename group
        // (REN_GROUP_ACC: over the slots that would be taken, so the snapshot contents do not wait for the
        // acceptance; they are written into a free slot and made valid only when the group is taken)
        j = -1;
        for (int i = 0; i < DEC_W; i++)
            if ((REN_GROUP_ACC ? ren_pa[i] : acc[i]) && d[i].fu == FU_BJU && d[i].cfit != CFI_JAL) j = i;
        snap_slot = -1;
        for (int k = SNAP_N - 1; k >= 0; k--) if (!snap_v[k]) snap_slot = k;
        snap_rob_new = (j >= 0) ? r_uop[j].rob_idx : '0;
        snap_cand = SNAP_EN && j >= 0 && snap_slot >= 0;
        snap_take = SNAP_EN && can_rename && j >= 0 && acc[j] && snap_slot >= 0 &&
                    (SNAP_DIST == 0 || !last_snap_v || rob_dist(last_snap_rob, snap_rob_new) >= SNAP_DIST);
        // state right after instruction j
        for (int r = 0; r < 64; r++) begin
            snap_rat_new[r] = rat[r];
            for (int i = 0; i < DEC_W; i++)
                if (i <= j && (REN_GROUP_ACC ? ren_pa[i] : acc[i]) && d[i].wen && d[i].ldst == 6'(r)) snap_rat_new[r] = r_uop[i].pdest;
        end
        // free-list heads right after instruction j (its allocations and the older ones taken)
        begin
            int ni, nf;
            ni = 0; nf = 0;
            for (int i = 0; i < DEC_W; i++)
                if (i <= j && (REN_GROUP_ACC ? ren_pa[i] : acc[i]) && d[i].wen) begin
                    if (d[i].ldst[5]) nf++; else if (!d[i].mv) ni++;     // a move allocates nothing
                end
            snap_hi_new = FLI_W'((int'(fli_head) + ni) % (2 * FLI_CAP));
            snap_hf_new = FLF_W'((int'(flf_head) + nf) % (2 * FLF_N));
        end
        // restore: youngest snapshot at (exact) or before (forward walk) the last kept instruction
        redir_keep = redir_q.flush_self ? rob_sub1(redir_q.rob_idx) : redir_q.rob_idx;
        redir_keep1 = SNAP_SEL_OH ? (redir_q.flush_self ? redir_q.rob_idx : rob_add(redir_q.rob_idx, 1))
                                  : rob_add(redir_keep, 1);
        if (SNAP_SEL_OH) begin
            logic [SNAP_N-1:0] c, oh, eq;
            logic [SNAP_W-1:0] sb;
            for (int k = 0; k < SNAP_N; k++) begin
                // snapshot k is the last kept instruction
                eq[k] = redir_q.flush_self ? rob_add(snap_rob[k], 1) == redir_q.rob_idx : snap_rob[k] == redir_q.rob_idx;
                c[k]  = SNAP_EN && snap_v[k] && redir_q.valid && (SNAP_FWD ? !killed_by(redir_q, snap_rob[k]) : eq[k]);
            end
            // the youngest candidate (equal positions: the lowest slot)
            for (int k = 0; k < SNAP_N; k++) begin
                logic [SNAP_N-1:0] yg;
                for (int j = 0; j < SNAP_N; j++)
                    yg[j] = j != k && c[j] && (rob_older(snap_rob[k], snap_rob[j]) || (j < k && snap_rob[j] == snap_rob[k]));
                oh[k] = c[k] && !(|yg);
            end
            for (int b = 0; b < SNAP_W; b++) begin
                logic [SNAP_N-1:0] m;
                for (int k = 0; k < SNAP_N; k++) m[k] = 1'((k >> b) & 1);
                sb[b] = |(oh & m);
            end
            snap_hit   = |oh;
            snap_sel   = int'(sb);
            snap_exact = |(oh & eq);
        end else begin
            snap_hit = 1'b0; snap_sel = 0;
            for (int k = 0; k < SNAP_N; k++)
                if (SNAP_EN && snap_v[k] && redir_q.valid &&
                    (snap_rob[k] == redir_keep || (SNAP_FWD && rob_older(snap_rob[k], redir_keep))) &&
                    (!snap_hit || rob_older(snap_rob[snap_sel], snap_rob[k]))) begin
                    snap_hit = 1'b1; snap_sel = k;
                end
            snap_exact = snap_rob[snap_sel] == redir_keep;
        end
        snap_hit_w = snap_hit;
        snap_sel_w = snap_sel;
        // forward walk: re-apply the renames of fw_ptr .. fw_end-1, DEC_W per cycle
        if (FW_PIPE) begin
            for (int q = 0; q < DEC_W; q++) begin
                fw_v[q] = fwalk && !redir_q.valid && fw_b_v[q];
                fw_e[q] = '0;
                fw_wen[q] = fw_b_wen[q]; fw_mv[q] = fw_b_mv[q]; fw_ldst[q] = fw_b_ldst[q]; fw_pdest[q] = fw_b_pdest[q];
            end
            fw_ptr_next = fw_b_end;
        end else begin
            rob_ptr_t t;
            t = fw_ptr;
            for (int q = 0; q < DEC_W; q++) begin
                fw_v[q] = fwalk && !redir_q.valid && t != fw_end;
                fw_e[q] = t[ROB_PW-2:0];
                if (fw_v[q]) t = rob_add(t, 1);
                fw_wen[q] = rob_wen[fw_e[q]]; fw_mv[q] = rob_mv[fw_e[q]];
                fw_ldst[q] = rob_ldst[fw_e[q]]; fw_pdest[q] = rob_pdest[fw_e[q]];
            end
            fw_ptr_next = t;
        end
    end
    if (FW_PIPE) begin : g_fwp
        // next batch: the entries after the one applied this cycle (slot q valid when q < the remaining count).
        // The kept ROB entries do not change during the walk (rename is stopped)
        logic [DEC_W-1:0]     a_v;
        logic [ROB_PW-2:0]    a_e [DEC_W];
        rob_ptr_t             a_end;
        logic [$clog2(DEC_W+1)-1:0] a_ni, a_nf;
        always_comb begin
            int rem;
            rem = rob_dist(fw_b_end, fw_end);
            a_ni = '0; a_nf = '0;
            for (int q = 0; q < DEC_W; q++) begin
                rob_ptr_t t;
                t = rob_add(fw_b_end, q);
                a_v[q] = rem > q;
                a_e[q] = t[ROB_PW-2:0];
                if (a_v[q] && rob_wen[a_e[q]] && !rob_mv[a_e[q]]) begin
                    if (rob_ldst[a_e[q]][5]) a_nf++; else a_ni++;
                end
            end
            a_end = a_v[DEC_W-1] ? rob_add(fw_b_end, DEC_W) : fw_end;
        end
        always_ff @(posedge clk) begin
            if (!rst_n || redir_q.valid || !fwalk) begin
                // a redirect starts or shortens the walk: restart from the applied position (one bubble)
                fw_b_v <= '0; fw_b_ni <= '0; fw_b_nf <= '0;
                fw_b_end <= !rst_n ? '0 : (redir_q.valid && snap_hit) ? rob_add(snap_rob[snap_sel], 1) : fw_ptr;
            end else begin
                fw_b_v <= a_v; fw_b_ni <= a_ni; fw_b_nf <= a_nf; fw_b_end <= a_end;
            end
            for (int q = 0; q < DEC_W; q++) begin
                fw_b_wen[q] <= rob_wen[a_e[q]]; fw_b_mv[q] <= rob_mv[a_e[q]];
                fw_b_ldst[q] <= rob_ldst[a_e[q]]; fw_b_pdest[q] <= rob_pdest[a_e[q]];
            end
        end
    end
    always_ff @(posedge clk) begin
        if (!rst_n) last_snap_v <= 1'b0;
        else if (snap_take) begin last_snap_v <= 1'b1; last_snap_rob <= snap_rob_new; end
        else if (redir_q.valid && last_snap_v && killed_by(redir_q, last_snap_rob)) last_snap_v <= 1'b0;
    end
    for (genvar k = 0; k < SNAP_N; k++) begin : g_snap
        always_ff @(posedge clk) begin
            if (!rst_n) snap_v[k] <= 1'b0;
            else begin
                logic cmt;
                cmt = 1'b0;
                for (int c = 0; c < DEC_W; c++) if (cmt_v[c] && cmt_idx[c] == snap_rob[k]) cmt = 1'b1;
                if (snap_v[k] && (cmt || killed_by(redir_q, snap_rob[k]))) snap_v[k] <= 1'b0;
                if (snap_take && snap_slot == k) snap_v[k] <= 1'b1;
                // contents: into the free slot whenever the group has a branch (REN_GROUP_ACC: also when the
                // group is not taken this cycle; the slot stays invalid then)
                if ((REN_GROUP_ACC ? snap_cand : snap_take) && snap_slot == k) begin
                    snap_rob[k]  <= snap_rob_new;
                    snap_rat[k]  <= snap_rat_new;
                    snap_hi[k]   <= snap_hi_new;
                    snap_hf[k]   <= snap_hf_new;
                end
            end
        end
    end

`ifndef SYNTHESIS
    // SNAP_SEL_OH: the old sequential choice
    always_ff @(posedge clk)
        if (rst_n && SNAP_SEL_OH && redir_q.valid) begin
            logic h;
            int sl;
            h = 1'b0; sl = 0;
            for (int k = 0; k < SNAP_N; k++)
                if (SNAP_EN && snap_v[k] &&
                    (snap_rob[k] == redir_keep || (SNAP_FWD && rob_older(snap_rob[k], redir_keep))) &&
                    (!h || rob_older(snap_rob[sl], snap_rob[k]))) begin
                    h = 1'b1; sl = k;
                end
            if (h != snap_hit || (h && (sl != snap_sel || (snap_rob[sl] == redir_keep) != snap_exact)) ||
                redir_keep1 != rob_add(redir_keep, 1))
                $error("SNAP_SEL_OH: hit %0d/%0d sel %0d/%0d", snap_hit, h, snap_sel, sl);
        end
`endif

    // =====================================================================
    // Control state: pointers, redirect, walk, load wait table
    // =====================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            redir_q <= '0;
            walking <= 1'b0;
            fwalk <= 1'b0;
            walk_target <= '0;
            rob_head <= '0; rob_tail <= '0;
            lq_head <= '0; lq_tail <= '0;
            sq_head <= '0; sq_cmt <= '0; sq_tail <= '0;
            lwt <= '0; lwt_clear_cnt <= '0;
        end else begin
            redir_q <= redir_sel;

            lwt_clear_cnt <= lwt_clear_cnt + 1'b1;
            if (lwt_clear_cnt == '1) lwt <= '0;
            else if (redir_q.valid && redir_q.flush_self) lwt[lwt_set] <= 1'b1;

            if (can_rename) begin
                rob_tail <= rob_add(rob_tail, n_acc);
                lq_tail  <= lq_add(lq_tail, n_ld_acc);
                sq_tail  <= sq_add(sq_tail, n_st_acc);
            end

            rob_head <= rob_add(rob_head, cmt_n);
            lq_head  <= lq_add(lq_head, cmt_nl);
            sq_cmt   <= sq_add(sq_cmt, cmt_ns);
            sq_head  <= sq_head_next;

            if (redir_q.valid) begin
                lq_tail     <= redir_q.lq_ptr;
                sq_tail     <= redir_q.sq_ptr;
                if (snap_hit) begin                 // RAT / free list restored from the snapshot
                    walking  <= 1'b0;
                    rob_tail <= redir_keep1;
                    fwalk    <= !snap_exact;
                    fw_ptr   <= rob_add(snap_rob[snap_sel], 1);
                    fw_end   <= redir_keep1;
                end else if (fwalk && rob_older(fw_ptr, redir_keep1)) begin
                    // during a forward walk, kept instructions not re-applied yet: walk forward up to them
                    fw_end   <= redir_keep1;
                    rob_tail <= redir_keep1;
                end else begin
                    // the RAT reflects every entry before the walk start (rob_tail, or fw_ptr during a
                    // forward walk): undo backwards from there
                    if (fwalk) rob_tail <= fw_ptr;
                    walking     <= 1'b1;
                    fwalk       <= 1'b0;
                    walk_target <= redir_q.flush_self ? redir_q.rob_idx : rob_add(redir_q.rob_idx, 1);
                end
            end else if (fwalk) begin
                fw_ptr <= fw_ptr_next;
                if (fw_ptr_next == fw_end) fwalk <= 1'b0;
            end else if (walking) begin
                rob_tail <= walk_tail_next;
                if (walk_tail_next == walk_target) walking <= 1'b0;
            end
        end
    end

    // =====================================================================
    // Zicsr (executed in ALU0's EX stage while the instruction is the ROB head)
    // =====================================================================
    logic [63:0] csr_old, csr_new, csr_src;
    logic        csr_we;
    logic [11:0] csr_addr;
    always_comb begin
        csr_addr = a_ex[0].imm[11:0];
        unique case (csr_addr)
            12'h001: csr_old = 64'(fflags);
            12'h002: csr_old = 64'(frm);
            12'h003: csr_old = 64'({frm, fflags});
            12'hc00, 12'hc01: csr_old = cycle_cnt;        // cycle, time
            12'hc02: csr_old = instret_cnt;               // instret: all older instructions committed
            default: csr_old = '0;
        endcase
        csr_src = a_ex[0].mdfn[2] ? 64'(a_ex[0].imm[16:12]) : a_src1[0];
        unique case (a_ex[0].mdfn[1:0])
            2'd1:    csr_new = csr_src;
            2'd2:    csr_new = csr_old | csr_src;
            default: csr_new = csr_old & ~csr_src;
        endcase
        // CSRRW[I] always writes; CSRRS/C[I] with rs1 = x0 / uimm = 0 only read
        csr_we = a_live[0] && a_ex[0].fu == FU_CSR && (a_ex[0].mdfn[1:0] == 2'd1 || a_ex[0].imm[16:12] != '0);
    end

    assign instret = instret_cnt;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fflags <= '0; frm <= '0; cycle_cnt <= '0; instret_cnt <= '0; csr_pend <= 1'b0;
        end else begin
            cycle_cnt   <= cycle_cnt + 1'b1;
            instret_cnt <= instret_cnt + 64'(cmt_n);
            if (csr_we && (csr_addr == 12'h001 || csr_addr == 12'h003)) fflags <= csr_new[4:0];
            else                                                         fflags <= fflags | cmt_fflags;
            if (csr_we && csr_addr == 12'h002) frm <= csr_new[2:0];
            if (csr_we && csr_addr == 12'h003) frm <= csr_new[7:5];
            // younger instructions dispatch after the CSR instruction commits
            if (can_rename && |acc && (d[n_acc - 1].fu == FU_CSR)) begin
                csr_pend <= 1'b1;
                csr_rob  <= r_uop[n_acc - 1].rob_idx;
            end else if (csr_pend && (killed_by(redir_q, csr_rob) || (cmt_n > 0 && rob_head == csr_rob))) begin
                csr_pend <= 1'b0;
            end
        end
    end

    // dispatch round-robin pointer of each unit class
    for (genvar f = 0; f < N_FU; f++) begin : g_rr
        always_ff @(posedge clk) begin
            if (!rst_n)          fu_rr[f] <= 0;
            else if (can_rename) fu_rr[f] <= (fu_rr[f] + n_cls_acc[f]) % class_n(f);
        end
    end

    // =====================================================================
    // Rename tables: speculative RAT (rename / walk), architectural RAT (commit)
    //   architectural register r: x0..x31 = 0..31, f0..f31 = 32..63
    // =====================================================================
    for (genvar r = 0; r < 64; r++) begin : g_rat
        localparam preg_t INIT = (r < 32) ? preg_t'(r) : preg_t'(INT_PRF_N + r - 32);
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                rat[r]      <= INIT;
                arch_rat[r] <= INIT;
            end else begin
                for (int i = 0; i < DEC_W; i++)
                    if (acc[i] && d[i].wen && d[i].ldst == 6'(r)) rat[r] <= r_uop[i].pdest;
                for (int j = 0; j < DEC_W; j++)   // youngest first: the oldest undo wins
                    if (walk_v[j] && rob_wen[walk_e[j]] && rob_ldst[walk_e[j]] == 6'(r)) rat[r] <= rob_old[walk_e[j]];
                for (int k = 0; k < DEC_W; k++)
                    if (cmt_v[k] && rob_wen[cmt_e[k]] && rob_ldst[cmt_e[k]] == 6'(r)) arch_rat[r] <= rob_pdest[cmt_e[k]];
                for (int q = 0; q < DEC_W; q++)   // forward walk: the youngest re-applied rename wins
                    if (fw_v[q] && fw_wen[q] && fw_ldst[q] == 6'(r)) rat[r] <= fw_pdest[q];
                if (snap_hit) rat[r] <= snap_rat[snap_sel][r];
            end
        end
    end

    // =====================================================================
    // Physical registers: busy table, free lists, register file
    // =====================================================================
    always_ff @(posedge clk) begin
        wk_vq  <= rst_n ? wk_valid : '0;
        wk_pq  <= wk_preg;
        can_vq <= rst_n ? can_v : '0;
        can_pq <= can_p;
    end
    for (genvar p = 0; p < PRF_N; p++) begin : g_preg
        logic rset;
        always_comb begin
            rset = 1'b0;
            for (int i = 0; i < DEC_W; i++)
                if (acc[i] && d[i].wen && !d[i].mv && r_uop[i].pdest == preg_t'(p)) rset = 1'b1;
        end
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                busy[p]      <= 1'b0;
                rset_q[p]    <= 1'b0;
            end else if (BUSY_DLY) begin
                // a destination renamed last cycle is not cleared by last cycle's wakeups (the direct
                // update lets the rename win)
                rset_q[p] <= rset;
                for (int k = 0; k < N_CAN; k++)
                    if (can_vq[k] && can_pq[k] == preg_t'(p)) busy[p] <= 1'b1;
                for (int k = 0; k < N_WK; k++)
                    if (wk_vq[k] && wk_pq[k] == preg_t'(p) && !rset_q[p]) busy[p] <= 1'b0;
                if (rset) busy[p] <= 1'b1;
            end else begin
                rset_q[p] <= 1'b0;
                for (int k = 0; k < N_CAN; k++)
                    if (can_v[k] && can_p[k] == preg_t'(p)) busy[p] <= 1'b1;
                for (int k = 0; k < N_WK; k++)
                    if (wk_valid[k] && wk_preg[k] == preg_t'(p)) busy[p] <= 1'b0;
                if (rset) busy[p] <= 1'b1;
            end
        end
`ifndef SYNTHESIS
        // sim check: the delayed table plus last cycle's updates equals the directly updated table
        logic busy_ref;
        always_ff @(posedge clk) begin
            if (!rst_n) busy_ref <= 1'b0;
            else begin
                for (int k = 0; k < N_CAN; k++)
                    if (can_v[k] && can_p[k] == preg_t'(p)) busy_ref <= 1'b1;
                for (int k = 0; k < N_WK; k++)
                    if (wk_valid[k] && wk_preg[k] == preg_t'(p)) busy_ref <= 1'b0;
                if (rset) busy_ref <= 1'b1;
            end
            if (rst_n && BUSY_DLY && busy_ref != (rset_q[p] || (!woken(preg_t'(p), wk_vq, wk_pq) &&
                                (busy[p] || cancelled(preg_t'(p), can_vq, can_pq)))))
                $error("BUSY_DLY: preg %0d effective busy differs from the direct table", p);
        end
`endif
        // only the writeback ports that can write this register file are connected
        if (p < INT_PRF_N) begin : g_wi
            always_ff @(posedge clk)
                for (int q = 0; q < N_WB; q++)
                    if (wb_writes_int(q) && wbw[q].v && wbw[q].wen && wbw[q].pdest == preg_t'(p)) prf_i[p] <= wbw[q].val;
        end else begin : g_wf
            always_ff @(posedge clk)
                for (int q = 0; q < N_WB; q++)
                    if (wb_writes_fp(q) && wbw[q].v && wbw[q].wen && wbw[q].pdest == preg_t'(p)) prf_f[p - INT_PRF_N] <= wbw[q].val;
        end
    end

    // =====================================================================
    // ROB entries
    // =====================================================================
    for (genvar e = 0; e < ROB_N; e++) begin : g_rob
        always_ff @(posedge clk) begin
            for (int i = 0; i < DEC_W; i++) begin
                if (acc[i] && r_uop[i].rob_idx[ROB_PW-2:0] == (ROB_PW-1)'(e)) begin
                    rob_done[e]   <= d[i].mv;
                    rob_wen[e]    <= d[i].wen;
                    rob_mv[e]     <= d[i].mv;
                    if (d[i].mv) rob_fflags[e] <= '0;     // done here: no writeback clears it
                    rob_ldst[e]   <= d[i].ldst;
                    rob_pdest[e]  <= r_uop[i].pdest;
                    rob_old[e]    <= r_old[i];
                    rob_is_ld[e]  <= (d[i].ld_type != LOAD_DISABLE);
                    rob_is_st[e]  <= (d[i].st_type != STORE_DISABLE);
                    rob_sta_f[e]  <= 1'b0;
                    rob_std_f[e]  <= 1'b0;
                    rob_is_cfi[e] <= d[i].cfi;
                    rob_cfi[e]    <= d[i].cfit;
                    rob_call[e]   <= d[i].is_call;
                    rob_rvc[e]    <= rn_f[i].rvc;
                    rob_fu[e]     <= d[i].fu;
                    rob_off[e]    <= rn_f[i].off;
`ifndef SYNTHESIS
                    rob_insn[e]   <= rn_f[i].insn;
`endif
                    rob_ftq[e]    <= rn_f[i].ftq_idx;
                end
            end
            for (int k = 0; k < N_BJU; k++) begin
                if (brw_live[k] && brw_rob[k][ROB_PW-2:0] == (ROB_PW-1)'(e)) begin
                    rob_taken[e]  <= brw_taken[k];
`ifndef SYNTHESIS
                    dbg_rob_tgt[e] <= brw_tgt[k];
`endif
                end
            end
            for (int q = 0; q < N_WB; q++)
                if (wbw[q].v && wbw[q].rob[ROB_PW-2:0] == (ROB_PW-1)'(e)) begin
                    rob_done[e]   <= 1'b1;
                    rob_fflags[e] <= wbw[q].fflags;
                end
            // a store completes when its address part (after the violation check) and, with STD_SPLIT, its
            // data part have (either order, or the same cycle)
            begin
                logic sta_now, std_now;
                sta_now = 1'b0; std_now = 1'b0;
                for (int u = 0; u < N_STU; u++)
                    if (VIOL_REG ? (sd_live[u] && sd_rob[u][ROB_PW-2:0] == (ROB_PW-1)'(e))
                                 : (c_live[u] && c_u[u].rob_idx[ROB_PW-2:0] == (ROB_PW-1)'(e))) sta_now = 1'b1;
                for (int k = 0; k < N_STD; k++)
                    if (std_live[k] && std_ex[k].rob_idx[ROB_PW-2:0] == (ROB_PW-1)'(e)) std_now = 1'b1;
                if (sta_now) rob_sta_f[e] <= 1'b1;
                if (std_now) rob_std_f[e] <= 1'b1;
                if ((sta_now || std_now) && (!STD_SPLIT || ((sta_now || rob_sta_f[e]) && (std_now || rob_std_f[e])))) begin
                    rob_done[e]   <= 1'b1;
                    rob_fflags[e] <= '0;
                end
            end
        end
    end

    // =====================================================================
    // Load queue / store queue entries
    // =====================================================================
    for (genvar q = 0; q < LQ_N; q++) begin : g_lq
        always_ff @(posedge clk) begin
            for (int i = 0; i < DEC_W; i++) begin
                if (acc[i] && d[i].ld_type != LOAD_DISABLE && r_uop[i].lq_ptr[LQ_PW-2:0] == (LQ_PW-1)'(q)) begin
                    lq_rob[q]   <= r_uop[i].rob_idx;
                    lq_exec[q]  <= 1'b0;
                    lq_off[q]   <= rn_f[i].off;
                    lq_ftq[q]   <= rn_f[i].ftq_idx;
                    lq_sqptr[q] <= r_uop[i].sq_ptr;
                end
            end
            for (int m = 0; m < N_LDU; m++) begin
                if (l_live[m] && !l_mmio[m] && l_m[m].lq_ptr[LQ_PW-2:0] == (LQ_PW-1)'(q)) begin
                    lq_exec[q] <= !l_m_rp[m];       // (a replayed load has not read yet)
                    lq_addr[q] <= l_m_addr[m];
                    lq_mask[q] <= l_mask[m];
                end
            end
        end
    end

    // =====================================================================
    // Store data pipelines (STD_SPLIT): IS -> RR (data operand) -> EX (into the SQ,
    // ROB data part done)
    // =====================================================================
    for (genvar k = 0; k < N_STD; k++) begin : g_std
        logic [63:0] rf;
        assign rf = (std_rr[k].psrc2 >= preg_t'(INT_PRF_N)) ? prf_f[std_rr[k].psrc2 - preg_t'(INT_PRF_N)]
                                                            : IRP_ARB ? irp_val(IQ_STD0 + k, 0, 2, std_rr[k].psrc2, ir_val)
                                                                      : prf_i[std_rr[k].psrc2];
        assign std_live[k] = std_ex_v[k] && !killed_by(redir_q, std_ex[k].rob_idx);
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                std_rr_v[k] <= 1'b0; std_ex_v[k] <= 1'b0;
            end else begin
                std_rr_v[k] <= iq_iss_v[IQ_STD0 + k];
                std_rr[k]   <= iq_iss[IQ_STD0 + k];
                std_ex_v[k] <= std_rr_v[k] && !killed_by(redir_q, std_rr[k].rob_idx);
                std_ex[k]   <= std_rr[k];
                std_dat[k]  <= WB_STAGE ? rr_operand(3, std_rr[k].psrc2, rf, fd_v, fd_p, fd_val, bp_v, bp_p, bp_val) : rf;
            end
        end
    end
    if (N_STD == 0) begin : g_nostd
        assign std_live[0] = 1'b0;
        always_comb begin std_ex[0] = '0; std_dat[0] = '0; end
    end

    for (genvar q = 0; q < SQ_N; q++) begin : g_sq
        always_ff @(posedge clk) begin
            for (int i = 0; i < DEC_W; i++)
                if (acc[i] && d[i].st_type != STORE_DISABLE && r_uop[i].sq_ptr[SQ_PW-2:0] == (SQ_PW-1)'(q)) begin
                    sq_addrv[q]   <= 1'b0;
                    sq_dv[q]      <= 1'b0;
                    sq_rob[q]     <= r_uop[i].rob_idx;
                    sq_ftq[q]     <= r_uop[i].ftq_idx;
                    sq_off[q]     <= r_uop[i].off;
                end
            if (!STD_SPLIT) begin
                for (int u = 0; u < N_STU; u++) begin
                    if (s_live[u] && s_ag[u].sq_ptr[SQ_PW-2:0] == (SQ_PW-1)'(q)) begin
                        sq_addrv[q] <= 1'b1;
                        sq_addr[q]  <= s_addr[u];
                        sq_data[q]  <= s_data[u];
                        sq_mask[q]  <= s_mask[u];
                    end
                end
            end else begin
                // STA writes the address, STD the raw data; the aligned data is formed by whichever comes
                // last (or both in the same cycle)
                logic a_w, d_w;
                logic [2:0]  off;
                logic [63:0] raw;
                a_w = 1'b0; d_w = 1'b0; off = sq_addr[q][2:0]; raw = sq_draw[q];
                for (int u = 0; u < N_STU; u++)
                    if (s_live[u] && s_ag[u].sq_ptr[SQ_PW-2:0] == (SQ_PW-1)'(q)) begin
                        a_w = 1'b1; off = s_addr[u][2:0];
                        sq_addrv[q] <= 1'b1;
                        sq_addr[q]  <= s_addr[u];
                        sq_mask[q]  <= s_mask[u];
                    end
                for (int k = 0; k < N_STD; k++)
                    if (std_live[k] && std_ex[k].sq_ptr[SQ_PW-2:0] == (SQ_PW-1)'(q)) begin
                        d_w = 1'b1; raw = std_dat[k];
                        sq_dv[q]   <= 1'b1;
                        sq_draw[q] <= std_dat[k];
                    end
                if ((a_w || d_w) && (a_w || sq_addrv[q]) && (d_w || sq_dv[q]))
                    sq_data[q] <= raw << {off, 3'b000};
            end
        end
    end

endmodule
