// Nexys Video (XC7A200T) top for mm_soc: 100 MHz board clock -> MMCM -> core clock (CLK_MHZ),
// CPU_RESET button, USB-UART (115200 8N1), 8 LEDs = GPIO OUT[7:0], 8 switches = GPIO IN[7:0].
// Program images are compiled into the bitstream ($readmemh, defines MM_IMEM_INIT / MM_DMEM_INIT).
module mm_fpga_top #(
    parameter int CLK_MHZ = 25,          // 1000 / CLK_MHZ must be a valid MMCM output divider (2..128)
    parameter int BAUD    = 115200
) (
    input  logic       clk100,
    input  logic       cpu_resetn,
    input  logic       uart_rx,
    output logic       uart_tx,
    input  logic [7:0] sw,
    output logic [7:0] led
);
    // ---------------- clock: VCO 1000 MHz, CLKOUT0 = 1000 / CLK_MHZ ----------------
    logic clk_fb, clk_mmcm, clk, locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(10.0), .CLKFBOUT_MULT_F(10.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(1000.0 / CLK_MHZ)
    ) u_mmcm (
        .CLKIN1(clk100), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKOUT0(clk_mmcm), .LOCKED(locked),
        .PWRDWN(1'b0), .RST(1'b0),
        .CLKFBOUTB(), .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6()
    );
    BUFG u_bufg (.I(clk_mmcm), .O(clk));

    // ---------------- reset: asserted while the MMCM is unlocked or CPU_RESET is pressed ----------------
    logic [3:0] rst_sync;
    logic       rst_n;
    always_ff @(posedge clk or negedge locked)
        if (!locked) rst_sync <= '0;
        else         rst_sync <= {rst_sync[2:0], cpu_resetn};
    assign rst_n = rst_sync[3];

    // ---------------- SoC + devices ----------------
    logic        tx_v, tx_rdy, rx_v, exit_v;
    logic [7:0]  tx_d, rx_d;
    logic [31:0] exit_c;
    logic [63:0] gpo;
    mm_soc u_soc (
        .clk, .rst_n,
        .uart_tx_valid(tx_v), .uart_tx_data(tx_d), .uart_tx_ready(tx_rdy),
        .uart_rx_push(rx_v), .uart_rx_data(rx_d),
        .gpio_in({24'd0, sw}), .gpio_out(gpo),
        .exit_valid(exit_v), .exit_code(exit_c), .mtime_o(),
        .host_imem_we(1'b0), .host_imem_addr('0), .host_imem_data('0),
        .host_dmem_we(1'b0), .host_dmem_waddr('0), .host_dmem_wdata('0), .host_dmem_wmask('0)
    );
    mm_uart_tx #(.CLK_HZ(CLK_MHZ * 1_000_000), .BAUD(BAUD)) u_tx (.clk, .rst_n, .valid(tx_v), .data(tx_d), .ready(tx_rdy), .tx(uart_tx));
    mm_uart_rx #(.CLK_HZ(CLK_MHZ * 1_000_000), .BAUD(BAUD)) u_rx (.clk, .rst_n, .rx(uart_rx), .valid(rx_v), .data(rx_d));

    // LEDs: GPIO OUT[7:0]; after the program writes EXIT: led[7] = 1, led[6:0] = exit code
    logic       exited;
    logic [6:0] code;
    always_ff @(posedge clk)
        if (!rst_n) exited <= 1'b0;
        else if (exit_v) begin exited <= 1'b1; code <= exit_c[6:0]; end
    assign led = exited ? {1'b1, code} : gpo[7:0];
endmodule
