// AXI4-Lite slave: the host side of the meimei SoC on an FPGA card.
//
// The host loads the program image into instruction / data SRAM, then starts and polls the core
// and drains its console through the TX FIFO. Address map (offset inside the 256 KiB window that
// the NoC aperture assigns to this slave):
//
//   0x00000 - 0x0FFFF  IMEM    64 KiB, little-endian 32-bit words; a write must have all four
//                              byte strobes (wstrb = 1111), otherwise it is answered with SLVERR
//   0x10000 - 0x1FFFF  DMEM    64 KiB, 64-bit words: byte offset 8*i+0..3 = low half, 8*i+4..7 =
//                              high half of word i (byte strobes honoured)
//   0x20000  CTRL       W  bit0 = run (level: 0 holds the core in reset), bit1 = clear EXIT
//                            (1-cycle pulse), bit2 = clear the UART TX FIFO (1-cycle pulse)
//                      R  bit0 = run
//   0x20004  STATUS     R  bit0 = run, bit1 = EXIT latched
//   0x20008  EXIT_STATUS R bit0 = EXIT latched (set by the program's store to TIMER+0x10)
//   0x2000c  EXIT_CODE  R  the value the program stored to TIMER+0x10 (0 = pass)
//   0x20010  MTIME_LO   R  SoC cycle counter [31:0]  (0 at the start of a run, counts cpu_clk)
//   0x20014  MTIME_HI   R  SoC cycle counter [63:32]
//   0x21000  UART_TX_DATA   R  head byte of the TX FIFO; reading it pops that byte
//   0x21004  UART_TX_STATUS R  bit0 = data valid (FIFO not empty), bit1 = full
//   0x21008  UART_RX_DATA   W  push a byte into the core's UART RX FIFO
//   0x2100c  UART_RX_STATUS R  always 0 (the RX path is push-only)
//
// Unmapped writes are answered with SLVERR, unmapped reads return 0. A single outstanding read and
// a single outstanding write are accepted (AXI4-Lite allows no more); the host must not issue a
// second read before the first rvalid handshake.
module mm_host_axi #(
    parameter int IMEM_AW = 14,       // word address width (16K words = 64 KiB)
    parameter int DMEM_AW = 13        // word address width (8K words = 64 KiB)
) (
    input  logic        clk,
    input  logic        rst_n,
    // ---------------- AXI4-Lite slave ----------------
    input  logic [63:0] s_axi_awaddr,
    input  logic [2:0]  s_axi_awprot,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [63:0] s_axi_araddr,
    input  logic [2:0]  s_axi_arprot,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    // ---------------- to the SoC ----------------
    output logic                    host_imem_we,
    output logic [IMEM_AW-1:0]      host_imem_addr,
    output logic [31:0]             host_imem_data,
    output logic                    host_dmem_we,
    output logic [63:0]             host_dmem_waddr,
    output logic [31:0]             host_dmem_wdata,
    output logic [3:0]              host_dmem_wmask,
    output logic                    ctrl_run,
    output logic                    ctrl_clear_exit,
    output logic                    ctrl_clear_tx,
    // core status
    input  logic [63:0]             mtime_i,
    input  logic                    exit_valid_i,   // latched EXIT, in the clk domain
    input  logic [31:0]             exit_code_i,
    // console
    output logic                    uart_tx_pop,
    input  logic                    uart_tx_valid,
    input  logic                    uart_tx_full,
    input  logic [7:0]              uart_tx_data,
    output logic                    uart_rx_push,
    output logic [7:0]              uart_rx_data
);
    localparam int DMAW = DMEM_AW + 3;               // DMEM byte address width

    // region select from the byte offset inside the window
    localparam logic [2:0] SEL_NONE = 3'd0, SEL_IMEM = 3'd1, SEL_DMEM = 3'd2,
                           SEL_CTRL = 3'd3, SEL_UART = 3'd4;

    function automatic logic [2:0] sel(logic [19:0] o);
        unique case (o[19:16])
            4'd0: return SEL_IMEM;
            4'd1: return SEL_DMEM;
            4'd2: unique case (o[15:12])
                      4'd0: return SEL_CTRL;
                      4'd1: return SEL_UART;
                      default: return SEL_NONE;
                  endcase
            default: return SEL_NONE;
        endcase
    endfunction

    // =================================================================
    // write channel
    // =================================================================
    typedef enum logic [1:0] { W_IDLE, W_EXEC, W_RESP } wst_t;
    wst_t        wst;
    logic        aw_got, w_got;
    logic [19:0] woff;
    logic [31:0] wdata_q;
    logic [3:0]  wstrb_q;
    logic [1:0]  bresp_q;

    wire aw_hit = (wst == W_IDLE) && s_axi_awvalid && !aw_got;
    wire w_hit  = (wst == W_IDLE) && s_axi_wvalid  && !w_got;
    wire w_start = (wst == W_IDLE) && (aw_got || aw_hit) && (w_got || w_hit);
    wire w_exec  = (wst == W_EXEC);

    assign s_axi_awready = (wst == W_IDLE) && !aw_got;
    assign s_axi_wready  = (wst == W_IDLE) && !w_got;
    assign s_axi_bvalid  = (wst == W_RESP);
    assign s_axi_bresp   = bresp_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wst     <= W_IDLE;
            aw_got  <= 1'b0;
            w_got   <= 1'b0;
            woff    <= '0;
            wdata_q <= '0;
            wstrb_q <= '0;
            bresp_q <= 2'b00;
        end else
            unique case (wst)
                W_IDLE: begin
                    if (aw_hit) begin woff <= s_axi_awaddr[19:0]; aw_got <= 1'b1; end
                    if (w_hit)  begin wdata_q <= s_axi_wdata; wstrb_q <= s_axi_wstrb; w_got <= 1'b1; end
                    if (w_start) begin wst <= W_EXEC; aw_got <= 1'b0; w_got <= 1'b0; end
                end
                W_EXEC: begin
                    // bresp_q must be ready when W_RESP drives s_axi_bresp
                    bresp_q <= ((w_imem && !w_imem_ok) || !(w_imem || w_dmem || w_ctrl || w_uart)) ? 2'b10 : 2'b00;
                    wst <= W_RESP;
                end
                W_RESP: if (s_axi_bready) wst <= W_IDLE;
                default: wst <= W_IDLE;
            endcase
    end

    wire [2:0] wsel    = sel(woff);
    wire       w_imem  = w_exec && wsel == SEL_IMEM;
    wire       w_dmem  = w_exec && wsel == SEL_DMEM;
    wire       w_ctrl  = w_exec && wsel == SEL_CTRL;
    wire       w_uart  = w_exec && wsel == SEL_UART;
    wire       w_imem_ok = wstrb_q == 4'hF;

    assign host_imem_we   = w_imem && w_imem_ok;
    assign host_imem_addr = woff[2 +: IMEM_AW];
    assign host_imem_data = wdata_q;
    assign host_dmem_we   = w_dmem;
    assign host_dmem_waddr = {{(64-DMAW){1'b0}}, woff[DMAW-1:0]};
    assign host_dmem_wdata = wdata_q;
    assign host_dmem_wmask = wstrb_q;

    // control / console writes, and the RX push pulse
    logic [7:0] rx_byte;
    logic       push_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ctrl_run        <= 1'b0;
            ctrl_clear_exit <= 1'b0;
            ctrl_clear_tx   <= 1'b0;
            rx_byte         <= 8'd0;
            push_q          <= 1'b0;
        end else begin
            ctrl_clear_exit <= 1'b0;
            ctrl_clear_tx   <= 1'b0;
            push_q          <= 1'b0;
            if (w_ctrl && woff[11:0] == 12'h000 && wstrb_q[0]) begin
                ctrl_run        <= wdata_q[0];
                ctrl_clear_exit <= wdata_q[1];
                ctrl_clear_tx   <= wdata_q[2];
            end
            if (w_uart && woff[11:0] == 12'h008) begin
                rx_byte <= wdata_q[7:0];
                push_q  <= 1'b1;
            end
        end
    end

    assign uart_rx_push = push_q;
    assign uart_rx_data = rx_byte;

    // =================================================================
    // read channel
    // =================================================================
    typedef enum logic { R_IDLE_ST, R_EXEC } rst_t;
    rst_t        rst;
    logic        ar_got;
    logic [19:0] roff;

    wire ar_hit = (rst == R_IDLE_ST) && s_axi_arvalid && !ar_got;
    wire r_exec = (rst == R_EXEC);
    wire r_pop  = r_exec && s_axi_rready && sel(roff) == SEL_UART && roff[11:0] == 12'h000;

    assign s_axi_arready = (rst == R_IDLE_ST) && !ar_got;
    assign s_axi_rvalid  = r_exec;
    assign s_axi_rresp   = 2'b00;
    assign uart_tx_pop   = r_pop;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rst    <= R_IDLE_ST;
            ar_got <= 1'b0;
            roff   <= '0;
        end else
            unique case (rst)
                R_IDLE_ST: if (ar_hit) begin roff <= s_axi_araddr[19:0]; ar_got <= 1'b1; rst <= R_EXEC; end
                R_EXEC:    if (s_axi_rready) begin rst <= R_IDLE_ST; ar_got <= 1'b0; end
            endcase
    end

    always_comb begin
        s_axi_rdata = 32'd0;
        if (r_exec) begin
            if (sel(roff) == SEL_CTRL) begin
                unique case (roff[11:0])
                    12'h000: s_axi_rdata = {31'd0, ctrl_run};
                    12'h004: s_axi_rdata = {30'd0, exit_valid_i, ctrl_run};
                    12'h008: s_axi_rdata = {31'd0, exit_valid_i};
                    12'h00c: s_axi_rdata = exit_code_i;
                    12'h010: s_axi_rdata = mtime_i[31:0];
                    12'h014: s_axi_rdata = mtime_i[63:32];
                    default: s_axi_rdata = 32'd0;
                endcase
            end else if (sel(roff) == SEL_UART) begin
                unique case (roff[11:0])
                    12'h000: s_axi_rdata = {24'd0, uart_tx_data};
                    12'h004: s_axi_rdata = {30'd0, uart_tx_full, uart_tx_valid};
                    default: s_axi_rdata = 32'd0;
                endcase
            end
        end
    end
endmodule
