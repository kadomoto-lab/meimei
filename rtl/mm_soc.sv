// Bare-metal SoC around the out-of-order core (simulation model).
//
//   0x0000_1000  4 KiB   reserved (boot ROM / reset vector; not implemented, reads as 0)
//   0x1000_0000  4 KiB   UART
//   0x1000_1000  4 KiB   GPIO
//   0x1000_2000  4 KiB   timer / run status
//   0x8000_0000  64 KiB  instruction SRAM (fetch only; the reset vector)
//   0x8001_0000  64 KiB  data SRAM (loads / stores; .rodata .data .bss heap stack)
//
// Host load port: an FPGA host (e.g. an FPGA PCIe card driving this SoC over AXI) writes the
// program image into the two SRAMs before releasing the core; the simulation testbenches tie the
// port off and use $readmemh instead. The host must keep the core in reset (rst_n low) while
// loading, because the host write shares the SRAM write port with the core.
//
// Device registers (offsets; loads of 1..8 bytes at any offset inside a register dword):
//   UART  +0x00 TXDATA  W  byte [7:0] is sent (the simulation prints it immediately)
//         +0x04 STATUS  R  bit0 = TX ready (always 1), bit1 = RX data available
//         +0x08 RXDATA  R  {bit8 = valid, [7:0] = head of the RX FIFO}; W with bit0 = 1 pops
//   GPIO  +0x00 IN      R  input pins
//         +0x08 OUT     RW output pins
//   TIMER +0x00 MTIME   R  cycles since reset (64-bit)
//         +0x08 INSTRET R  retired instructions (64-bit)
//         +0x10 EXIT    W  ends the run, value = exit code (0 = pass)
// MMIO loads are executed by the core non-speculatively (at the ROB head, after older stores),
// MMIO stores when they drain from the store queue after commit.
package mm_soc_pkg;
    localparam logic [63:0] RESET_VECTOR = 64'h8000_0000;
    localparam logic [63:0] UART_BASE    = 64'h1000_0000;
    localparam logic [63:0] GPIO_BASE    = 64'h1000_1000;
    localparam logic [63:0] TIMER_BASE   = 64'h1000_2000;
    localparam logic [63:0] IMEM_BASE    = 64'h8000_0000;
    localparam logic [63:0] DMEM_BASE    = 64'h8001_0000;
`ifdef MM_DMEM_WORDS
    localparam int          DMEM_WORDS   = `MM_DMEM_WORDS;
`else
    localparam int          DMEM_WORDS   = 8192;          // 64 KiB
`endif
endpackage

