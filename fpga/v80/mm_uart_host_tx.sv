// UART TX buffer with a host (AXI) read port.
//
// The SoC pushes one byte per cycle (valid -> data) into a FIFO; the host reads the head over
// AXI and pops it (rvalid + rready). ready = space left, so the SoC's UART STATUS bit0 (TX ready)
// is simply "FIFO not full": no byte is ever dropped. With the core stalling while the FIFO is
// full the run throughput follows the console speed, so DEPTH is large (the host drains a 4 KiB
// FIFO with a handful of bursts).
module mm_uart_host_tx #(
    parameter int DEPTH = 4096            // power of two
) (
    input  logic       clk,
    input  logic       rst_n,
    // SoC side (mm_soc uart_tx_*)
    input  logic       valid,
    input  logic [7:0] data,
    output logic       ready,             // FIFO not full
    // host side: read the head byte (rdata) and pop it
    input  logic       rvalid,
    input  logic       rready,
    output logic [7:0] rdata,
    output logic       data_valid,        // FIFO not empty
    // drop everything buffered (CTRL bit2)
    input  logic       clear
);
    localparam int CW = $clog2(DEPTH) + 1;

    logic [7:0]  fifo [DEPTH];
    logic [CW-1:0] wptr, rptr;
    logic [CW-1:0] cnt;

    wire push = valid && (cnt < DEPTH);
    wire pop  = rvalid && rready && (cnt != 0);

    assign ready      = cnt < DEPTH;
    assign data_valid = cnt != 0;
    assign rdata      = fifo[rptr[$clog2(DEPTH)-1:0]];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wptr <= '0;
            rptr <= '0;
            cnt  <= '0;
        end else if (clear) begin
            wptr <= '0;
            rptr <= '0;
            cnt  <= '0;
        end else begin
            if (push) begin
                fifo[wptr[$clog2(DEPTH)-1:0]] <= data;
                wptr <= wptr + 1'b1;
            end
            if (pop)
                rptr <= rptr + 1'b1;
            cnt <= cnt + CW'(push) - CW'(pop);
        end
    end
endmodule
