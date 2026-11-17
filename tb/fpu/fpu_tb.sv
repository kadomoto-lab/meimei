// FPU unit test: applies vectors from fpu_vec.py to fp_fma_unit / fp_misc / fp_i2f / fp_divsqrt
module fpu_tb;
    import mm_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [4:0] op; logic fmt; logic [2:0] rm; logic [1:0] it;
    logic [63:0] a, b, c, x, exp_r, r_fma, r_misc, r_i2f, r_div, got;
    logic [4:0] exp_f, f_fma, f_misc, f_i2f, f_div, gotf;
    logic start, busy, done;
    logic ps = 0, pa = 0;
    logic [63:0] r_pipe; logic [4:0] f_pipe;
    integer pbad = 0;
    fp_fma_unit_pipe u_pipe (.clk, .fma_start(ps), .add_mode(pa), .fop(fop_t'(op)), .fmt, .rm, .a, .b, .c,
                             .res(r_pipe), .flags(f_pipe));
    fp_fma_unit u_fma (.fop(fop_t'(op)), .fmt, .rm, .a, .b, .c, .res(r_fma), .flags(f_fma));
    fp_mu_t mu;
    logic [63:0] r_cvt; logic [4:0] f_cvt;
    integer cbad = 0;
    fp_misc_unpack u_mu (.a, .b, .u(mu));
    fp_cvt_pipe u_cvtp (.clk, .fop(fop_t'(op)), .fmt, .rm, .ityp(it), .a, .b, .u(mu), .u1(mu), .fmt1(fmt), .res(r_cvt), .flags(f_cvt));
    fp_misc     u_misc (.fop(fop_t'(op)), .fmt, .rm, .ityp(it), .a, .b, .res(r_misc), .flags(f_misc));
    fp_i2f      u_i2f (.fop(fop_t'(op)), .fmt, .rm, .ityp(it), .x, .res(r_i2f), .flags(f_i2f));
    logic [63:0] r_i2fp; logic [4:0] f_i2fp;
    integer ibad = 0;
    fp_i2f_pipe u_i2fp (.clk, .fop(fop_t'(op)), .fmt, .rm, .ityp(it), .x, .res(r_i2fp), .flags(f_i2fp));
    fp_divsqrt #(.U(FDIV_U)) u_div (.clk, .rst_n, .start, .kill(1'b0), .is_sqrt(fop_t'(op) == FOP_SQRT), .fmt, .rm,
                     .a, .b, .busy, .done, .res(r_div), .flags(f_div));
    // FDIV / FSQRT with the overlapped engine: all division vectors back to back, a start whenever one is taken
    logic        o_start = 0, o_sq, o_fmt, o_busy, o_post, o_acc2, o_done;
    logic [2:0]  o_rm;
    logic [63:0] o_a, o_b, o_r;
    logic [4:0]  o_f;
    integer      obad = 0;
    fp_divsqrt #(.U(FDIV_U), .OVL(1'b1)) u_dov (.clk, .rst_n, .start(o_start), .kill(1'b0), .is_sqrt(o_sq), .fmt(o_fmt),
                     .rm(o_rm), .a(o_a), .b(o_b), .busy(o_busy), .post(o_post), .acc2(o_acc2), .done(o_done), .res(o_r), .flags(o_f));
    typedef struct { logic sq, fmt; logic [2:0] rm; logic [63:0] a, b, r; logic [4:0] f; } dv_t;
    dv_t dq[$];
    integer fd, n = 0, bad = 0, cnt[32], badc[32];
    initial begin
        for (int i = 0; i < 32; i++) begin cnt[i] = 0; badc[i] = 0; end
        start = 0;
        fd = $fopen("vectors.txt", "r");
        repeat (2) @(posedge clk);
        rst_n = 1;
        while ($fscanf(fd, "%h %h %h %h %h %h %h %h %h %h", op, fmt, rm, it, a, b, c, x, exp_r, exp_f) == 10) begin
            if (fop_t'(op) == FOP_DIV || fop_t'(op) == FOP_SQRT) begin
                @(negedge clk) start = 1;
                @(negedge clk) start = 0;
                while (!done) @(negedge clk);
                got = r_div; gotf = f_div;
                dq.push_back('{fop_t'(op) == FOP_SQRT, fmt, rm, a, b, exp_r, exp_f});
            end else begin
                #1;
                if (op <= FOP_NMADD) begin
                    got = r_fma; gotf = f_fma;
                    // pipelined unit: FADD/FSUB after 1 clock edge, the others after 2 (FMA4: 3)
                    @(negedge clk);
                    pa = (fop_t'(op) == FOP_ADD || fop_t'(op) == FOP_SUB); ps = !pa;
                    @(negedge clk);
                    ps = 0;
                    if (!pa) @(negedge clk);
                    if (!pa && FMA4) @(negedge clk);
                    pa = 0;
                    if (r_pipe !== exp_r || f_pipe !== exp_f) begin
                        pbad++;
                        if (pbad <= 10) $display("MISMATCH pipe %s fmt %0d rm %0d a %h b %h c %h exp %h/%h got %h/%h",
                                                 fop_t'(op), fmt, rm, a, b, c, exp_r, exp_f, r_pipe, f_pipe);
                    end
                end
                else if (fop_t'(op) == FOP_MVFX || fop_t'(op) == FOP_I2F) begin
                    got = r_i2f; gotf = f_i2f;
                    // pipelined I2F: result one clock edge after its EX1 inputs
                    @(posedge clk); #1;
                    if (r_i2fp !== exp_r || f_i2fp !== exp_f) begin
                        ibad++;
                        if (ibad <= 10) $display("MISMATCH i2fpipe %s fmt %0d rm %0d it %0d x %h exp %h/%h got %h/%h",
                                                 fop_t'(op), fmt, rm, it, x, exp_r, exp_f, r_i2fp, f_i2fp);
                    end
                end
                else begin
                    got = r_misc; gotf = f_misc;
                    // FCVT core: result one clock edge after its EX2 inputs; the EX1 set-up registers (u1) take one
                    // more edge (inputs are held, so u1 = u)
                    @(posedge clk); @(posedge clk); #1;
                    if (r_cvt !== exp_r || f_cvt !== exp_f) begin
                        cbad++;
                        if (cbad <= 10) $display("MISMATCH cvtpipe %s fmt %0d rm %0d it %0d a %h b %h exp %h/%h got %h/%h",
                                                 fop_t'(op), fmt, rm, it, a, b, exp_r, exp_f, r_cvt, f_cvt);
                    end
                end
            end
            n++; cnt[op]++;
            if (got !== exp_r || gotf !== exp_f) begin
                bad++; badc[op]++;
                if (bad <= 30) $display("MISMATCH %s fmt %0d rm %0d it %0d a %h b %h c %h x %h exp %h/%h got %h/%h",
                                        fop_t'(op), fmt, rm, it, a, b, c, x, exp_r, exp_f, got, gotf);
            end
        end
        // overlapped FDIV: start when the engine is idle or hands over (post); results come back in order
        begin
            integer ni = 0, no = 0, cyc = 0;
            while (no < dq.size() && cyc < 100 * dq.size() + 100) begin
                @(negedge clk);
                if (o_done) begin
                    if (o_r !== dq[no].r || o_f !== dq[no].f) begin
                        obad++;
                        if (obad <= 10) $display("MISMATCH overlapped %s fmt %0d rm %0d a %h b %h exp %h/%h got %h/%h",
                                                 dq[no].sq ? "SQRT" : "DIV", dq[no].fmt, dq[no].rm, dq[no].a, dq[no].b,
                                                 dq[no].r, dq[no].f, o_r, o_f);
                    end
                    no++;
                end
                o_start = 0;
                if (ni < dq.size() && (!o_busy || o_post)) begin
                    o_start = 1; o_sq = dq[ni].sq; o_fmt = dq[ni].fmt; o_rm = dq[ni].rm; o_a = dq[ni].a; o_b = dq[ni].b;
                    ni++;
                end
                cyc++;
            end
            if (no < dq.size()) begin obad++; $display("overlapped FDIV: %0d of %0d results", no, dq.size()); end
            $display("overlapped FDIV: %0d mismatches (%0d operations, %0d cycles)", obad, dq.size(), cyc);
        end
        for (int i = 0; i < 23; i++) if (cnt[i] > 0) $display("  %-10s %6d tests %5d bad", fop_t'(i), cnt[i], badc[i]);
        bad += pbad + cbad + ibad + obad;
        $display("pipelined I2F: %0d mismatches", ibad);
        $display("pipelined FCVT: %0d mismatches", cbad);
        $display("pipelined FMA: %0d mismatches", pbad);
        $display("%0d/%0d FPU vectors passed", n - bad, n);
        $finish;
    end
endmodule
