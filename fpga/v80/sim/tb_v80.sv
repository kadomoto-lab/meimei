// Testbench for mm_v80_top: an AXI4-Lite host master loads the image over the load port, starts
// the core, drains the UART FIFO and checks the EXIT store -- i.e. the exact path the V80 host
// loader (fpga/v80/load_coremark.py) uses, without the QDMA driver.
//
//   +CODE=<code.hex> +DATA=<data.hex>   IMEM words / DMEM 64-bit words (elf2hex.py output)
//   +MAXCYC=<n>                         give up after n SoC cycles (MTIME)
//   +UART=<file>                        also write the console output to this file
`timescale 1ns / 1ps
module tb_v80;
    import mm_pkg::*;
    import mm_soc_pkg::*;

    localparam logic [63:0] BASE = 64'h0201_0010_0000;
    localparam int CYCLES_PER_NS = 10;   // 100 MHz

    logic s_axi_aclk = 1'b0;
    always #5 s_axi_aclk = ~s_axi_aclk;                  // 100 MHz

    logic        s_axi_aresetn, cpu_rst_n;
    logic [63:0] awaddr, araddr;
    logic [2:0]  awprot, arprot;
    logic        awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready;
    logic [31:0] wdata, rdata;
    logic [3:0]  wstrb;
    logic [1:0]  bresp, rresp;

    mm_v80_top #() u_top (
        .s_axi_aclk, .s_axi_aresetn, .cpu_clk(s_axi_aclk), .cpu_rst_n,
        .s_axi_awaddr(awaddr), .s_axi_awprot(awprot), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(arprot), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    // ------------------------------------------------------------------ AXI4-Lite master
    // The ready/valid levels are combinational from DUT flops, so they must be sampled *settled*
    // (a few ns after the edge) and the request must stay valid through the edge on which the
    // handshake completes -- otherwise a ready that was high for exactly one cycle is missed and
    // the transfer deadlocks. Hence the #2 waits below (clock period is 10 ns).
    // A transfer is detected from the *response* (bvalid / rvalid), not from the ready level:
    // awready is a level that may already have dropped by the time the model settles after the
    // edge on which the slave consumed the request, so polling it from a TB races and deadlocks.
    // Requests are held until the response shows up, then dropped 2 ns after the response edge.
    task automatic axw(input logic [63:0] a, input logic [31:0] d, input logic [3:0] s);
        begin
            @(negedge s_axi_aclk);
            awaddr <= a; awprot <= '0; awvalid <= 1'b1;
            wdata  <= d; wstrb  <= s;  wvalid  <= 1'b1;
            bready <= 1'b1;
            begin : w_wait
                logic got;
                got = 1'b0;
                while (!got) begin
                    @(posedge s_axi_aclk); #2;
                    got = bvalid;
                end
                if (bresp !== 2'b00) $display("[tb] write 0x%0h -> SLVERR", a);
            end
            awvalid <= 1'b0; wvalid <= 1'b0;
            @(posedge s_axi_aclk); #2;
            bready <= 1'b0;
        end
    endtask

    task automatic axr(input logic [63:0] a, output logic [31:0] d);
        begin
            @(negedge s_axi_aclk);
            araddr <= a; arprot <= '0; arvalid <= 1'b1;
            rready <= 1'b1;
            begin : r_wait
                logic got;
                got = 1'b0;
                while (!got) begin
                    @(posedge s_axi_aclk); #2;
                    got = rvalid;
                end
                d = rdata;
            end
            arvalid <= 1'b0;
            @(posedge s_axi_aclk); #2;
            rready <= 1'b0;
        end
    endtask

    // ------------------------------------------------------------------ image
    logic [31:0] imem_img [0:IMEM_WORDS-1];
    logic [63:0] dmem_img [0:DMEM_WORDS-1];
    string code_f, data_f, uart_f;

    integer ufd;
    integer npoll;
    integer maxcyc;
    integer n_imem, n_dmem;
    logic [31:0] v, ec;
    logic [31:0] mlo;
    logic [7:0]  ch;
    logic        done = 1'b0;

    initial begin
        $display("[tb] start t=%0t", $time);
        awvalid = 0; awaddr = 0; awprot = 0;
        wvalid = 0; wdata = 0; wstrb = 0;
        bready = 0;
        arvalid = 0; araddr = 0; arprot = 0;
        rready = 0;
        s_axi_aresetn = 1'b0;
        cpu_rst_n     = 1'b0;

        if (!$value$plusargs("CODE=%s", code_f)) code_f = "code.hex";
        if (!$value$plusargs("DATA=%s", data_f)) data_f = "data.hex";
        if (!$value$plusargs("MAXCYC=%d", maxcyc)) maxcyc = 2000000;
        ufd = 0;
        if ($value$plusargs("UART=%s", uart_f)) ufd = $fopen(uart_f, "w");

        for (int i = 0; i < IMEM_WORDS; i++) imem_img[i] = 32'd0;
        for (int i = 0; i < DMEM_WORDS; i++) dmem_img[i] = 64'd0;
        $readmemh(code_f, imem_img);
        $readmemh(data_f, dmem_img);
        $display("[tb] images read (%s / %s)", code_f, data_f);

        repeat (10) @(posedge s_axi_aclk);
        #1;
        s_axi_aresetn = 1'b1;
        cpu_rst_n     = 1'b1;
        $display("[tb] aresetn released t=%0t", $time);
        repeat (5) @(posedge s_axi_aclk);
        #1;

        // ---- load the image while the core is held in reset (CTRL.run = 0)
        n_imem = 0; n_dmem = 0;
        for (int i = 0; i < IMEM_WORDS; i++) if (imem_img[i] != 32'd0) n_imem = i + 1;
        for (int i = 0; i < DMEM_WORDS; i++) if (dmem_img[i] != 64'd0) n_dmem = i + 1;
        $display("[tb] loading %0d imem words, %0d dmem words", n_imem, n_dmem);
        for (int i = 0; i < n_imem; i++) begin
            axw(BASE + 4 * i, imem_img[i], 4'hF);
        end
        for (int i = 0; i < n_dmem; i++) begin
            axw(BASE + 64'h10000 + 8 * i,     dmem_img[i][31:0], 4'hF);   // low half
            axw(BASE + 64'h10000 + 8 * i + 4, dmem_img[i][63:32], 4'hF);  // high half
        end
        $display("[tb] loaded %0d IMEM words, %0d DMEM words", n_imem, n_dmem);

        axw(BASE + 64'h20008, 32'h1, 4'hF);   // clear the EXIT latch
        axw(BASE + 64'h20000, 32'h1, 4'hF);   // run

        // ---- poll: console + EXIT + MTIME
        npoll = 0;
        while (!done) begin
            npoll = npoll + 1;
            axr(BASE + 64'h21004, v);
            if (v[0]) begin
                axr(BASE + 64'h21000, v);
                ch = v[7:0];
                $write("%c", ch);
                if (ufd) $fwrite(ufd, "%c", ch);
            end
            axr(BASE + 64'h20008, v);
            if (v[0]) begin
                axr(BASE + 64'h2000c, ec);
                done = 1'b1;
            end
            if (!done && ($time / CYCLES_PER_NS) > maxcyc) begin
                $display("\n[tb] TIMEOUT after %0d cycles", $time / CYCLES_PER_NS);
                if (ufd) $fclose(ufd);
                $fatal(1, "timeout");
            end
        end
        axr(BASE + 64'h20010, mlo);            // MTIME_LO (cpu_clk cycles since CTRL.run)
        $display("[tb] exit code %0d after %0d cycles (mtime=%0d cycles)", ec, $time / CYCLES_PER_NS, mlo);
        if (ufd) $fclose(ufd);
        if (ec != 32'd0) $fatal(1, "exit code %0d", ec);
        $display("[tb] PASS");
        $finish;
    end
endmodule
