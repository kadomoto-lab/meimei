// Physical register free list as a circular queue, one per register class.
//   - rename takes the first n_alloc free registers from the head (alloc[0..] are the next ones)
//   - commit pushes the released (old) registers at the tail, in program order
//   - recovery only moves the head: a backward ROB walk returns its squashed allocations
//     (n_back), a forward walk re-takes them (n_fwd), a snapshot restore sets the head
//     (squashed allocations are the queue entries just behind the current head)
// Pointers run over [0, 2N) so that "all N registers free" and "none free" differ.
module mm_freelist
    import mm_pkg::*;
#(
    parameter int N    = 192,          // capacity (class size - 32 architectural; with MOVE_ELIM, class size - 1:
                                       // architectural registers may share one, so more can be free)
    parameter int NI   = N,            // registers free at reset: BASE .. BASE+NI-1
    parameter int BASE = 32,           // first physical register number initially free
    localparam int PW  = $clog2(2 * N)
)
(
    input  logic          clk,
    input  logic          rst_n,
    output preg_t         alloc [DEC_W],
    output int            avail,                 // number of free registers
    input  int            n_alloc,
    input  logic [DEC_W-1:0] free_v,             // commit releases (compacted in program order below)
    input  preg_t         free_p [DEC_W],
    input  logic          restore,
    input  logic [PW-1:0] restore_ptr,
    input  int            n_back,
    input  int            n_fwd,
    output logic [PW-1:0] head
);
    function automatic logic [PW-1:0] padd(logic [PW-1:0] p, int n);   // (p + n) mod 2N, 0 <= n <= N
        int s;
        s = int'(p) + n;
        if (s >= 2 * N) s -= 2 * N;
        return PW'(s);
    endfunction
    function automatic logic [PW-1:0] psub(logic [PW-1:0] p, int n);
        int s;
        s = int'(p) - n;
        if (s < 0) s += 2 * N;
        return PW'(s);
    endfunction
    function automatic int pidx(logic [PW-1:0] p);
        return (int'(p) >= N) ? int'(p) - N : int'(p);
    endfunction

    preg_t q [N];
    logic [PW-1:0] tail;

    always_comb begin
        int d;
        d = int'(tail) - int'(head);
        avail = (d < 0) ? d + 2 * N : d;
        for (int k = 0; k < DEC_W; k++) alloc[k] = q[pidx(padd(head, k))];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= '0;
            tail <= PW'(NI);                                 // NI registers free
        end else begin
            int n;
            n = 0;
            for (int k = 0; k < DEC_W; k++) n += int'(free_v[k]);
            tail <= padd(tail, n);
            if (restore) head <= restore_ptr;
            else         head <= psub(padd(head, n_alloc + n_fwd), n_back);
        end
    end
    // queue storage: initial contents BASE .. BASE+NI-1, then commit releases at the tail.
    // The entry position is computed inline: written as `pidx(padd(tail, n)) == e`, Vivado 2024.1 made the
    // condition true for every entry, so each release overwrote the whole queue on the V80 (fixed in 12f5d89)
    for (genvar e = 0; e < N; e++) begin : g_q
        always_ff @(posedge clk) begin
            if (!rst_n) q[e] <= preg_t'(BASE + e);
            else begin
                int n, s;
                n = 0;
                for (int k = 0; k < DEC_W; k++)
                    if (free_v[k]) begin
                        s = int'(tail) + n;                     // (tail + n) mod 2N, then the index mod N
                        if (s >= 2 * N) s -= 2 * N;
                        if (s >= N) s -= N;
                        if (s == e) q[e] <= free_p[k];
                        n++;
                    end
            end
        end
    end
endmodule
