// Ideal memories, kept in their own modules so they can be replaced by SRAM macros
// (and reported separately in synthesis). Both are banked so that every bank needs only one
// read and one write port, which maps onto FPGA
// distributed RAM / block RAM.
//
// Simulation: the testbenches load the flat image `mem` and then set `sim_load`, which copies it
// into the banks (`mem` is not used by the hardware; in mm_dmem it mirrors every write so the
// final memory contents can be dumped from it).
// FPGA: MM_IMEM_INIT / MM_DMEM_INIT give the image file name prefix; the banks read
// <prefix>.bNN.hex (NN = bank number, written by fpga/split_hex.py from a flat image).

// instruction memory: IMEM_WORDS x 32-bit (64 KiB). Returns the NSLOT+1 halfwords of a fetch block
// (NSLOT slots plus the second half of a 32-bit instruction in the last slot), asynchronously.
// A block touches at most NSLOT/2+1 consecutive words, so NSLOT word-interleaved banks with one
// read port each cover it. The address is taken modulo the memory size.
module mm_imem
    import mm_pkg::*;
(
    input  logic clk,
    input  logic [63:0] addr,                    // block start (halfword aligned)
    output logic [NSLOT:0][15:0] data,           // halfwords at addr, addr+2, ..., addr+2*NSLOT
    // program load port (as in the SynRV cores)
    input  logic        wr_en,
    input  logic [IMEM_AW-1:0] wr_addr,
    input  logic [31:0] wr_data
);
    localparam int NB   = NSLOT;
    localparam int BW   = $clog2(NB);
    localparam int ROWS = IMEM_WORDS / NB;
    localparam int RW   = $clog2(ROWS);
    logic [IMEM_AW-1:0] w0;
    logic [31:0] bank_q [NB];          // word read from each bank
    logic [31:0] win    [NB];          // words w0, w0+1, ... of the block
    assign w0 = addr[IMEM_AW+1:2];
