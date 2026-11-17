// 8N1 UART for the FPGA build: transmitter with a small FIFO (TX ready = FIFO not full) and receiver
module mm_uart_tx #(parameter int CLK_HZ = 25_000_000, parameter int BAUD = 115200, parameter int DEPTH = 16) (
    input  logic       clk, rst_n,
    input  logic       valid,          // push one byte
    input  logic [7:0] data,
    output logic       ready,          // FIFO not full
    output logic       tx
);
    localparam int DIV = CLK_HZ / BAUD;
    logic [7:0] fifo [DEPTH];
    logic [$clog2(DEPTH)-1:0] head, tail;
    logic [$clog2(DEPTH):0]   cnt;
    logic [9:0]  shreg;
    logic [3:0]  nbit;
    logic [$clog2(DIV+1)-1:0] tick;
    logic        busy;
    assign ready = cnt < DEPTH;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= '0; tail <= '0; cnt <= '0; busy <= 1'b0; tx <= 1'b1; tick <= '0; nbit <= '0;
        end else begin
            logic pop;
            pop = !busy && cnt != 0;
            if (valid && ready) begin fifo[tail] <= data; tail <= tail + 1'b1; end
            cnt <= cnt + (valid && ready) - pop;
            if (pop) begin
                shreg <= {1'b1, fifo[head], 1'b0};          // stop, data (LSB first), start
                head <= head + 1'b1; busy <= 1'b1; nbit <= '0; tick <= '0;
            end else if (busy) begin
                tx <= shreg[0];
                if (tick == DIV - 1) begin
                    tick <= '0;
                    shreg <= {1'b1, shreg[9:1]};
                    nbit <= nbit + 1'b1;
                    if (nbit == 4'd9) busy <= 1'b0;
                end else tick <= tick + 1'b1;
            end
        end
    end
endmodule

module mm_uart_rx #(parameter int CLK_HZ = 25_000_000, parameter int BAUD = 115200) (
    input  logic       clk, rst_n,
    input  logic       rx,
    output logic       valid,          // one cycle per received byte
    output logic [7:0] data
);
    localparam int DIV = CLK_HZ / BAUD;
    logic [2:0] sync;
    logic       busy;
    logic [3:0] nbit;
    logic [$clog2(DIV+1)-1:0] tick;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            sync <= '1; busy <= 1'b0; valid <= 1'b0; nbit <= '0; tick <= '0;
        end else begin
            sync  <= {sync[1:0], rx};
            valid <= 1'b0;
            if (!busy) begin
                if (!sync[2]) begin busy <= 1'b1; tick <= DIV / 2; nbit <= '0; end   // start bit edge
            end else if (tick == DIV - 1) begin
                tick <= '0;
                nbit <= nbit + 1'b1;
                if (nbit == 4'd0 && sync[2]) busy <= 1'b0;                          // false start
                else if (nbit >= 4'd1 && nbit <= 4'd8) data <= {sync[2], data[7:1]};
                else if (nbit == 4'd9) begin busy <= 1'b0; valid <= sync[2]; end   // stop bit
            end else tick <= tick + 1'b1;
        end
    end
endmodule
