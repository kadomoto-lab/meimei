// V80 top: the meimei out-of-order RV64 core as a PL block with a host (AXI4-Lite) load/run port.
//
//   s_axi_aclk / s_axi_aresetn : host side, AXI4-Lite slave, NoC M00 (pl0_ref_clk, 100 MHz)
//   cpu_clk / cpu_rst_n        : core side (also pl0_ref_clk; cpu_clk MUST be the same clock as
//                                s_axi_aclk -- the EXIT pulse from mm_soc is latched in the
//                                s_axi_aclk domain)
//
// The host writes CTRL.run to release the core from reset, so a run always starts at the reset
// vector with MTIME = 0. See fpga/v80/README.md for the register map and the host-side loader.
module mm_v80_top
    import mm_pkg::*;
    import mm_soc_pkg::*;
(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aclk, ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn, FREQ_HZ 100000000, PHASE 0.0" *)
    input  logic        s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi_aresetn, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
    input  logic        s_axi_aresetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 cpu_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME cpu_clk, ASSOCIATED_RESET cpu_rst_n, FREQ_HZ 100000000, PHASE 0.0" *)
    input  logic        cpu_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 cpu_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME cpu_rst_n, POLARITY ACTIVE_LOW, INSERT_VIP 0" *)
    input  logic        cpu_rst_n,
    // ---------------- AXI4-Lite slave (host) ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4LITE, ADDR_WIDTH 64, DATA_WIDTH 32, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1, READ_WRITE_MODE READ_WRITE, SUPPORTS_NARROW_BURST 0, FREQ_HZ 100000000, ID_WIDTH 0, AWUSER_WIDTH 0, ARUSER_WIDTH 0, WUSER_WIDTH 0, RUSER_WIDTH 0, BUSER_WIDTH 0" *)
    input  logic [63:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  logic [2:0]  s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  logic        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output logic        s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  logic [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  logic [3:0]  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  logic        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output logic        s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output logic [1:0]  s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output logic        s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  logic        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  logic [63:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  logic [2:0]  s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  logic        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output logic        s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output logic [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output logic [1:0]  s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output logic        s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  logic        s_axi_rready
);
    // ---------------- host interface ----------------
    logic                    host_imem_we;
    logic [IMEM_AW-1:0]      host_imem_addr;
    logic [31:0]             host_imem_data;
    logic                    host_dmem_we;
    logic [63:0]             host_dmem_waddr;
    logic [31:0]             host_dmem_wdata;
    logic [3:0]              host_dmem_wmask;
    logic                    ctrl_run, ctrl_clear_exit, ctrl_clear_tx;
    logic [63:0]             mtime;
    logic                    exit_v;            // 1-cycle pulse from mm_soc (cpu_clk)
    logic [31:0]             exit_c;
    logic                    exit_v_q;         // latched, s_axi_aclk domain
    logic [31:0]             exit_c_q;
    logic                    uart_tx_valid, uart_tx_ready, uart_tx_pop, uart_tx_dv;
    logic [7:0]              uart_tx_data, uart_tx_head;
    logic                    uart_rx_push;
    logic [7:0]              uart_rx_data;

    mm_host_axi #(.IMEM_AW(IMEM_AW), .DMEM_AW($clog2(DMEM_WORDS))) u_axi (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
        .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
        .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
        .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
        .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
        .host_imem_we, .host_imem_addr, .host_imem_data,
        .host_dmem_we, .host_dmem_waddr, .host_dmem_wdata, .host_dmem_wmask,
        .ctrl_run, .ctrl_clear_exit, .ctrl_clear_tx,
        .mtime_i(mtime), .exit_valid_i(exit_v_q), .exit_code_i(exit_c_q),
        .uart_tx_pop, .uart_tx_valid(uart_tx_dv), .uart_tx_full(~uart_tx_ready),
        .uart_tx_data(uart_tx_head),
        .uart_rx_push, .uart_rx_data
    );

    // ---------------- the SoC ----------------
    // CTRL.run is the core reset: a run always starts from the reset vector with MTIME = 0.
    mm_soc u_soc (
        .clk(cpu_clk), .rst_n(cpu_rst_n & ctrl_run),
        .uart_tx_valid, .uart_tx_data, .uart_tx_ready,
        .uart_rx_push, .uart_rx_data,
        .gpio_in(32'd0), .gpio_out(),
        .exit_valid(exit_v), .exit_code(exit_c), .mtime_o(mtime),
        .host_imem_we, .host_imem_addr, .host_imem_data,
        .host_dmem_we, .host_dmem_waddr, .host_dmem_wdata, .host_dmem_wmask
    );

    // ---------------- console ----------------
    mm_uart_host_tx #(.DEPTH(4096)) u_tx (
        .clk(s_axi_aclk), .rst_n(s_axi_aresetn),
        .valid(uart_tx_valid), .data(uart_tx_data), .ready(uart_tx_ready),
        .rvalid(uart_tx_pop), .rready(1'b1), .rdata(uart_tx_head), .data_valid(uart_tx_dv),
        .clear(ctrl_clear_tx)
    );

    // ---------------- EXIT latch (s_axi_aclk domain) ----------------
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            exit_v_q  <= 1'b0;
            exit_c_q  <= 32'd0;
        end else if (ctrl_clear_exit) begin
            exit_v_q  <= 1'b0;
            exit_c_q  <= 32'd0;
        end else if (exit_v) begin
            exit_v_q  <= 1'b1;
            exit_c_q  <= exit_c;
        end
    end
endmodule
