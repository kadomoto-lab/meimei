// Parameters and types for the meimei out-of-order RV64IMFDC_Zicsr core.
// The default is the 8-wide configuration; compile with +define+MM_SMALL for the 4-wide core.
package mm_pkg;

`ifndef MM_SMALL
    // ================= default 8-wide core =================
    localparam int FETCH_W  = 16;   // 64-byte fetch block
    localparam int FTQ_N    = 64;
    localparam int IBUF_N   = 48;
    localparam int DEC_W    = 8;    // decode / rename / commit width
    localparam int ROB_N    = 352;
    localparam int INT_PRF_N = 224; // integer physical registers
    localparam int FP_PRF_N  = 256; // FP physical registers
    localparam int LQ_N     = 120;
    localparam int SQ_N     = 128;
    // execution units / issue queues (one IQ per unit):
    //   ALU0..2 + BJU0..2 (18 entries), ALU3..5 (20), LDU0..2 (20), STA0..1 (16),
    //   STD0..1 (16, STD_SPLIT), FEX0..3 (20). DIV on ALU1, I2F on ALU2, MUL on ALU4/ALU5;
    //   FALU+FMUL(FMA) on every FEX, FCVT/FCMP on FEX0, FDIV on FEX1/FEX2
    localparam int N_ALU  = 6;
    localparam int N_BJU  = 3;
    localparam int N_LDU  = 3;
    localparam int N_STU  = 2;
    localparam int N_FEX  = 4;
    localparam int N_MUL  = 2;      // the last N_MUL ALUs
    localparam int N_FDIV = 2;      // FEX1 .. FEX(N_FDIV)
    localparam int IQ_N_BJU = 18, IQ_N_ALU = 20, IQ_N_LDU = 20, IQ_N_STU = 16, IQ_N_FEX = 20;
`else
    // ================= scaled-down 4-wide core =================
    localparam int FETCH_W  = 8;
    localparam int FTQ_N    = 16;
    localparam int IBUF_N   = 32;
    localparam int DEC_W    = 4;
    localparam int ROB_N    = 64;
    localparam int INT_PRF_N = 96;
    localparam int FP_PRF_N  = 96;
    localparam int LQ_N     = 16;
    localparam int SQ_N     = 16;
    localparam int N_ALU  = 4;
    localparam int N_BJU  = 2;
    localparam int N_LDU  = 2;
    localparam int N_STU  = 1;
    localparam int N_FEX  = 2;
    localparam int N_MUL  = 1;
    localparam int N_FDIV = 1;
    localparam int IQ_N_BJU = 12, IQ_N_ALU = 12, IQ_N_LDU = 12, IQ_N_STU = 12, IQ_N_FEX = 12;
`endif
    // integer and FP registers share one physical index space (int pregs first); x0 is preg 0
    localparam int PRF_N    = INT_PRF_N + FP_PRF_N;
    localparam int IQ_ENQ   = 2;    // enqueue ports per issue queue
`ifdef MM_IMEM_WORDS
    localparam int IMEM_WORDS = `MM_IMEM_WORDS;
`else
    localparam int IMEM_WORDS = 16384;               // instruction SRAM 64 KiB
