// timescale set by simulator
module tb;
    import mm_pkg::*;
    logic clk = 0, rst_n = 0;
    logic [N_WK-1:0] dbg_v;
    logic [N_WK-1:0][63:0] dbg_val;
    // random-program test bench: core + a 2 KiB data RAM aliased over the whole address space
    logic [N_LDU-1:0][63:0] dm_raddr, dm_raddr_n, dm_rdata;
    logic [1:0]             dm_we;
    logic [1:0][63:0]       dm_waddr, dm_wdata;
    logic [1:0][7:0]        dm_wmask;
    logic                   io_re;
    logic [63:0]            io_raddr;
    mm_core dut (.clk(clk), .rst_n(rst_n), .imem_wr_en(1'b0), .imem_wr_addr('0), .imem_wr_data(32'd0),
                 .dm_raddr, .dm_raddr_n, .dm_rdata, .dm_we, .dm_waddr, .dm_wdata, .dm_wmask,
                 .io_re, .io_raddr, .io_rdata(64'd0), .instret(),
                 .dbg_wb_valid(dbg_v), .dbg_wb_value(dbg_val));
    mm_dmem #(.WORDS(256)) u_dmem (.clk, .raddr_n(dm_raddr_n), .raddr(dm_raddr), .rdata(dm_rdata),
                                   .we(dm_we), .waddr(dm_waddr), .wdata(dm_wdata), .wmask(dm_wmask));
    always #5 clk = ~clk;

    localparam logic [31:0] HALT = 32'h0000006f;
    integer i, fd, tfd, ncyc, cyc = 0, halt_cyc = -1, ncommit = 0;

    // event counters (coverage of the speculative mechanisms)
    integer n_s3ovr = 0, n_s2ovr = 0, n_wrapfwd = 0, n_br_redir = 0, n_viol = 0, n_ifu_redir = 0, n_walk = 0, n_fwd = 0, n_dual_bju = 0, n_ffail = 0, n_ldrep = 0, n_ffull = 0, n_funp = 0, n_rawin = 0, n_rawrep = 0;
    integer n_div = 0, n_div_kill = 0, n_fdiv = 0, n_fdiv_kill = 0, n_wbb_stall = 0;
    integer n_rvc = 0, n_skip = 0, n_csr = 0, n_fflags_cmt = 0;
    always @(posedge clk) if (rst_n) begin
        if (dut.fe.ifu_fire && dut.fe.ifu_skip) n_skip++;          // block started inside an instruction
        if (dut.a_live[0] && dut.a_ex[0].fu == FU_CSR) n_csr++;
        if (dut.cmt_fflags != 0) n_fflags_cmt++;
        for (int k = 0; k < DEC_W; k++) if (dut.cmt_v[k] && dut.rob_rvc[dut.cmt_idx[k][ROB_PW-2:0]]) n_rvc++;
        if (dut.g_alu[DIV_IQ].g_div.dv_start) n_div++;
        if (dut.g_alu[DIV_IQ].g_div.dv_kill) n_div_kill++;
        if (dut.g_fex[1].g_fdiv.fd_start) n_fdiv++;
        if (dut.g_fex[1].g_fdiv.fd_kill) n_fdiv_kill++;
        if (dut.redir_q.valid && !dut.redir_q.flush_self) n_br_redir++;
        if (dut.redir_q.valid &&  dut.redir_q.flush_self) n_viol++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.lf_q[m].valid) n_ffail++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.l_rep[m]) n_ldrep++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.l_live[m] && !dut.l_mmio[m] && dut.l_m_pff[m] && dut.lrq_full[m]) n_ffull++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.l_live[m] && !dut.l_mmio[m] && !dut.l_m_pff[m] && dut.l_ffail[m]) n_funp++;   // (STD_SPLIT forward fails, before redirect selection)
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.rw_in[m]) n_rawin++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.l_live[m] && !dut.l_mmio[m] && dut.l_m_prw[m]) n_rawrep++;
        if (dut.fe.ifu_fire && dut.fe.ifu_redir) n_ifu_redir++;
        if (dut.walking) n_walk++;
        if (dut.fe.s2_override && !dut.fe.s3_override) n_s2ovr++;
        if (dut.fe.s3_override) n_s3ovr++;
        if (dut.br_live[0] && dut.br_live[1]) n_dual_bju++;
        // forwarding where >=2 older stores overlap the load and the SQ wraps between them
        for (int m = 0; m < N_LDU; m++) if (dut.l_live[m]) begin
            automatic int n_older = int'(sq_ptr_t'(dut.l_m[m].sq_ptr - dut.sq_head));
            automatic int nmatch = 0;
            automatic logic wrapped = 0;
            for (int a = 0; a < n_older; a++) begin
                automatic int idx = (int'(dut.sq_head[SQ_PW-2:0]) + a) % SQ_N;
                if (dut.sq_addrv[idx] && dut.sq_addr[idx][10:3] == dut.l_m_addr[m][10:3] &&
                    (dut.sq_mask[idx] & dut.l_mask[m]) != 0) begin
                    nmatch++;
                    if (nmatch >= 2 && idx == 0) wrapped = 1;
                end
            end
            if (nmatch >= 2) n_fwd++;
            if (wrapped) n_wrapfwd++;
        end
    end

    // a ready uop held back only because its unit's write port is reserved
    for (genvar k = 0; k < N_IQ; k++) begin : g_wbbst
        always @(posedge clk) if (rst_n && dut.g_iq[k].iq.wbb_stall && !dut.iq_iss_v[k]) n_wbb_stall++;
    end

    // commit trace (architectural register writes, in program order)
    always @(posedge clk) if (rst_n) begin
        cyc <= cyc + 1;
        for (int k = 0; k < DEC_W; k++) begin
            if (dut.cmt_v[k]) begin
                automatic logic [ROB_PW-2:0] e = dut.cmt_idx[k][ROB_PW-2:0];
                ncommit = ncommit + 1;
                if (dut.rob_wen[e])
                    $fdisplay(tfd, "%s%0d %016x", dut.rob_ldst[e][5] ? "f" : "x", dut.rob_ldst[e][4:0], dut.prf[dut.rob_pdest[e]]);
                if (dut.rob_insn[e] == HALT && halt_cyc < 0) halt_cyc = cyc;
            end
        end
    end

    initial begin
        for (i = 0; i < IMEM_WORDS; i++) dut.fe.u_imem.mem[i] = 32'h13;
        for (i = 0; i < 256; i++) u_dmem.mem[i] = 0;
        for (i = 0; i < INT_PRF_N; i++) dut.prf_i[i] = 0;
        for (i = 0; i < FP_PRF_N; i++) dut.prf_f[i] = 0;
        $readmemh("prog.hex", dut.fe.u_imem.mem);
        $readmemh("dmem.hex", u_dmem.mem);
        if (!$value$plusargs("CYC=%d", ncyc)) ncyc = 3000;
        tfd = $fopen("rtl_trace.txt", "w");
        repeat (2) @(posedge clk);
        dut.fe.u_imem.sim_load = 1'b1;          // copy the images into the memory banks
        u_dmem.sim_load = 1'b1;
        #1 rst_n = 1;
        repeat (ncyc) @(posedge clk);
        #1;
        $fclose(tfd);
        fd = $fopen("rtl_out.txt", "w");
        for (i = 1; i < 32; i++) $fdisplay(fd, "x%0d %016x", i, dut.prf[dut.arch_rat[i]]);
        for (i = 0; i < 32; i++) $fdisplay(fd, "f%0d %016x", i, dut.prf[dut.arch_rat[32 + i]]);
        // stores still in the committed-store buffer (SBUFFER) are part of the final memory
        // (a line being written out first, a newer entry for the same line over it)
        if (mm_pkg::SBUFFER)
            for (int e = 0; e < 2 * mm_pkg::SB_N; e++)
                if (dut.sb_v[e % mm_pkg::SB_N] && dut.sb_infl[e % mm_pkg::SB_N] == (e < mm_pkg::SB_N))
                    for (int b = 0; b < 16; b++)
                        if (dut.sb_mask[e % mm_pkg::SB_N][b])
                            u_dmem.mem[{dut.sb_tag[e % mm_pkg::SB_N], b[3]} % 256][8 * (b % 8) +: 8] = dut.sb_data[e % mm_pkg::SB_N][8 * b +: 8];
        for (i = 0; i < 256; i++) $fdisplay(fd, "m%0d %016x", i, u_dmem.mem[i]);
        $fdisplay(fd, "fflags %02x\nfrm %0x", dut.fflags, dut.frm);
        $fclose(fd);
        fd = $fopen("stats.txt", "w");
        $fdisplay(fd, "br_redirect %0d viol_replay %0d ifu_redirect %0d walk_cycles %0d dual_bju %0d multi_fwd %0d wrap_fwd %0d s2_override %0d s3_override %0d div %0d div_kill %0d fdiv1 %0d fdiv1_kill %0d wbport_stall %0d rvc_commit %0d straddle_fetch %0d csr_exec %0d fflags_commit %0d fwd_fail %0d ld_replay %0d ffail_full %0d ffail_unpred %0d raw_enq %0d raw_replay %0d",
                  n_br_redir, n_viol, n_ifu_redir, n_walk, n_dual_bju, n_fwd, n_wrapfwd, n_s2ovr, n_s3ovr, n_div, n_div_kill, n_fdiv, n_fdiv_kill, n_wbb_stall, n_rvc, n_skip, n_csr, n_fflags_cmt, n_ffail, n_ldrep, n_ffull, n_funp, n_rawin, n_rawrep);
        $fclose(fd);
        fd = $fopen("cycles.txt", "w"); $fdisplay(fd, "%0d", halt_cyc); $fclose(fd);
        $finish;
    end
endmodule
