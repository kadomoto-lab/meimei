// Simulation top for mm_soc: runs a bare-metal program image
//   +CODE=<code.hex>   instruction SRAM image (32-bit words from 0x8000_0000)
//   +DATA=<data.hex>   data SRAM image (64-bit words from 0x8001_0000)
//   +MAXCYC=<n>        timeout (default 50,000,000 cycles)
//   +TRACE=<file>      commit trace for lockstep checking against the ISS (sim/rvsim.py)
//   +UART=<file>       copy of the UART output (default uart.log)
//   +STATS=<file>      run summary (default sim_result.txt)
//   +PERF=<file>       performance counters (commit / rename stall breakdown, redirects ...)
// The run ends when the program writes the EXIT register; the exit code is reported.
module tb_soc;
    import mm_pkg::*;
    import mm_soc_pkg::*;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic        tx_v, exit_v;
    logic [7:0]  tx_d;
    logic [31:0] exit_c;
    logic [63:0] gpo;
    mm_soc dut (.clk, .rst_n, .uart_tx_valid(tx_v), .uart_tx_data(tx_d), .uart_tx_ready(1'b1), .uart_rx_push(1'b0), .uart_rx_data(8'd0),
                .gpio_in(32'd0), .gpio_out(gpo), .exit_valid(exit_v), .exit_code(exit_c), .mtime_o(),
                .host_imem_we(1'b0), .host_imem_addr('0), .host_imem_data('0),
                .host_dmem_we(1'b0), .host_dmem_waddr('0), .host_dmem_wdata('0), .host_dmem_wmask('0));

    string code_f, data_f, trace_f, uart_f, stats_f, perf_f;
`include "perf.svh"
    longint maxcyc, cyc = 0;
    integer tfd = 0, ufd;
    logic tracing = 0;

    // commit trace: "<pc> <insn>" and, if a register is written, " x<n>|f<n> <value>"
    always @(posedge clk) if (rst_n && tracing) begin
        for (int k = 0; k < DEC_W; k++) begin
            if (dut.u_core.cmt_v[k]) begin
                automatic logic [ROB_PW-2:0] e = dut.u_core.cmt_idx[k][ROB_PW-2:0];
                if (dut.u_core.rob_wen[e])
                    $fdisplay(tfd, "%016x %s%0d %016x", dut.u_core.dbg_cmt_pc[k], dut.u_core.rob_ldst[e][5] ? "f" : "x",
                              dut.u_core.rob_ldst[e][4:0], dut.u_core.prf[dut.u_core.rob_pdest[e]]);
                else
                    $fdisplay(tfd, "%016x", dut.u_core.dbg_cmt_pc[k]);
            end
        end
    end

    always @(posedge clk) if (rst_n) begin
        cyc <= cyc + 1;
        if (tx_v) begin
            $write("%c", tx_d); $fflush();
            $fwrite(ufd, "%c", tx_d); $fflush(ufd);
        end
        if (exit_v) finish(exit_c, 0);
        if (cyc >= maxcyc) finish(32'hffffffff, 1);
    end

    task automatic finish(input logic [31:0] code, input bit timeout);
        integer fd;
        longint ins;
        ins = dut.u_core.instret_cnt;
        fd = $fopen(stats_f, "w");
        $fdisplay(fd, "exit %0d timeout %0d cycles %0d instret %0d", $signed(code), timeout, cyc, ins);
        $fclose(fd);
        $display("\n[tb_soc] %s code %0d : %0d cycles, %0d instructions, IPC %0.3f",
                 timeout ? "TIMEOUT" : "EXIT", $signed(code), cyc, ins, real'(ins) / real'(cyc));
        if (tfd) $fclose(tfd);
        $fclose(ufd);
        if (perf_f != "") perf_dump(perf_f);
        $finish;
    endtask

    initial begin
        if (!$value$plusargs("CODE=%s", code_f)) code_f = "code.hex";
        if (!$value$plusargs("DATA=%s", data_f)) data_f = "data.hex";
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 50000000;
        if (!$value$plusargs("UART=%s", uart_f)) uart_f = "uart.log";
        if (!$value$plusargs("STATS=%s", stats_f)) stats_f = "sim_result.txt";
        if (!$value$plusargs("PERF=%s", perf_f)) perf_f = "";
        if ($value$plusargs("TRACE=%s", trace_f)) begin tfd = $fopen(trace_f, "w"); tracing = 1; end
        ufd = $fopen(uart_f, "w");
        for (int i = 0; i < IMEM_WORDS; i++) dut.u_core.fe.u_imem.mem[i] = 32'h0000_0013;
        for (int i = 0; i < DMEM_WORDS; i++) dut.u_dmem.mem[i] = '0;
        for (int i = 0; i < INT_PRF_N; i++) dut.u_core.prf_i[i] = '0;
        for (int i = 0; i < FP_PRF_N; i++) dut.u_core.prf_f[i] = '0;
        $readmemh(code_f, dut.u_core.fe.u_imem.mem);
        $readmemh(data_f, dut.u_dmem.mem);
        repeat (2) @(posedge clk);
        dut.u_core.fe.u_imem.sim_load = 1'b1;   // copy the images into the memory banks
        dut.u_dmem.sim_load = 1'b1;
        #1 rst_n = 1;
    end
endmodule