`endif
    localparam int IMEM_AW    = $clog2(IMEM_WORDS);
    localparam int IQ_MAX   = 20;   // largest issue queue (width of the free counters)
    localparam int BTB_SETS = 32;   // BTB sets per bank (one bank per word offset of the block)
    localparam int RAS_N    = 16;
    // RVC: a fetch block is 2 * FETCH_W halfword slots (64 B for FETCH_W = 16);
    // predictions are made per slot
    localparam int NSLOT    = 2 * FETCH_W;
    localparam int SLOT_W   = $clog2(NSLOT);     // halfword slot inside a fetch block
    // TAGE (tagged geometric-history predictor) on top of the BTB's 2-bit base counters
    localparam bit ENABLE_TAGE  = 1'b1;
    // BPU override pipeline: s1 = fast BTB + bimodal prediction (0 bubble),
    // s2 = TAGE prediction that overrides s1 with a 1-cycle bubble when they differ.
    // 0: TAGE is looked up in s1 directly (single-stage predictor).
    localparam bit BPU_OVERRIDE = 1'b1;
    // Global history: 1 = path history (per taken CFI: shift by 2, xor a 15-bit
    // hash of {cfi pc, target}); 0 = one taken/not-taken bit per fetch block.
    localparam bit HIST_PATH    = 1'b1;
    // s1 predictor: 1 = separate small fully-associative uBTB indexed by block start
    // (trained from the s2 prediction); 0 = s1 reads the main BTB
    localparam bit UBTB_EN      = 1'b1;
    localparam int UBTB_N       = 32;
    localparam int HIST_W       = 64;
    localparam int TAGE_NT    = 4;      // tagged tables
    localparam int TAGE_IDX_W = 10;     // 1024 entries per table (512 sets x TAGE_WAYS)
    localparam int TAGE_WAYS  = 2;
    localparam int TAGE_TAG_W = 10;
    // TAGE tag / counter tables as one RAM per table and field (one write port: the training writes at most
    // one entry of a table per cycle; the reads are combinational: NCHK rows for the prediction in s1 and
    // one row for the training in U0), so FPGA tools build distributed RAM instead of flip-flops and read
    // multiplexers. The valid and useful bits stay flip-flops (reset, aging)
    localparam bit TAGE_RAM = 1'b1;
    localparam int TAGE_HIST_B [TAGE_NT] = '{4, 8, 16, 32};    // block history: blocks
    localparam int TAGE_HIST_P [TAGE_NT] = '{8, 16, 32, 64};   // path history: bits (2 per taken CFI)

    // s3 stage (SC + ITTAGE), overrides s2 with a 2nd bubble
    localparam bit ENABLE_SC     = 1'b0;   // statistical corrector for conditional branches
    localparam bit ENABLE_ITTAGE = 1'b1;   // indirect target predictor for JALR (non-return)
    localparam int SC_NT    = 3;           // bias table (pc ^ TAGE dir) + 2 history tables
    localparam int SC_IDX_W = 7;
    localparam int SC_HIST [SC_NT] = '{0, 16, 64};
    localparam int SC_THR   = 24;          // SC training threshold on |TAGE-weighted sum|
    localparam int IT_NT    = 3;
    localparam int IT_IDX_W = 6;
    localparam int IT_TAG_W = 9;
    localparam int IT_HIST [IT_NT] = '{16, 32, 64};
    // TAGE / ITTAGE indexing (the CFI position is xor-ed into the tag in modes 1 and 2):
    //   0: CFI pc (one table read per halfword slot of the block; large)
    //   1: fetch block start (one read per table; a CFI reached from
    //      different block starts uses different entries, which costs ~2% CoreMark with these
    //      small tables)
    //   2: aligned chunk of the CFI (2^BP_ALIGN_W halfwords) + position in the chunk (chunk =
    //      half the fetch block: one entry per CFI, NSLOT / 2^BP_ALIGN_W + 1 reads per table)
    localparam int BP_IDX_MODE = 2;
    localparam int BP_ALIGN_W  = $clog2(NSLOT) - 1;
    // the chunk lines of the block (start line + r, mode 2) are computed when the block start is written and
    // registered with it, so the TAGE index / tag hashes in s1 start from registers (no adder before the
    // table read)
    localparam bit BP_LINE_PRE = 1'b1;
    // branch mispredict: 1 = predicted taken ^ taken, or taken with a wrong target
    // (every taken CFI ends its fetch block); 0 = only when the next pc differs (a taken branch
    // to the next instruction is not redirected; the FTQ training target of such blocks is then
    // approximate)
    localparam bit BR_MISP_TAKEN = 1'b1;
    // BPU s2 override compares the target with s1's (0: only taken / position;
    // a different target is caught by s3, which compares all targets)
    localparam bit S2_TGT_CMP = 1'b0;
    // predicted BTB / ITTAGE targets take the upper bits from the block start;
    // 0: from the CFI's pc (start + 2 * offset, one adder more on the prediction path)
    localparam bit BP_TGT_START = 1'b1;
    // IFU predecode check also redirects a predicted-taken JAL whose predicted target differs from the
    // decoded one (0: only unpredicted JALs; a wrong target is fixed by the BJU)
    localparam bit IFU_JAL_TGT_CHK = 1'b0;
    // the predicted-taken bit written to the IBuffer is decided per slot from that slot's own check
    // (an unpredicted JAL, or the predicted taken slot without a fault); 0: "slot == delivered count - 1"
    // (the fault priority encoder -> count -> compare path). Same for every delivered slot
    localparam bit IFU_PT_SLOT = 1'b1;
    // RAS pushes are written to the stack one cycle later, read through a bypass;
    // 0: written in the push cycle (the s3 override -> push address adder -> RAS write path)
    localparam bit RAS_WDELAY = 1'b1;
    // the main RAS is updated only by the final (s3) prediction of each block; s1 takes its RAS top
    // from a micro-RAS that tracks the pushes / pops of the blocks in s2 / s3, s2 does not use the RAS,
    // overrides do not touch the RAS pointer. 0: one speculative RAS updated
    // at s1 and repaired by the s2 / s3 overrides
    localparam bit RAS_S3 = 1'b1;
    // BPU per-slot set-up one stage early (the stage that decides only compares and selects):
    // s1 registers each bank's position, TAGE chunk and expected TAGE tag and the block start's upper part + 1
    // (carry-select CFI / link addresses); s2 registers each bank's expected ITTAGE tag for s3; s3 takes the
    // s2 decision (the same with ENABLE_SC = 0) and only forms the target (BP_IDX_MODE = 2 only)
    localparam bit BP_PRE = 1'b1;
    // s3 starts from the decided bank's BTB fields, ITTAGE chunk and expected tags selected at the end of s2
    // (registered) instead of indexing the per-bank registers with the registered bank number; same result
    localparam bit BP_S3_SEL = 1'b1;
    // FMA as a 3-stage pipeline (FADD/FSUB 2 stages). 0: computed in EX1 and delayed
    // (one long combinational path). Same latencies, so the cycle counts do not change
    localparam bit FMA_PIPE = 1'b1;
    // FMA in 4 stages (normalization and rounding in separate stages; FMUL/FMADD
    // latency 4, FADD/FSUB stay at 2 with their own rounding). 0: 3 stages (normalize + round in one)
    localparam bit FMA4 = 1'b1;
    // FMA4: the addend is aligned in EX1 in parallel with the multiplier and EX2 only adds.
    // 0: EX2 computes the exponent difference, aligns the smaller term and adds
    localparam bit FMA_ALIGN_A = 1'b1;
    // FMA multiplier split over two stages (FMA_ALIGN_A only): A = Booth partial products of the raw
    // significands (no subnormal normalization) and 5 carry-save levels; B = the remaining levels,
    // a 3:2 level with the aligned addend and the carry-propagate adds. 0: the full product in A
    localparam bit FMA_CSA = 1'b1;
    // FMA normalization limited by the exponent: C1 counts leading zeros of the
    // sum ORed with a one at the shift limit, so a subnormal result comes out of the left shift and the rounding
    // stage C2 has no denormalizing right shift (FMA_ALIGN_A only). 0: full normalization, denormalized in C2
    localparam bit FMA_LSH = 1'b1;
    // single-precision FADD/FSUB datapath from the raw low 32 operand bits; the NaN-boxing check
    // (64-bit compare + canonical-NaN substitution) only feeds the NaN flags, off the alignment path
    localparam bit FADD_RAW = 1'b1;
    // FADD/FSUB alignment from the raw exponent fields: a subnormal is taken as twice its fraction with exponent
    // field 0 (the same value), so the exponent difference needs no zero test in front of its subtract
    localparam bit FADD_RAWEXP = 1'b1;
    // FADD/FSUB EX2 rounds the sum at the three normalization shifts that can be inexact (carry out, none,
    // one cancelled bit) in parallel with the leading-zero count; a longer shift (two or more cancelled bits)
    // only happens with an exponent difference <= 1 and is exact, so it is packed without rounding.
    // 0: leading-zero count -> left shift -> rounding in series
    localparam bit FADD_RSEL = 1'b1;
    // the FP pipes have no latency-1 uops: their write-back pipes are built without the issue-stage wakeup and
    // the EX1 write port (otherwise the FP select -> wakeup tag -> ready bits of every queue is one cycle path)
    localparam bit WBP_FEX_NOL1 = 1'b1;
    // the redirect kill of the oldest violating load is taken from per-entry kill bits of the LQ (compared in
    // parallel with the address hits) by the same one-hot select, not compared after selecting its ROB
    // number; the registered violation is not checked again in the same cycle
    localparam bit VIOL_KILL_OH = 1'b1;
    // the issue queues' register cache tracking takes the cache writes before the redirect kill: a killed
    // write's register is not a source of any live entry (it was allocated after them), and a selected entry
    // that is killed now does not issue, so the state seen by live uops is the same
    localparam bit RC_TRK_NOKILL = 1'b1;
    // the leading-one searches of the FP unpack (subnormal normalization) and of fp_round_norm use the tree
    // leading-zero count (mm_lzc); 0: a loop over the bits, which is built as a chain over the significand
    localparam bit FP_LZC_TREE = 1'b1;
    // FCVT / FCMP / FCLASS / FMV.X (latency 4) as a pipeline: operands are
    // registered in EX1, computed in EX2 and written in EX4. 0: computed in EX1 and delayed
    localparam bit FCVT_PIPE = 1'b1;
    // FCVT f->i / f->f split over EX2 (shift + rounding increment / normalization) and EX3 (range
    // check + negation / rounding); 0: computed in EX2
    localparam bit FCVT_PIPE2 = 1'b1;
    // FCVT.S.D denormalizes in EX2 (fp_round_den) so EX3 rounds without a shift; FCVT.D.S packs the normalized
    // significand (exact, never subnormal) instead of rounding
    localparam bit FCVT_DEN = 1'b1;
    // FCVT int->fp / FMV.W.X on ALU2 as a pipeline: EX1 normalization, EX2 rounding,
    // written in EX3. 0: computed in EX1 and delayed
    localparam bit I2F_PIPE = 1'b1;
    // Integer multiplier as a pipeline: EX1 Booth partial products + 3 CSA levels,
    // EX2 4 CSA levels, EX3 last level + final add, written in EX3 (wbpipe late entry).
    // 0: the full product in EX1 (combinational, delayed by registers)
    localparam bit MUL_PIPE = 1'b1;
    // unpacked operands of fp_misc (S and D views of a and b), registered between the FCVT stages
    typedef struct packed {
        logic s_sa, s_za, s_ia, s_na, s_sna, s_sb, s_zb, s_ib, s_nb, s_snb;
        logic d_sa, d_za, d_ia, d_na, d_sna, d_sb, d_zb, d_ib, d_nb, d_snb;
        logic signed [15:0] s_ea, s_eb, d_ea, d_eb;
        logic [23:0] s_ma, s_mb;
        logic [52:0] d_ma, d_mb;
    } fp_mu_t;
    // store pipeline: the memory-order violation check (LQ RAW query) is a stage after the address
    // generation (the address check is off the AGU path); the store is marked done in the ROB there. 0: both in the AGU stage
    localparam bit ST_CHECK_STAGE = 1'b1;
    // redirect selection by parallel age compares instead of a serial scan over the sources
    localparam bit REDIR_PAR = 1'b1;
    // the redirect being applied does not gate the candidates: the oldest of them is selected and
    // only the winner is checked against it (a killed candidate is younger than every surviving one,
    // so the result is the same). The MMIO replay candidate is registered first (its validity depends
    // on the load liveness, which includes the kill): an MMIO load replay redirects one cycle later
    localparam bit REDIR_KILL_LATE = 1'b1;
    // backward walk slots from one distance compare (slot i is valid when i < the remaining walk size)
    // instead of a per-slot chain of "t != walk_target; t = t - 1"; same result
    localparam bit WALK_PAR = 1'b1;
    // forward walk in two stages: the next batch (slots, ROB fields, allocation counts) is read from the ROB
    // into registers a cycle before it is applied to the RAT / free lists (one bubble at the walk start,
    // usually hidden by the frontend refill). 0: read and applied in the same cycle
    localparam bit FW_PIPE = 1'b1;
    // issue queue: the redirect squash is applied after the select (to the selected entry, by AND-OR of the
    // per-entry squash bits), not to each entry's ready bit; same result (entries are in program order)
    localparam bit IQ_KILL_LATE = 1'b1;
    // issue queue select -> wakeup -> ready loop: the wakeups an entry took in its enqueue cycle (ENQ_DELAY)
    // are kept as per-entry bits instead of being picked from the enqueue slots by the registered slot
    // one-hots; the "latency 1 and writes a register" bit of the selected uop is an AND-OR of per-entry bits
    // (no latency field compare after the select); the next ready bit is (valid && woken) OR the rest
    // (the wakeup compare enters last). Same cycle counts
    localparam bit IQ_WK_FAST = 1'b1;
    // issue queue: each source remembers which speculative-wakeup ports woke it last cycle, so a cancel is an
    // AND-OR of those bits with the cancel vector instead of a tag compare; same result
    localparam bit IQ_CAN_BIT = 1'b1;
    // wakeups of the dispatch cycle reach a new issue-queue entry one cycle later from registered copies
    // the select -> wakeup -> enqueue-ready loop is cut; same timing
    localparam bit ENQ_DELAY = 1'b1;
    // issue select as a one-hot vector (oldest ready entry by the age matrix) and the issued uop by AND-OR,
    // instead of a priority-encoded index and an index mux (shorter select -> wakeup path); same result
    localparam bit IQ_ONEHOT = 1'b1;
    // memory-order violation: the redirect being applied is checked on the selected (oldest) load only
    localparam bit VIOL_KILL_LATE = 1'b1;
    // memory-order violation: the younger loads are found from the store's LQ pointer (a
    // pointer mask) instead of per-entry ROB-order compares, the oldest hit as a one-hot vector + AND-OR
    localparam bit VIOL_LQMASK = 1'b1;
    // the violation check's address compare against the LQ in the store's AGU stage, registered for SC
    // (needs ST_CHECK_STAGE and VIOL_LQMASK); same result
    localparam bit VIOL_CAM_AGU = 1'b1;
    // the memory-order violation redirect is registered before the redirect selection: one more cycle to recover a violation
    localparam bit VIOL_REG = 1'b1;
    // rename accepts by group: ROB, LQ, SQ and both free lists must have
    // room for the whole DE group (its counts). 0: per-instruction prefix of the counts
    localparam bit REN_GROUP_ACC = 1'b1;
    // move elimination: an integer move (addi rd, rs, 0 / add rd, x0, rs) takes its
    // source's physical register as its destination, allocates nothing and is not issued. A register is
    // freed at commit only when no architectural register still maps to it (compared
    // against the committed table, one cycle after the commit)
    localparam bit MOVE_ELIM = 1'b1;
    // a move whose source is written by an earlier move in the same rename group is not eliminated (it executes
    // as an ALU op), so the renamed destinations do not form a chain through the group
    localparam bit MV_NOCHAIN = MOVE_ELIM;
    // writeback stage and operand bypass at register read: a uop takes its operands at RR from the register file, from the results of this
    // cycle (forward) or of the previous cycle (bypass) of the fixed-latency units, so EX has no
    // bypass mux; results are written to the register file and the ROB one cycle later (WB).
    // 0: register file and ROB written in the result cycle, bypass in EX
    localparam bit WB_STAGE = 1'b1;
    localparam int BTB_TGT_W   = 20;   // BTB target bits (2-byte units; upper bits from the CFI pc)
    localparam int LWT_N    = 64;   // load wait table (memory dependence predictor, MDP_STORESET = 0)
    // memory dependence prediction (StoreSet): SSIT maps load / store PCs to a store set,
    // LFST holds the last renamed store of each set; a load waits only for that store's address.
    // 0: load wait table (a marked load waits until every older store has its address)
    localparam bit MDP_STORESET = 1'b1;
    // the issue queue evaluates a load's store wait from the previous cycle's SQ state (registered;
    // the release is one cycle later). 0: from the current SQ state on the select path
    localparam bit LD_WAIT_REG = 1'b1;
    // the pc of a re-executed load (memory-order violation, MMIO replay) is read from the FTQ when the
    // redirect is applied (registered FTQ index + slot), not on the redirect-select path where the
    // index comes from the LQ priority encoder. 0: computed with the redirect
    localparam bit REDIR_PC_LATE = 1'b1;
    // forward-fail redirect: the store's pc for StoreSet training is read from the FTQ after the redirect is
    // registered (only the store's FTQ entry / slot are selected by the SQ match); same result
    localparam bit LF_STPC_LATE = 1'b1;
    // load forwarding: the youngest matching store of each byte as a one-hot vector (suffix OR), data and the
    // forward fail by AND-OR (the index loops were built as chains over the SQ entries); same result
    localparam bit FWD_ONEHOT = 1'b1;
    // load forward fail: any older store that matches the address and overlaps the load's bytes without its
    // data (not only the youngest one per byte): the fail no longer goes through the youngest-store
    // selection (that stays for the data only). Conservative (a younger store with data covering the bytes
    // still fails the load), as the AGU-stage prediction already is. Needs FWD_ONEHOT
    localparam bit FWD_FAIL_ANY = 1'b1;
    // RAW queue entries keep their load's LQ entry as a one-hot vector: the violation check puts the hits at
    // the LQ positions by AND-OR instead of index compares; same result
    localparam bit RAW_LQOH = 1'b1;
    localparam int SSIT_N  = 256;
    localparam int SSID_W  = 5;     // 32 store sets (LFST entries)
    // commit more than one CFI per cycle: committed CFIs go into a training queue in the frontend
    // (BPU tables are trained one CFI per cycle from the queue)
    localparam bit MULTI_CFI_COMMIT = 1'b1;
    localparam int TRQ_N   = 16;
    // predictor training: the training-queue head is registered with its table indices / tags, the
    // tables are read and written the next cycle (0: hashes, read and write in one cycle)
    localparam bit TRAIN_STAGE = 1'b1;
    // the training reads the BTB / TAGE / ITTAGE rows synchronously in the stage before (SRAM-style:
    // index registered, data the next cycle). A row written by the training
    // in the same cycle is read with its older value. Requires TRAIN_STAGE. 0: rows read in the
    // training cycle
    localparam bit TRAIN_SRAM = 1'b1;
    // the TAGE / ITTAGE useful bits of the trained rows are also read in the stage before (with the
    // other row fields) instead of in the training cycle. The allocation chain then starts from
    // registers. A row written by the training in the same cycle is read with its older value.
    // Requires TRAIN_SRAM
    localparam bit TRAIN_U_REG = 1'b1;
    // rename snapshots: RAT + free list after a branch / JALR;
    // a mispredict of that instruction restores them at once instead of walking the ROB
    localparam bit SNAP_EN = 1'b1;
    localparam int SNAP_N  = 4;
    // A redirect restores the youngest snapshot at or before the last kept instruction and then walks
    // forward (re-applies the renames between the snapshot and the redirect)
    // (SNAP_FWD = 0: exact hits only). SNAP_DIST: minimum instructions between snapshots; taking one
    // whenever a slot is free (0) was better than every 4 * DEC_W instructions:
    // CoreMark MM_SMALL 312,191 vs 312,552 cycles, random loop programs 285,695 vs 300,938.
    localparam bit SNAP_FWD  = 1'b1;
    // the restored snapshot is chosen as a one-hot: a snapshot is at or before the last kept instruction iff
    // the redirect does not kill it (one compare each, no decrement of the redirect position), and the
    // youngest of those is found from the snapshots' own order (independent of the redirect). Same choice
    localparam bit SNAP_SEL_OH = 1'b1;
    localparam int SNAP_DIST = 0;
    // separate BJU issue port + pipeline in the ALU0..ALU(N_BJU-1) issue queues (two dequeue
    // ports: ALUx + BJUx); 0: branches use the ALU issue slot and pipeline
    localparam bit BJU_PORT = 1'b1;
    // dispatch: the n-th uop of a class in a rename group goes to the n-th least occupied issue queue
    // of that class; 0: round-robin over the class's issue queues
    localparam bit IQ_BALANCE = 1'b1;

    // iterative units: bits per cycle
    localparam int DIV_U   = 4;     // integer divider
    // Integer divider: carry-save SRT (LZC pre stages, digit selection from a few top
    // bits of the redundant remainder, post correction, steps from the leading-zero difference).
    // 0: restoring divider (U full-width subtracts in series per cycle, fixed 64/U or 32/U cycles)
    localparam bit DIV_SRT = 1'b1;
    // integer divider (DIV_SRT): the two pre stages in one cycle (the dividend is normalized by its own
    // leading-zero count, then shifted by the pad of the step count to a multiple of U) and the two post
    // stages in one cycle (w and w + d summed in parallel): two cycles less per division
    localparam bit DIV_PRE1  = 1'b1;
    localparam bit DIV_POST1 = 1'b1;
    // integer divider: the next division starts while the previous one is in its last post stage (the result
    // stage is separate from the iteration engine). The issue queue holds DIV back unless the engine takes a
    // start two cycles later (acc2) and no DIV issued in the last two cycles. Needs DIV_SRT
    localparam bit DIV_OVL = 1'b1;
    localparam int FDIV_U  = 4;     // FDIV / FSQRT
    // FDIV / FSQRT: radix-2 SRT on a carry-save remainder with on-the-fly conversion of the quotient / root.
    // 0: restoring (U full-width compare-subtracts in series)
    localparam bit FDIV_SRT = 1'b1;
    // FDIV / FSQRT: a result that may be subnormal (decided from the exponent before the iterations end) takes one
    // more cycle (DEN) for the denormalization shift, so FIN only rounds (fp_round_fin_lim). Needs FDIV_SRT
    localparam bit FDIV_DEN = 1'b1;
    // FDIV / FSQRT: the next operation starts while the previous one is in POST (without DEN) or DEN (FIN keeps its own
    // copies of the operation's format, sign, rounding mode and special-case result). The issue queue holds FDIV back
    // unless the engine takes a start two cycles later (acc2) and no FDIV issued in the last two cycles. Needs FDIV_SRT
    localparam bit FDIV_OVL = 1'b1;

    // store address and store data in separate issue queues and pipelines (STA / STD): STD IQ k is
    // enqueued with every store enqueued into STA IQ k (same slots). The STA computes the
    // address (SQ address, violation check), the STD reads the data into the SQ; the store completes
    // when both have. A load whose youngest matching older store has no data yet is replayed (flushed;
    // LD_REPLAY makes most of them wait instead) and trains StoreSet, which then waits for address and data.
    // 0: one STU per store (address and data together)
    localparam bit STD_SPLIT = 1'b1;
    localparam int N_STD = STD_SPLIT ? N_STU : 0;
    // load replay queue for forward fails: a load whose older matching
    // store has no data yet waits in a small per-pipe queue until the data is in and is re-injected into
    // its load pipe (in RR, taking priority over the issue queue)
    // instead of being flushed. The fail is predicted in AGU against the then-SQ (registered: the SQ search
    // stays off the wakeup path); a fail only seen in MEM, or a full queue, still flushes. Needs STD_SPLIT
    localparam bit LD_REPLAY = STD_SPLIT;
    localparam int LRQ_N     = 4;      // entries per load pipe
    // committed-store buffer: committed stores leave the SQ (2 / cycle) into
    // SB_N line entries, merging into a line already held; a line is written to memory (one per cycle) when
    // the active count reaches SB_THRESH (registered), on a timeout, or to
    // drain for an MMIO access; the victim by a valid-aware tree PLRU. Loads forward from it below the SQ.
    // Lines are 16 B (one dword per data-memory bank, what one write cycle carries).
    // 0: committed stores are written from the SQ directly (2 / cycle, different banks)
    localparam bit SBUFFER    = 1'b1;
    // MMIO store written to its device from registers the cycle after it leaves the SQ (the data-memory write
    // port selection then does not depend on the SQ head); an MMIO load waits for it
    localparam bit MMIO_WREG = 1'b1;
    // the line matches of the SQ head stores against the buffer are computed the cycle before (for the
    // head positions 0..3 ahead, against the tags the buffer will hold, then selected by the head advance)
    // and registered: the enqueue starts from the registered match vectors instead of the SQ address read
    // and the tag compares. A store that leaves the SQ is committed, so its address was written at least
    // two cycles earlier
    localparam bit SB_MATCH_PRE = 1'b1;
    localparam int SB_N       = 16;
    localparam int SB_THRESH  = 9;
    localparam int SB_TIMEOUT = 1 << 20;
    // load queue split (RAW queue): a load that executes while an older store has no address yet
    // (the address-ready SQ pointer has not passed it) takes a RAW_N-entry queue entry with its address; the store
    // address check searches only these (the LQ keeps no address). Freed once every older store has its
    // address. A load that may find it full (fewer than 2 x N_LDU free, registered) is replayed until the
    // older stores have their addresses. No load-load (RAR) queue: with no cache, one core and MMIO loads
    // in order at the ROB head, loads cannot be reordered observably. Needs LD_REPLAY
    localparam bit RAWQ  = LD_REPLAY;
`ifndef MM_SMALL
    localparam int RAW_N = 56;
