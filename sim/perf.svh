// performance counters for tb_soc (included inside module tb_soc): written to +PERF=<file>
    longint pc_cyc = 0, pc_cmt_hist [DEC_W+1], pc_ren_stall [11], pc_iqst_cls [N_FU], pc_ren_hist [DEC_W+1];
    longint pc_head_wait [N_FU], pc_rob_empty = 0, pc_cfi_limit = 0, pc_walk = 0, pc_redir_br = 0;
    longint pc_irp_req = 0, pc_irp_cancel = 0, pc_rc_hit = 0;
    // losing operands by the port that wrote the value (0: RC writer, 1: other) and its age
    longint pc_lose [2][5];
    longint lw_cyc [INT_PRF_N];
    int     lw_port [INT_PRF_N];
    initial begin
        for (int i = 0; i < 2; i++) for (int j = 0; j < 5; j++) pc_lose[i][j] = 0;
        for (int p = 0; p < INT_PRF_N; p++) begin lw_cyc[p] = 0; lw_port[p] = -1; end
    end
    longint pc_sb_enq = 0, pc_sb_merge = 0, pc_sb_evict = 0, pc_sb_full = 0;
    longint pc_fwalk = 0, pc_redir_replay = 0, pc_ffail = 0, pc_ldrep = 0, pc_ifu_redir = 0, pc_s2 = 0, pc_s3 = 0, pc_ib_empty = 0, pc_dp_stall [3];
    initial begin
        for (int i = 0; i <= DEC_W; i++) begin pc_cmt_hist[i] = 0; pc_ren_hist[i] = 0; end
        for (int i = 0; i < 11; i++) pc_ren_stall[i] = 0;
        for (int i = 0; i < N_FU; i++) pc_iqst_cls[i] = 0;
        for (int i = 0; i < 3; i++) pc_dp_stall[i] = 0;
        for (int i = 0; i < N_FU; i++) pc_head_wait[i] = 0;
    end
    always @(posedge clk) if (rst_n) begin
        automatic int nc = 0, cnt;
        pc_cyc++;
        for (int k = 0; k < DEC_W; k++) nc += int'(dut.u_core.cmt_v[k]);
        pc_cmt_hist[nc]++;
        pc_ren_hist[dut.u_core.n_acc]++;
        if (dut.u_core.n_acc < DEC_W) pc_ren_stall[dut.u_core.dbg_ren_stall]++;
        if (dut.u_core.dbg_dp_stall != 0) begin pc_iqst_cls[dut.u_core.dbg_dp_stall_fu]++; pc_dp_stall[dut.u_core.dbg_dp_stall]++; end
        cnt = rob_dist(dut.u_core.rob_head, dut.u_core.rob_tail);
        if (nc < DEC_W) begin
            automatic logic [ROB_PW-2:0] e = dut.u_core.cmt_idx[nc][ROB_PW-2:0];
            if (nc >= cnt) begin if (nc == 0) pc_rob_empty++; end
            else if (!dut.u_core.rob_done[e]) begin if (nc == 0) pc_head_wait[dut.u_core.rob_fu[e]]++; end
            else if (dut.u_core.rob_is_cfi[e]) pc_cfi_limit++;
        end
        if (dut.u_core.walking) pc_walk++;
        if (dut.u_core.fwalk) pc_fwalk++;
        if (dut.u_core.redir_q.valid && !dut.u_core.redir_q.flush_self) pc_redir_br++;
        if (dut.u_core.redir_q.valid &&  dut.u_core.redir_q.flush_self) pc_redir_replay++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.u_core.lf_q[m].valid) pc_ffail++;
        for (int m = 0; m < mm_pkg::N_LDU; m++) if (dut.u_core.l_rep[m]) pc_ldrep++;
        if (mm_pkg::SBUFFER) begin
            pc_sb_enq   += int'(dut.u_core.g_sb.enq0) + int'(dut.u_core.g_sb.enq1);
            pc_sb_merge += int'(dut.u_core.g_sb.enq0 && dut.u_core.g_sb.m0 != '0) +
                           int'(dut.u_core.g_sb.enq1 && (dut.u_core.g_sb.m1 != '0 || dut.u_core.g_sb.same01));
            pc_sb_evict += int'(dut.u_core.g_sb.ev);
            if (dut.u_core.g_sb.ncmt > 0 && !dut.u_core.g_sb.enq0 && !dut.u_core.g_sb.mmio_w) pc_sb_full++;
        end
        if (dut.u_core.fe.ifu_fire && dut.u_core.fe.ifu_redir) pc_ifu_redir++;
        if (dut.u_core.fe.s2_override && !dut.u_core.fe.s3_override) pc_s2++;
        if (dut.u_core.fe.s3_override) pc_s3++;
        if (!dut.u_core.ib_valid[0]) pc_ib_empty++;
        for (int q = 0; q < N_WB; q++)
            if (wb_writes_int(q) && dut.u_core.wbw[q].v && dut.u_core.wbw[q].wen && dut.u_core.wbw[q].pdest < INT_PRF_N) begin
                lw_cyc[dut.u_core.wbw[q].pdest] = pc_cyc;
                lw_port[dut.u_core.wbw[q].pdest] = q;
            end
        for (int q = 0; q < N_IQ; q++)
            for (int d = 0; d < 2; d++) begin
                automatic logic sv = (d == 0) ? dut.u_core.iq_sel_v[q] : dut.u_core.iq_sel2_v[q];
                automatic logic ok = (d == 0) ? dut.u_core.iq_ok[q] : dut.u_core.iq_ok2[q];
                if (sv && !ok) pc_irp_cancel++;
                for (int src = 1; src <= 2; src++) begin
                    if (dut.u_core.irp_rq[q][d][src]) pc_irp_req++;
                    if (dut.u_core.irp_rq[q][d][src] && dut.u_core.irp_lose[q][d][src]) begin
                        automatic int a = int'(dut.u_core.irp_a[q][d][src]);
                        automatic longint age = pc_cyc - lw_cyc[a];
                        automatic int w = (lw_port[a] >= 0 && dut.u_core.rc_wb(lw_port[a])) ? 0 : 1;
                        pc_lose[w][age < 4 ? 0 : age < 16 ? 1 : age < 64 ? 2 : age < 256 ? 3 : 4]++;
                    end
                    if (sv && dut.u_core.rc_use[q][d][src]) pc_rc_hit++;
                end
            end
    end
    string fu_name [N_FU] = '{"ALU", "BJU", "LDU", "STU", "MUL", "DIV", "I2F", "FMAC", "FCVT", "FDIV", "CSR"};
    string stall_name [11] = '{"none", "ibuf_empty", "redirect_walk", "csr", "rob_full", "int_preg", "fp_preg", "lq_full", "sq_full", "dispatch_busy", "unused"};
    task automatic perf_dump(string fn);
        integer fd;
        fd = $fopen(fn, "w");
        $fdisplay(fd, "cycles %0d", pc_cyc);
        for (int i = 0; i <= DEC_W; i++) $fdisplay(fd, "commit_%0d %0d", i, pc_cmt_hist[i]);
        for (int i = 0; i <= DEC_W; i++) $fdisplay(fd, "rename_%0d %0d", i, pc_ren_hist[i]);
        $fdisplay(fd, "commit0_rob_empty %0d", pc_rob_empty);
        for (int i = 0; i < N_FU; i++) $fdisplay(fd, "commit0_head_wait_%s %0d", fu_name[i], pc_head_wait[i]);
        $fdisplay(fd, "commit_cfi_limit %0d", pc_cfi_limit);
        for (int i = 0; i < 11; i++) $fdisplay(fd, "rename_stall_%s %0d", stall_name[i], pc_ren_stall[i]);
        $fdisplay(fd, "dispatch_stall_iq_full %0d", pc_dp_stall[1]);
        $fdisplay(fd, "dispatch_stall_iq_enq_port %0d", pc_dp_stall[2]);
        for (int i = 0; i < N_FU; i++) $fdisplay(fd, "iq_stall_class_%s %0d", fu_name[i], pc_iqst_cls[i]);
        $fdisplay(fd, "walk_cycles %0d", pc_walk);
        $fdisplay(fd, "forward_walk_cycles %0d", pc_fwalk);
        $fdisplay(fd, "branch_redirects %0d", pc_redir_br);
        $fdisplay(fd, "replay_redirects %0d", pc_redir_replay);
        $fdisplay(fd, "forward_fails %0d", pc_ffail);
        $fdisplay(fd, "load_replays %0d", pc_ldrep);
        $fdisplay(fd, "sbuffer_stores %0d merged %0d line_writes %0d sq_head_blocked %0d", pc_sb_enq, pc_sb_merge, pc_sb_evict, pc_sb_full);
        $fdisplay(fd, "ifu_redirects %0d", pc_ifu_redir);
        $fdisplay(fd, "s2_override %0d", pc_s2);
        $fdisplay(fd, "s3_override %0d", pc_s3);
        $fdisplay(fd, "int_read_port_requests %0d", pc_irp_req);
        $fdisplay(fd, "int_read_port_cancels %0d", pc_irp_cancel);
        $fdisplay(fd, "regcache_hits %0d", pc_rc_hit);
        for (int i = 0; i < 2; i++)
            $fdisplay(fd, "port_lose_%s_age <4 %0d <16 %0d <64 %0d <256 %0d more %0d", i ? "other" : "rcwriter",
                      pc_lose[i][0], pc_lose[i][1], pc_lose[i][2], pc_lose[i][3], pc_lose[i][4]);
        $fclose(fd);
    endtask
