// Delayed writeback and wakeup for one execution-unit pipeline (IS | RR | EX1 | EX2 | ...).
// A uop with fixed latency L (uop.lat) computes its result in EX1 and writes the register file
// at the end of EX_L (= issue + 1 + L). The issue queue reserves the unit's single write port
// for that cycle (write ports are scheduled at issue), so at most one result leaves
// this pipe per cycle. Consumers are woken 2 cycles before the write (issue + L - 1), so that a
// dependent uop issued the next cycle takes the value from the bypass network at its register read
// (WB_STAGE: forwarded from this port in the write cycle; else from the EX-stage bypass).
// Every pipe entry is dropped when a redirect kills it.
// A "late" uop (pipelined unit, e.g. the FMA) has no value in EX1: its value and flags are taken
// from late_val / late_flags in the write cycle.
module mm_wbpipe
    import mm_pkg::*;
#(
    parameter bit L1 = 1'b1     // the unit has latency-1 uops (0: no wakeup at issue, no EX1 write)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  redirect_t   redir,
    input  logic        iss_v,      // issued this cycle (SPEC_WAKE: selected, before the read-port arbitration)
    input  logic        iss_l1,     // IQ_WK_FAST: iss_v && latency 1 && writes a register (from the issue queue)
    input  uop_t        iss,
    input  logic        rr_v,       // live uop in RR (SPEC_WAKE: latency >= 2 wakeups are scheduled here)
    input  uop_t        rr,
    input  logic        ex_v,       // live uop in EX1
    input  uop_t        ex,
    input  logic [63:0] ex_val,
    input  logic [63:0] ex_val1,    // value of a latency-1 uop (only the units with latency 1, so the
                                    // longer units' EX1 logic stays off the forward path)
    input  logic [4:0]  ex_flags,
    input  logic        ex_late,    // the EX1 uop's value comes from late_val in its write cycle
    input  logic [63:0] late_val,
    input  logic [4:0]  late_flags,
    output wb_t         port,
    output logic        wk_v,
    output preg_t       wk_p
);
    wb_t [MAXL-2:0] wp;     // wp[j]: written j+1 cycles from now
    wb_t [MAXL-2:0] wkp;    // wkp[j]: wakeup j+1 cycles from now
    logic [MAXL-2:0] wl;    // wp[j] is a late entry

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wp  <= '0;
            wkp <= '0;
            wl  <= '0;
        end else begin
            for (int j = 0; j < MAXL - 2; j++) begin
                wp[j]    <= wp[j+1];
                wp[j].v  <= wp[j+1].v && !killed_by(redir, wp[j+1].rob);
                wl[j]    <= wl[j+1];
                wkp[j]   <= wkp[j+1];
                wkp[j].v <= wkp[j+1].v && !killed_by(redir, wkp[j+1].rob);
            end
            wp[MAXL-2].v  <= 1'b0;
            wkp[MAXL-2].v <= 1'b0;
            if (ex_v && ex.lat >= 3'd2) begin
                wp[ex.lat - 3'd2].v     <= 1'b1;
                wp[ex.lat - 3'd2].wen   <= ex.rf_wen;
                wp[ex.lat - 3'd2].pdest <= ex.pdest;
                wp[ex.lat - 3'd2].rob   <= ex.rob_idx;
                wp[ex.lat - 3'd2].val   <= ex_val;
                wp[ex.lat - 3'd2].fflags <= ex_flags;
                wl[ex.lat - 3'd2]       <= ex_late;
            end
            if (!SPEC_WAKE && iss_v && iss.lat >= 3'd2 && iss.rf_wen) begin
                wkp[iss.lat - 3'd2].v     <= 1'b1;
                wkp[iss.lat - 3'd2].pdest <= iss.pdest;
                wkp[iss.lat - 3'd2].rob   <= iss.rob_idx;
            end
            if (SPEC_WAKE && rr_v && rr.lat >= 3'd3 && rr.rf_wen) begin
                wkp[rr.lat - 3'd3].v     <= 1'b1;
                wkp[rr.lat - 3'd3].pdest <= rr.pdest;
                wkp[rr.lat - 3'd3].rob   <= rr.rob_idx;
            end
        end
    end

    always_comb begin
        if (L1 && ex_v && ex.lat == 3'd1) begin
            port.v = 1'b1; port.wen = ex.rf_wen; port.pdest = ex.pdest; port.rob = ex.rob_idx; port.val = ex_val1;
            port.fflags = ex_flags;
        end else begin
            port   = wp[0];
            port.v = wp[0].v && !killed_by(redir, wp[0].rob);
            if (wl[0]) begin port.val = late_val; port.fflags = late_flags; end
        end
        if (L1 && (IQ_WK_FAST ? iss_l1 : iss_v && iss.lat == 3'd1 && iss.rf_wen)) begin
            wk_v = 1'b1; wk_p = iss.pdest;
        end else if (SPEC_WAKE && rr_v && rr.lat == 3'd2 && rr.rf_wen) begin
            wk_v = !killed_by(redir, rr.rob_idx); wk_p = rr.pdest;
        end else begin
            wk_v = wkp[0].v && !killed_by(redir, wkp[0].rob);
            wk_p = wkp[0].pdest;
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk)
        if (rst_n && !L1 && (iss_v && iss.lat == 3'd1 || ex_v && ex.lat == 3'd1))
            $error("mm_wbpipe: latency-1 uop in a pipe built without L1");
`endif
endmodule