`else
    localparam int RAW_N = 8;
`endif
    // issue queues: 0..N_ALU-1 ALU (0..N_BJU-1 also branch), then LDU, STU (STA), STD, FEX
    localparam int IQ_LDU0 = N_ALU;
    localparam int IQ_STU0 = N_ALU + N_LDU;
    localparam int IQ_STD0 = N_ALU + N_LDU + N_STU;
    localparam int IQ_FEX0 = N_ALU + N_LDU + N_STU + N_STD;
    localparam int N_IQ    = IQ_FEX0 + N_FEX;
    localparam int DIV_IQ  = 1;     // ALU1 + DIV
    localparam int I2F_IQ  = 2;     // ALU2 + I2F

    // writeback ports (one per unit pipeline, plus one per iterative unit); each also drives one
    // wakeup port. Fixed-latency results wake their consumers 2 cycles before the write (EX bypass).
    localparam int WB_LDU0  = N_ALU;
    localparam int WB_FEX0  = N_ALU + N_LDU;
    localparam int WB_DIV   = WB_FEX0 + N_FEX;
    localparam int WB_FDIV0 = WB_DIV + 1;
    localparam int WB_UNC   = WB_FDIV0 + N_FDIV;     // uncached (MMIO) loads
    localparam int WB_BJU0  = WB_UNC + 1;            // BJU pipelines (link register), BJU_PORT only
    localparam int N_WB     = WB_BJU0 + (BJU_PORT ? N_BJU : 0);
    // register files a writeback port can write
    function automatic logic wb_writes_int(int q);
        if (q < N_ALU) return 1'b1;                          // ALU / MUL / DIV-less ALU pipes
        if (q < WB_FEX0) return 1'b1;                        // LDU
        if (q < WB_DIV) return (q == WB_FEX0);               // FEX0: FCVT / FCMP / FMV.X results
        if (q == WB_DIV) return 1'b1;
        if (q < WB_UNC) return 1'b0;                         // FDIV
        return 1'b1;                                         // uncached load, BJU
    endfunction
    function automatic logic wb_writes_fp(int q);
        if (q < N_ALU) return (q == I2F_IQ);                 // I2F
        if (q < WB_FEX0) return 1'b1;                        // LDU (FLW / FLD)
        if (q < WB_DIV) return 1'b1;                         // FEX
        if (q == WB_DIV) return 1'b0;
        if (q < WB_UNC) return 1'b1;                         // FDIV
        return (q == WB_UNC);                                // uncached load: FLW / FLD from MMIO
    endfunction
    localparam int N_WK     = N_WB;
    // loads wake their consumers in AGU (one cycle before the data), speculatively: a load that turns out not
    // to complete in MEM (replay queue, RAW queue full, MMIO) cancels the wakeup the next cycle, as a
    // latency-1 uop that lost a read port does. A consumer issued the cycle after the wakeup takes the value
    // from the WB stage register (bypass); later ones read the register file. Load-to-use 4 -> 3 cycles
    localparam bit LD_SPEC_WAKE = 1'b1;
    localparam int N_CAN    = N_ALU + (BJU_PORT ? N_BJU : 0) + (LD_SPEC_WAKE ? N_LDU : 0);   // speculative wakeups that can be cancelled
    // integer register-file read ports shared by the issue ports:
    // each register operand of an issue port has a fixed read port and priority; a uop whose
    // register operand loses its port is not issued that cycle and stays in its issue queue
    // (arbitration in the issue cycle, re-issue later). Operands that will come from the bypass
    // network and x0 do not read. 0: one read port per operand
    localparam bit IRP_ARB = 1'b1;
    // speculative wakeup: a latency-1 uop wakes its consumers when it is selected,
    // without waiting for the read-port arbitration; a loser's destination is cancelled the next cycle
    // in every issue queue and the busy table (consumers about to issue on it are held back). Longer
    // latencies schedule their wakeup from RR, after the arbitration. 0: the wakeup waits for the
    // arbitration result (it is in the select -> wakeup loop)
    localparam bit SPEC_WAKE = 1'b1;
    // busy table updated one cycle late: the wakeups and cancels of a cycle are registered and applied
    // the next cycle (the issue select -> wakeup -> busy-table decode path ends at a register).
    // Dispatch reads the table together with last cycle's registered wakeups / cancels / renamed
    // destinations, so readiness is the same as with the direct update
    localparam bit BUSY_DLY = 1'b1;