module mm_soc
    import mm_pkg::*;
    import mm_soc_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    // UART (simulation side)
    output logic        uart_tx_valid,
    output logic [7:0]  uart_tx_data,
    input  logic        uart_tx_ready,   // STATUS bit0 (the simulation ties it to 1)
    input  logic        uart_rx_push,
    input  logic [7:0]  uart_rx_data,
    // GPIO
    input  logic [31:0] gpio_in,
    output logic [63:0] gpio_out,
    // run status
    output logic        exit_valid,
    output logic [31:0] exit_code,
    output logic [63:0] mtime_o,         // MTIME, for a host measuring the run time
    // host load port
    input  logic                    host_imem_we,
    input  logic [IMEM_AW-1:0]      host_imem_addr,
    input  logic [31:0]             host_imem_data,
    input  logic                    host_dmem_we,
    input  logic [63:0]             host_dmem_waddr,   // byte address inside the data SRAM
    input  logic [31:0]             host_dmem_wdata,
    input  logic [3:0]              host_dmem_wmask
);
    logic [N_LDU-1:0][63:0] dm_raddr, dm_raddr_n, dm_rdata, sram_rdata;
    logic [1:0]             dm_we, sram_we;
    logic [1:0][63:0]       dm_waddr, dm_wdata;
    logic [1:0][7:0]        dm_wmask;
    logic                   io_re;
    logic [63:0]            io_raddr, io_rdata;
    logic [N_WB-1:0]        dbg_v;
    logic [N_WB-1:0][63:0]  dbg_val;
    logic [63:0]            instret;

    mm_core #(.RESET_PC(RESET_VECTOR)) u_core (
        .clk, .rst_n,
        .imem_wr_en(host_imem_we), .imem_wr_addr(host_imem_addr), .imem_wr_data(host_imem_data),
        .dm_raddr, .dm_raddr_n, .dm_rdata, .dm_we, .dm_waddr, .dm_wdata, .dm_wmask,
        .io_re, .io_raddr, .io_rdata, .instret,
        .dbg_wb_valid(dbg_v), .dbg_wb_value(dbg_val)
    );

    function automatic logic in_dmem(logic [63:0] a);
        return a[63:16] == DMEM_BASE[63:16];
    endfunction

    // data SRAM
    for (genvar d = 0; d < 2; d++) begin : g_we
        assign sram_we[d] = dm_we[d] && in_dmem(dm_waddr[d]);
    end
    mm_dmem #(.WORDS(DMEM_WORDS)) u_dmem (.clk, .raddr_n(dm_raddr_n), .raddr(dm_raddr), .rdata(sram_rdata),
                                          .we(sram_we), .waddr(dm_waddr), .wdata(dm_wdata), .wmask(dm_wmask),
                                          .host_we(host_dmem_we), .host_waddr(host_dmem_waddr),
                                          .host_wdata(host_dmem_wdata), .host_wmask(host_dmem_wmask));
    for (genvar m = 0; m < N_LDU; m++) begin : g_rd
        assign dm_rdata[m] = in_dmem(dm_raddr[m]) ? sram_rdata[m] : '0;
    end

    // ---------------- devices ----------------
    logic [63:0] mtime;
    assign mtime_o = mtime;
    logic [7:0]  rx_fifo [16];
    logic [3:0]  rx_head, rx_tail;
    logic [4:0]  rx_cnt;

    always_comb begin
        unique case (io_raddr[63:3])
            UART_BASE[63:3]:          io_rdata = {30'd0, rx_cnt != 0, uart_tx_ready, 32'd0};
            UART_BASE[63:3] + 1:      io_rdata = {55'd0, rx_cnt != 0, rx_fifo[rx_head]};
            GPIO_BASE[63:3]:          io_rdata = {32'd0, gpio_in};
            GPIO_BASE[63:3] + 1:      io_rdata = gpio_out;
            TIMER_BASE[63:3]:         io_rdata = mtime;
            TIMER_BASE[63:3] + 1:     io_rdata = instret;
            default:                  io_rdata = '0;
        endcase
    end

    always_comb begin
        uart_tx_valid = 1'b0; uart_tx_data = '0;
        exit_valid = 1'b0; exit_code = '0;
        for (int d = 0; d < 2; d++) begin
            if (dm_we[d] && dm_waddr[d][63:3] == UART_BASE[63:3] && dm_wmask[d][0]) begin
                uart_tx_valid = 1'b1; uart_tx_data = dm_wdata[d][7:0];
            end
            if (dm_we[d] && dm_waddr[d][63:3] == TIMER_BASE[63:3] + 2) begin
                exit_valid = 1'b1; exit_code = dm_wdata[d][31:0];
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mtime <= '0; gpio_out <= '0;
            rx_head <= '0; rx_tail <= '0; rx_cnt <= '0;
        end else begin
            logic pop, push;
            mtime <= mtime + 1'b1;
            pop  = 1'b0;
            for (int d = 0; d < 2; d++) begin
                if (dm_we[d] && dm_waddr[d][63:3] == GPIO_BASE[63:3] + 1)
                    for (int b = 0; b < 8; b++) if (dm_wmask[d][b]) gpio_out[8*b +: 8] <= dm_wdata[d][8*b +: 8];
                if (dm_we[d] && dm_waddr[d][63:3] == UART_BASE[63:3] + 1 && dm_wmask[d][0] && dm_wdata[d][0])
                    pop = 1'b1;
            end
            pop  = pop && rx_cnt != 0;
            push = uart_rx_push && (rx_cnt < 16 || pop);
            if (pop)  rx_head <= rx_head + 1'b1;
            if (push) begin rx_fifo[rx_tail] <= uart_rx_data; rx_tail <= rx_tail + 1'b1; end
            rx_cnt <= rx_cnt + 5'(push) - 5'(pop);
        end
    end
endmodule