`ifndef SYNTHESIS
    logic [31:0] mem [0:IMEM_WORDS-1];
    logic sim_load = 1'b0;
`endif
    for (genvar b = 0; b < NB; b++) begin : g_bank
        logic [31:0] m [ROWS];
        logic [RW-1:0] row;
        assign row       = RW'(w0 >> BW) + RW'(b < int'(w0[BW-1:0]));   // the window wraps into the next row
        assign bank_q[b] = m[row];
        always_ff @(posedge clk) if (wr_en && wr_addr[BW-1:0] == BW'(b)) m[RW'(wr_addr >> BW)] <= wr_data;
`ifndef SYNTHESIS
        always @(posedge sim_load) for (int r = 0; r < ROWS; r++) m[r] = mem[r * NB + b];
`elsif MM_IMEM_INIT
        initial $readmemh({`MM_IMEM_INIT, ".b", 8'd48 + 8'(b / 10), 8'd48 + 8'(b % 10), ".hex"}, m);
`endif
    end
    always_comb begin
        for (int j = 0; j < NB; j++) win[j] = bank_q[(int'(w0[BW-1:0]) + j) % NB];
        for (int i = 0; i <= NSLOT; i++) begin
            int h;
            h = int'(addr[1]) + i;
            data[i] = h[0] ? win[h >> 1][31:16] : win[h >> 1][15:0];
        end
    end
endmodule

// data RAM: WORDS x 64-bit, N_LDU read ports, 2 byte-masked write ports, plus one host load port.
// Two banks interleaved on address bit 3; the two writes of a cycle must go to different banks
// (the core's store drain guarantees it). Each bank keeps one copy per read port (1 write +
// 1 read port each, block RAM). Reads are synchronous on raddr_n (the address the load
// pipeline will hold next cycle); rdata is the word at raddr (= raddr_n of the previous cycle)
// including the writes of every earlier cycle, i.e. the same as an asynchronous read of raddr.
// The address is taken modulo the size.
//
// Host load port (an FPGA host loading a program image over PCIe/NoC; the simulation testbenches
// tie it off): host_waddr is a byte address inside the RAM, host_waddr[2] selects the 32-bit half
// of the 64-bit word, host_waddr[3] the bank. The host write has priority over the core's two
// writes and is merged into the same write port (two always_ff blocks writing one `ram` would
// not synthesize), so the core must be held in reset while a host image is written.
module mm_dmem
    import mm_pkg::*;
#(
    parameter int WORDS = 256
)
(
    input  logic clk,
    input  logic [N_LDU-1:0][63:0] raddr_n,
    input  logic [N_LDU-1:0][63:0] raddr,
    output logic [N_LDU-1:0][63:0] rdata,
    input  logic [1:0]       we,
    input  logic [1:0][63:0] waddr,
    input  logic [1:0][63:0] wdata,
    input  logic [1:0][7:0]  wmask,
    // host load port (byte address inside the RAM, bit2 = 32-bit half, bit3 = bank)
    input  logic             host_we,
    input  logic [63:0]      host_waddr,
    input  logic [31:0]      host_wdata,
    input  logic [3:0]       host_wmask
);
    localparam int AW   = $clog2(WORDS);
    localparam int ROWS = WORDS / 2;
    localparam int RW   = AW - 1;
    logic [63:0] bank_q [2][N_LDU];
`ifndef SYNTHESIS
    logic [63:0] mem [0:WORDS-1];
    logic sim_load = 1'b0;
    always_ff @(posedge clk) begin
        for (int d = 0; d < 2; d++)
            if (we[d])
                for (int b = 0; b < 8; b++)
                    if (wmask[d][b]) mem[waddr[d][AW+2:3]][8*b +: 8] <= wdata[d][8*b +: 8];
        if (we[0] && we[1] && waddr[0][3] == waddr[1][3]) $error("mm_dmem: two writes to one bank");
        if (host_we)
            for (int b = 0; b < 4; b++)
                if (host_wmask[b]) begin
                    if (host_waddr[2]) mem[host_waddr[AW+2:3]][32 + 8*b +: 8] <= host_wdata[8*b +: 8];
                    else               mem[host_waddr[AW+2:3]][      8*b +: 8] <= host_wdata[8*b +: 8];
                end
    end
`endif
    for (genvar k = 0; k < 2; k++) begin : g_bank
        logic          bwe, hwe, ewe;
        logic [RW-1:0] bwa, hwa, ewa;
        logic [63:0]   bwd, hwd, ewd;
        logic [7:0]    bwm, hwm, ewm, ewb;
        always_comb begin
            bwe = 1'b0; bwa = '0; bwd = '0; bwm = '0;
            for (int d = 0; d < 2; d++)
                if (we[d] && waddr[d][3] == 1'(k)) begin
                    bwe = 1'b1; bwa = waddr[d][AW+2:4]; bwd = wdata[d]; bwm = wmask[d];
                end
            hwe = host_we && host_waddr[3] == 1'(k);
            hwa = host_waddr[AW+2:4];
            hwd = host_waddr[2] ? {host_wdata, 32'h0} : {32'h0, host_wdata};
            hwm = host_waddr[2] ? {host_wmask, 4'h0} : {4'h0, host_wmask};
            // single write port to the RAM: host load wins over the CPU store
            if (hwe) begin ewe = 1'b1; ewa = hwa; ewd = hwd; ewm = hwm; end
            else     begin ewe = bwe;  ewa = bwa; ewd = bwd; ewm = bwm; end
            ewb = ewe ? ewm : 8'h00;
        end
        for (genvar m = 0; m < N_LDU; m++) begin : g_copy
            logic [63:0]   ram [ROWS];
            logic [63:0]   q, byp_d;
            logic [7:0]    byp_m;
            logic [RW-1:0] ra;
            assign ra = raddr_n[m][AW+2:4];
            // the write enable is folded into the byte enables (ewb): written as `if (ewe) for (b)
            // if (ewm[b])`, Vivado 2024.1 tied the byte enables of copy 0 to 0 (URAM and BRAM alike), so
            // load port 0 never saw any write on the V80 (fixed in 64cef2a)
            always_ff @(posedge clk)
                for (int b = 0; b < 8; b++)
                    if (ewb[b]) ram[ewa][8*b +: 8] <= ewd[8*b +: 8];
            always_ff @(posedge clk) begin
                q     <= ram[ra];                                // read-first
                byp_m <= (bwe && bwa == ra) ? bwm : 8'h00;       // same-cycle write to the word read
                byp_d <= bwd;
            end
            always_comb
                for (int b = 0; b < 8; b++)
                    bank_q[k][m][8*b +: 8] = byp_m[b] ? byp_d[8*b +: 8] : q[8*b +: 8];
`ifndef SYNTHESIS
            always @(posedge sim_load) for (int r = 0; r < ROWS; r++) ram[r] = mem[2 * r + k];
`elsif MM_DMEM_INIT
            initial $readmemh({`MM_DMEM_INIT, ".b0", 8'd48 + 8'(k), ".hex"}, ram);
`endif
        end
    end
    for (genvar m = 0; m < N_LDU; m++) begin : g_rd
        assign rdata[m] = raddr[m][3] ? bank_q[1][m] : bank_q[0][m];
    end
endmodule