`ifndef MM_SMALL
    localparam int N_IRP = 12;      // 25 operands
`else
    localparam int N_IRP = 8;       // 16 operands
`endif
    // register cache: a small copy of recent integer results (8-wide: 24 entries written by the ALU-side
    // units, 12 by the loads) written together with the register file; an operand found in it at
    // issue does not request a read port and is read from the cache in RR
    localparam bit REGCACHE = 1'b1;
    localparam int RC_DI = 4;       // entries per ALU writeback port (8-wide: 6 x 4 = 24)
    localparam int RC_DM = 4;       // entries per load writeback port (8-wide: 3 x 4 = 12)
    localparam int RC_DB = 2;       // entries per BJU writeback port (link registers)
    // replacement: second chance (a hit keeps an entry); 0: round-robin
    localparam bit RC_REPL = 1'b1;
    // IQ entries keep a cache hit bit and entry index per source: set at dispatch from the tag lookup
    // and when the source's value is written into the cache, cleared when the entry is replaced; the issue
    // cycle only takes the selected entry's bit (no tag compare after the select). 0: tag compare at issue
    // (same result)
    localparam bit RC_TRACK = 1'b1;
    // entries: the ALU ports' (RC_DI each), the BJU ports' (RC_DB each, link registers), then the loads'
    localparam int N_RCB = (BJU_PORT ? N_BJU : 0) * RC_DB;
    localparam int N_RCI = N_ALU * RC_DI + N_RCB;
    localparam int N_RC  = N_RCI + N_LDU * RC_DM;
    localparam int RC_IW = $clog2(N_RC);
    localparam int N_RCW = N_ALU + (BJU_PORT ? N_BJU : 0) + N_LDU;     // writing ports
    function automatic int rc_wport(int k);     // writeback port of cache writer k
        if (k < N_ALU) return k;
        if (k < N_ALU + (BJU_PORT ? N_BJU : 0)) return WB_BJU0 + k - N_ALU;
        return WB_LDU0 + k - N_ALU - (BJU_PORT ? N_BJU : 0);
    endfunction
    // read port * 4 + priority (0 highest) of operand src (1, 2) of issue queue q's main (d = 0) or
    // BJU (d = 1) issue port; -1: no integer register read
    function automatic int irp_slot(int q, int d, int src);
`ifndef MM_SMALL
        // (port, priority): ALU0 (0,0)(1,0) BJU0 (1,1)(7,2) / ALU1 (2,0)(3,0) BJU1 (3,1)(9,2) /
        // ALU2 (4,0)(5,0) BJU2 (5,1)(11,2) / ALU3 (6,0)(7,1) / ALU4 (8,0)(9,1) / ALU5 (10,0)(11,1) /
        // LDU0 (7,0) / LDU1 (9,0) / LDU2 (11,0) / STA0 (6,1) / STA1 (8,1) / STD0 (0,1) / STD1 (2,1)
        if (q < N_BJU && d == 1) return (src == 1) ? (2 * q + 1) * 4 + 1 : (7 + 2 * q) * 4 + 2;
        if (q < 3)               return (src == 1) ? (2 * q) * 4 : (2 * q + 1) * 4;
        if (q < N_ALU)           return (src == 1) ? (2 * q) * 4 : (2 * q + 1) * 4 + 1;
        if (q < IQ_STU0)         return (7 + 2 * (q - IQ_LDU0)) * 4;
        if (q < IQ_STD0)         return (src == 1) ? (6 + 2 * (q - IQ_STU0)) * 4 + 1 : (2 * (q - IQ_STU0)) * 4 + 1;
        if (q < IQ_FEX0)         return (2 * (q - IQ_STD0)) * 4 + 1;      // STD: data (src 2)
