// RV64IMFD_Zicsr decode: the RV64I decoder (decoder.sv) plus the M, F, D and Zicsr extensions
// (compressed instructions arrive already expanded by the IFU).
// Produces the dispatch class, the fixed latency, and the architectural register operands
// as {is_fp, index} (integer x0..x31 = 0..31, f0..f31 = 32..63).
module mm_decode
    import mm_pkg::*;
    import cpu_pkg::*;
(
    input  logic [31:0] insn,
    input  logic [2:0]  frm,       // dynamic rounding mode (a CSR write to frm blocks younger dispatch)
    output dec_t        d
);
    localparam logic [6:0] OP_LOADFP  = 7'b0000111;
    localparam logic [6:0] OP_STOREFP = 7'b0100111;
    localparam logic [6:0] OP_MADD    = 7'b1000011;
    localparam logic [6:0] OP_MSUB    = 7'b1000111;
    localparam logic [6:0] OP_NMSUB   = 7'b1001011;
    localparam logic [6:0] OP_NMADD   = 7'b1001111;
    localparam logic [6:0] OP_FP      = 7'b1010011;
    localparam logic [6:0] OP_SYSTEM  = 7'b1110011;

    logic [63:0] imm;
    logic [4:0]  alu_code;
    logic        op1_sel, op2_sel, reg_we;
    logic [2:0]  is_load, is_store;
    decoder dec (
        .insn, .imm, .alu_code, .alu_op1_sel(op1_sel), .alu_op2_sel(op2_sel), .reg_we,
        .is_load, .is_store
    );

    logic [6:0] opc;
    logic [4:0] rd, rs1, rs2, rs3, f5;
    logic [2:0] f3;
    assign opc = insn[6:0];
    assign rd  = insn[11:7];
    assign rs1 = insn[19:15];
    assign rs2 = insn[24:20];
    assign rs3 = insn[31:27];
    assign f3  = insn[14:12];
    assign f5  = insn[31:27];

    always_comb begin
        logic is_link_rd, is_link_rs1;
        is_link_rd  = (rd == 5'd1) || (rd == 5'd5);
        is_link_rs1 = (rs1 == 5'd1) || (rs1 == 5'd5);

        d          = '0;
        d.imm      = imm;
        d.alu_code = alu_code;
        d.op1_pc   = op1_sel;
        d.op2_imm  = op2_sel;
        d.fu       = FU_ALU;
        d.lat      = 3'(LAT_ALU);
        d.wen      = reg_we;
        d.ldst     = {1'b0, rd};
        d.lsrc1    = {1'b0, rs1};
        d.lsrc2    = {1'b0, rs2};
        d.lsrc3    = {1'b1, rs3};
        d.ld_type  = is_load;
        d.st_type  = is_store;
        d.cfit     = CFI_BR;
        d.fop      = FOP_ADD;
        d.fmt      = insn[25];
        d.rm       = (f3 == 3'd7) ? frm : f3;
        d.ityp     = rs2[1:0];
        d.mdfn     = f3;
        d.word     = (opc == OPREG32);

        unique case (opc)
            BRANCH: begin d.fu = FU_BJU; d.use1 = 1'b1; d.use2 = 1'b1; d.cfi = 1'b1; d.cfit = CFI_BR; end
            JAL:    begin d.fu = FU_BJU; d.cfi = 1'b1; d.cfit = CFI_JAL; d.is_call = is_link_rd; end
            JALR:   begin
                d.fu = FU_BJU; d.use1 = 1'b1; d.cfi = 1'b1;
                d.is_call = is_link_rd;
                d.is_ret  = (rd == 5'd0) && is_link_rs1;
                d.cfit    = d.is_ret ? CFI_RET : CFI_JALR;
            end
            LOAD:   begin d.fu = FU_LDU; d.lat = '0; d.use1 = 1'b1; end
            STORE:  begin d.fu = FU_STU; d.lat = '0; d.use1 = 1'b1; d.use2 = 1'b1; end
            OPREG, OPREG32: begin
                d.use1 = 1'b1; d.use2 = 1'b1;
                if (insn[31:25] == 7'b0000001) begin         // M extension
                    d.fu  = f3[2] ? FU_DIV : FU_MUL;
                    d.lat = f3[2] ? 3'd0 : 3'(LAT_MUL);
                end
            end
            OPIMM, OPIMM32: d.use1 = 1'b1;
            OP_SYSTEM: if (f3[1:0] != 2'b00) begin                // CSRRW/S/C[I]
                d.fu = FU_CSR; d.lat = 3'(LAT_ALU);
                d.use1 = !f3[2];
                d.wen = (rd != 5'd0); d.ldst = {1'b0, rd};
                d.imm = {47'd0, rs1, insn[31:20]};                 // {uimm / rs1 field, csr}
            end
            OP_LOADFP: begin                                  // FLW / FLD
                d.fu = FU_LDU; d.lat = '0; d.use1 = 1'b1;
                d.imm = {{52{insn[31]}}, insn[31:20]};
                d.ld_type = (f3 == 3'd2) ? LOAD_LWU : LOAD_LD;
                d.ld_fp32 = (f3 == 3'd2);
                d.wen = 1'b1; d.ldst = {1'b1, rd};
            end
            OP_STOREFP: begin                                 // FSW / FSD
                d.fu = FU_STU; d.lat = '0; d.use1 = 1'b1; d.use2 = 1'b1;
                d.lsrc2 = {1'b1, rs2};
                d.imm = {{52{insn[31]}}, insn[31:25], insn[11:7]};
                d.st_type = (f3 == 3'd2) ? STORE_SW : STORE_SD;
            end
            OP_MADD, OP_MSUB, OP_NMSUB, OP_NMADD: begin
                d.fu = FU_FMAC; d.lat = 3'(LAT_FMA);
                d.use1 = 1'b1; d.use2 = 1'b1; d.use3 = 1'b1;
                d.lsrc1 = {1'b1, rs1}; d.lsrc2 = {1'b1, rs2};
                d.wen = 1'b1; d.ldst = {1'b1, rd};
                d.fop = (opc == OP_MADD) ? FOP_MADD : (opc == OP_MSUB) ? FOP_MSUB :
                        (opc == OP_NMSUB) ? FOP_NMSUB : FOP_NMADD;
            end
            OP_FP: begin
                d.use1 = 1'b1; d.lsrc1 = {1'b1, rs1}; d.lsrc2 = {1'b1, rs2};
                d.wen = 1'b1; d.ldst = {1'b1, rd};
                d.fu = FU_FMAC; d.lat = 3'(LAT_FALU);
                unique case (f5)
                    5'h00: begin d.fop = FOP_ADD; d.use2 = 1'b1; end
                    5'h01: begin d.fop = FOP_SUB; d.use2 = 1'b1; end
                    5'h02: begin d.fop = FOP_MUL; d.use2 = 1'b1; d.lat = 3'(LAT_FMA); end
                    5'h03: begin d.fop = FOP_DIV; d.use2 = 1'b1; d.fu = FU_FDIV; d.lat = '0; end
                    5'h0b: begin d.fop = FOP_SQRT; d.fu = FU_FDIV; d.lat = '0; end
                    5'h04: begin
                        d.use2 = 1'b1;
                        d.fop = (f3 == 3'd0) ? FOP_SGNJ : (f3 == 3'd1) ? FOP_SGNJN : FOP_SGNJX;
                    end
                    5'h05: begin d.use2 = 1'b1; d.fop = f3[0] ? FOP_MAX : FOP_MIN; end
                    5'h08: begin d.fop = FOP_F2F; d.fu = FU_FCVT; d.lat = 3'(LAT_FCVT); end
                    5'h14: begin
                        d.use2 = 1'b1; d.fu = FU_FCVT; d.lat = 3'(LAT_FCVT);
                        d.fop = (f3 == 3'd2) ? FOP_FEQ : (f3 == 3'd1) ? FOP_FLT : FOP_FLE;
                        d.wen = (rd != 5'd0); d.ldst = {1'b0, rd};
                    end
                    5'h18: begin
                        d.fop = FOP_F2I; d.fu = FU_FCVT; d.lat = 3'(LAT_FCVT);
                        d.wen = (rd != 5'd0); d.ldst = {1'b0, rd};
                    end
                    5'h1c: begin
                        d.fop = f3[0] ? FOP_CLASS : FOP_MVXF; d.fu = FU_FCVT; d.lat = 3'(LAT_FCVT);
                        d.wen = (rd != 5'd0); d.ldst = {1'b0, rd};
                    end
                    5'h1a: begin d.fop = FOP_I2F;  d.fu = FU_I2F; d.lat = 3'(LAT_I2F); d.lsrc1 = {1'b0, rs1}; end
                    5'h1e: begin d.fop = FOP_MVFX; d.fu = FU_I2F; d.lat = 3'(LAT_I2F); d.lsrc1 = {1'b0, rs1}; end
                    default: begin d.wen = 1'b0; d.use1 = 1'b0; end   // unsupported: no-op
                endcase
            end
            default: ;
        endcase
        // MOVE_ELIM: addi rd, rs, 0 / add rd, x0, rs / add rd, rs, x0 (rd != x0)
        if (MOVE_ELIM && rd != 5'd0) begin
            if (opc == OPIMM && f3 == 3'd0 && imm == '0) d.mv = 1'b1;
            if (opc == OPREG && f3 == 3'd0 && insn[31:25] == 7'd0 && (rs1 == 5'd0 || rs2 == 5'd0)) begin
                d.mv = 1'b1;
                d.lsrc1 = {1'b0, (rs1 == 5'd0) ? rs2 : rs1};
                d.lsrc2 = '0;          // add rd, rs, x0: the same op if it is executed (MV_NOCHAIN)
            end
        end
    end
endmodule