`else
        // same pattern on 8 ports: ALU0 (0,0)(1,0) BJU0 (1,1)(5,2) / ALU1 (2,0)(3,0) BJU1 (3,1)(7,2) /
        // ALU2 (4,0)(5,1) / ALU3 (6,0)(7,1) / LDU0 (5,0) / LDU1 (7,0) / STU0 base (4,1) data (0,1)
        if (q < N_BJU && d == 1) return (src == 1) ? (2 * q + 1) * 4 + 1 : (5 + 2 * q) * 4 + 2;
        if (q < 2)               return (src == 1) ? (2 * q) * 4 : (2 * q + 1) * 4;
        if (q < N_ALU)           return (src == 1) ? (2 * q) * 4 : (2 * q + 1) * 4 + 1;
        if (q < IQ_STU0)         return (5 + 2 * (q - IQ_LDU0)) * 4;
        if (q < IQ_STD0)         return (src == 1) ? 4 * 4 + 1 : 0 * 4 + 1;
        if (q < IQ_FEX0)         return 0 * 4 + 1;                        // STD: data (src 2)
`endif
        return -1;
    endfunction
    // fixed-latency ports, whose consumers can issue before the register file is written and take
    // the value from the bypass network (loads, DIV, FDIV and MMIO loads wake up at their write)
    function automatic logic wb_fixed(int q);
        return q < WB_LDU0 || (q >= WB_FEX0 && q < WB_DIV) || q >= WB_BJU0;
    endfunction

    // execution latency in cycles (result written at issue + 1 + LAT)
    localparam int LAT_ALU  = 1;
    localparam int LAT_MUL  = 3;
    localparam int LAT_I2F  = 3;
    localparam int LAT_FALU = 2;    // FADD/FSUB/FSGNJ/FMIN/FMAX
    localparam int LAT_FMA  = FMA4 ? 4 : 3;   // FMUL/FMADD/... (FMA4: one more stage)
    localparam int LAT_FCVT = 4;    // FCVT / FCMP / FCLASS / FMV.X
    localparam int MAXL     = 4;

    // MMIO region [0x1000_0000, 0x2000_0000): loads there are uncached and non-speculative
    function automatic logic is_mmio(logic [63:0] a);
        return a[63:28] == 36'd1;
    endfunction

    // pointer widths (index + wrap flag); queues need not be powers of two
    localparam int ROB_PW  = $clog2(ROB_N) + 1;
    localparam int LQ_PW   = $clog2(LQ_N) + 1;
    localparam int SQ_PW   = $clog2(SQ_N) + 1;
    localparam int FTQ_PW  = $clog2(FTQ_N) + 1;
    localparam int IBUF_IW = $clog2(IBUF_N);
    localparam int PREG_W  = $clog2(PRF_N);

    typedef logic [ROB_PW-1:0] rob_ptr_t;
    typedef logic [LQ_PW-1:0]  lq_ptr_t;
    typedef logic [SQ_PW-1:0]  sq_ptr_t;
    typedef logic [FTQ_PW-1:0] ftq_ptr_t;
    typedef logic [PREG_W-1:0] preg_t;

    // functional unit type (dispatch class)
    typedef enum logic [3:0] {
        FU_ALU = 4'd0, FU_BJU = 4'd1, FU_LDU = 4'd2, FU_STU = 4'd3,
        FU_MUL = 4'd4, FU_DIV = 4'd5, FU_I2F = 4'd6,
        FU_FMAC = 4'd7,     // FALU + FMUL: FADD/FSUB/FMUL/FMA/FSGNJ/FMIN/FMAX (any FEX)
        FU_FCVT = 4'd8,     // FCVT/FCMP:   FEQ/FLT/FLE/FCLASS/FMV.X/FCVT f->i, f->f (FEX0)
        FU_FDIV = 4'd9,     // FDIV/FSQRT
        FU_CSR  = 4'd10     // Zicsr (ALU0): executes at the ROB head, blocks younger dispatch
    } fu_t;
    localparam int N_FU = 11;

    // FP operation
    typedef enum logic [4:0] {
        FOP_ADD, FOP_SUB, FOP_MUL, FOP_MADD, FOP_MSUB, FOP_NMSUB, FOP_NMADD,
        FOP_SGNJ, FOP_SGNJN, FOP_SGNJX, FOP_MIN, FOP_MAX,
        FOP_FEQ, FOP_FLT, FOP_FLE, FOP_CLASS, FOP_MVXF, FOP_F2I, FOP_F2F,
        FOP_MVFX, FOP_I2F, FOP_DIV, FOP_SQRT
    } fop_t;

    // units that can execute each class, per issue queue
    function automatic logic [N_FU-1:0] iq_cap(int q);
        logic [N_FU-1:0] c;
        c = '0;
        if (q < N_ALU) begin
            c[FU_ALU] = 1'b1;
            if (q == 0)             c[FU_CSR] = 1'b1;
            if (q < N_BJU)          c[FU_BJU] = 1'b1;
            if (q == DIV_IQ)        c[FU_DIV] = 1'b1;
            if (q == I2F_IQ)        c[FU_I2F] = 1'b1;
            if (q >= N_ALU - N_MUL) c[FU_MUL] = 1'b1;
        end else if (q < IQ_STU0) c[FU_LDU] = 1'b1;
        else if (q < IQ_STD0)     c[FU_STU] = 1'b1;
        else if (q < IQ_FEX0)     c = '0;            // STD: filled from the STA IQ, no class of its own
        else begin
            c[FU_FMAC] = 1'b1;
            if (q == IQ_FEX0) c[FU_FCVT] = 1'b1;
            if (q - IQ_FEX0 >= 1 && q - IQ_FEX0 <= N_FDIV) c[FU_FDIV] = 1'b1;
        end
        return c;
    endfunction
    function automatic logic iq_has(int q, int f);  // issue queue q serves class f
        logic [N_FU-1:0] c;
        c = iq_cap(q);
        return c[f];
    endfunction
    function automatic int class_n(int f);          // number of IQs serving class f
        int n;
        n = 0;
        for (int q = 0; q < N_IQ; q++) if (iq_has(q, f)) n++;
        return n;
    endfunction
    function automatic int class_iq(int f, int j);  // j-th IQ serving class f
        int n;
        n = 0;
        for (int q = 0; q < N_IQ; q++) if (iq_has(q, f)) begin
            if (n == j) return q;
            n++;
        end
        return 0;
    endfunction

    // CFI type kept in the BTB / ROB
    typedef enum logic [1:0] {CFI_BR = 2'd0, CFI_JAL = 2'd1, CFI_JALR = 2'd2, CFI_RET = 2'd3} cfi_t;

    // instruction leaving the IBuffer
    typedef struct packed {
        logic [31:0] insn;     // expanded to 32 bits if compressed
        logic        rvc;      // 16-bit instruction
        logic [63:0] pc;
        logic        pred_taken;   // predicted-taken CFI (the target is in the FTQ entry)
        ftq_ptr_t    ftq_idx;
        logic [SLOT_W-1:0] off;    // halfword slot in the fetch block: pc = FTQ start + 2 * off
    } fetch_t;

    // decoded instruction (mm_decode). Architectural register index {is_fp, reg}.
    typedef struct packed {
        logic [63:0] imm;
        logic [4:0]  alu_code;
        logic        op1_pc;
        logic        op2_imm;
        fu_t         fu;
        logic [2:0]  lat;      // fixed execution latency (0: LDU/STU/DIV/FDIV)
        logic        wen;      // allocates a destination register
        logic [5:0]  ldst;
        logic        use1, use2, use3;
        logic [5:0]  lsrc1, lsrc2, lsrc3;
        logic [2:0]  ld_type;
        logic [2:0]  st_type;
        logic        ld_fp32;  // FLW: NaN-box the loaded word
        logic        cfi;
        cfi_t        cfit;
        logic        is_call;
        logic        is_ret;
        fop_t        fop;
        logic        fmt;      // 0: S, 1: D (FCVT f->f / f<-i: destination format)
        logic [2:0]  rm;       // static rounding mode (dynamic -> frm = RNE)
        logic [1:0]  ityp;     // FCVT integer type: W, WU, L, LU
        logic [2:0]  mdfn;     // M extension / Zicsr funct3
        logic        word;     // *W
        logic        mv;       // MOVE_ELIM: integer register move (source in lsrc1)
    } dec_t;

    // micro-op in the issue queues and execution pipelines. The PC and the predicted target are not
    // carried: they are read from the FTQ PC memory with (ftq_idx, off), and the
    // immediate is kept in 32 bits (sign-extended where used).
    typedef struct packed {
        logic [31:0] imm;
        logic [4:0]  alu_code;
        logic        op1_pc;
        logic        op2_imm;
        fu_t         fu;
        logic [2:0]  lat;
        logic        rf_wen;
        preg_t       psrc1;
        preg_t       psrc2;
        preg_t       psrc3;
        preg_t       pdest;
        logic [2:0]  ld_type;
        logic [2:0]  st_type;
        logic        ld_fp32;
        fop_t        fop;
        logic        fmt;
        logic [2:0]  rm;
        logic [1:0]  ityp;
        logic [2:0]  mdfn;
        logic        word;
        logic        is_call;
        logic        is_ret;
        logic        pred_taken;
        ftq_ptr_t    ftq_idx;
        logic [SLOT_W-1:0] off;
        rob_ptr_t    rob_idx;
        lq_ptr_t     lq_ptr;   // load: own LQ entry; others: LQ tail at rename
        sq_ptr_t     sq_ptr;   // store: own SQ entry; others: SQ tail at rename
        logic        ld_wait;  // load predicted to depend on an older store (memory dependence predictor)
        sq_ptr_t     ld_wsq;   // StoreSet: the store it waits for (SQ entry + ROB index)
        rob_ptr_t    ld_wrob;
        logic        rvc;      // 16-bit instruction: link / fall-through = pc + 2
    } uop_t;

    // result on a writeback port (also used for the delayed-writeback pipelines)
    typedef struct packed {
        logic        v;
        logic        wen;
        preg_t       pdest;
        rob_ptr_t    rob;
        logic [63:0] val;
        logic [4:0]  fflags;   // FP exception flags, accumulated into fflags at commit
    } wb_t;

    // backend redirect (branch mispredict or memory-order violation)
    typedef struct packed {
        logic        valid;
        rob_ptr_t    rob_idx;
        logic        flush_self;   // 1: re-execute this instruction (load replay); 0: flush younger only
        logic [63:0] target;       //   (REDIR_PC_LATE and flush_self: from the FTQ entry + off when applied)
        logic [SLOT_W-1:0] off;    // slot of the instruction in its FTQ block (flush_self)
        ftq_ptr_t    ftq_idx;
        lq_ptr_t     lq_ptr;
        sq_ptr_t     sq_ptr;
        logic        is_call;
        logic        is_ret;
        logic [63:0] link;         // pc + 4 / pc + 2 (for RAS repair)
        logic        rvc;          // the redirecting CFI is compressed (cfi pc = link - 2)
        logic        taken;        // the redirecting CFI is taken
        logic        mdp_train;    // memory-order violation: train the dependence predictor
        logic [63:0] st_pc;        //   with the store that was violated
    } redirect_t;

    // ---------------- circular queue pointers {flag, index} ----------------
    // a is older than b
    function automatic logic rob_older(rob_ptr_t a, rob_ptr_t b);
        if (a[ROB_PW-1] == b[ROB_PW-1]) return a[ROB_PW-2:0] < b[ROB_PW-2:0];
        else                            return a[ROB_PW-2:0] > b[ROB_PW-2:0];
    endfunction
    function automatic rob_ptr_t rob_add(rob_ptr_t p, int n);   // 0 <= n <= ROB_N
        int i;
        i = int'(p[ROB_PW-2:0]) + n;
        if (i >= ROB_N) return {~p[ROB_PW-1], (ROB_PW-1)'(i - ROB_N)};
        else            return {p[ROB_PW-1],  (ROB_PW-1)'(i)};
    endfunction
    function automatic rob_ptr_t rob_sub1(rob_ptr_t p);
        if (p[ROB_PW-2:0] == '0) return {~p[ROB_PW-1], (ROB_PW-1)'(ROB_N - 1)};
        else                     return {p[ROB_PW-1], p[ROB_PW-2:0] - 1'b1};
    endfunction
    function automatic int rob_dist(rob_ptr_t h, rob_ptr_t t);   // entries in [h, t)
        if (h[ROB_PW-1] == t[ROB_PW-1]) return int'(t[ROB_PW-2:0]) - int'(h[ROB_PW-2:0]);
        else                            return ROB_N - int'(h[ROB_PW-2:0]) + int'(t[ROB_PW-2:0]);
    endfunction
    function automatic lq_ptr_t lq_add(lq_ptr_t p, int n);
        int i;
        i = int'(p[LQ_PW-2:0]) + n;
        if (i >= LQ_N) return {~p[LQ_PW-1], (LQ_PW-1)'(i - LQ_N)};
        else           return {p[LQ_PW-1],  (LQ_PW-1)'(i)};
    endfunction
    function automatic int lq_dist(lq_ptr_t h, lq_ptr_t t);
        if (h[LQ_PW-1] == t[LQ_PW-1]) return int'(t[LQ_PW-2:0]) - int'(h[LQ_PW-2:0]);
        else                          return LQ_N - int'(h[LQ_PW-2:0]) + int'(t[LQ_PW-2:0]);
    endfunction
    function automatic sq_ptr_t sq_add(sq_ptr_t p, int n);
        int i;
        i = int'(p[SQ_PW-2:0]) + n;
        if (i >= SQ_N) return {~p[SQ_PW-1], (SQ_PW-1)'(i - SQ_N)};
        else           return {p[SQ_PW-1],  (SQ_PW-1)'(i)};
    endfunction
    function automatic int sq_dist(sq_ptr_t h, sq_ptr_t t);
        if (h[SQ_PW-1] == t[SQ_PW-1]) return int'(t[SQ_PW-2:0]) - int'(h[SQ_PW-2:0]);
        else                          return SQ_N - int'(h[SQ_PW-2:0]) + int'(t[SQ_PW-2:0]);
    endfunction

    // uop with rob index r is squashed by redirect rd
    function automatic logic killed_by(redirect_t rd, rob_ptr_t r);
        return rd.valid && (rob_older(rd.rob_idx, r) || (rd.flush_self && rd.rob_idx == r));
    endfunction

endpackage
