module alu
    import cpu_pkg::*;
(
    input logic [4:0] alu_code,
    input logic [XLEN-1:0] op1,
    input logic [XLEN-1:0] op2,
    output logic [XLEN-1:0] alu_result,
    output logic br_taken
);

    // word (32-bit) results for the *W instructions
    logic [31:0] add_w, sub_w, sll_w, srl_w, sra_w;

    assign add_w = op1[31:0] + op2[31:0];
    assign sub_w = op1[31:0] - op2[31:0];
    assign sll_w = op1[31:0] << op2[4:0];
    assign srl_w = op1[31:0] >> op2[4:0];
    assign sra_w = signed'(op1[31:0]) >>> op2[4:0];

    always_comb begin
        unique case (alu_code)
            ALU_ADD: alu_result = op1 + op2;
            ALU_SUB: alu_result = op1 - op2;
            ALU_XOR: alu_result = op1 ^ op2;
            ALU_OR: alu_result = op1 | op2;
            ALU_AND: alu_result = op1 & op2;
            ALU_SLT: alu_result = (signed'(op1) < signed'(op2)) ? XLEN'(1) : XLEN'(0);
            ALU_SLTU: alu_result = (op1 < op2) ? XLEN'(1) : XLEN'(0);
            ALU_SLL: alu_result = op1 << op2[5:0];
            ALU_SRL: alu_result = op1 >> op2[5:0];
            ALU_SRA: alu_result = signed'(op1) >>> op2[5:0];
            ALU_LUI: alu_result = op2;
            ALU_JAL, ALU_JALR: alu_result = op1 + XLEN'(4);
            ALU_ADDW: alu_result = {{32{add_w[31]}}, add_w};
            ALU_SUBW: alu_result = {{32{sub_w[31]}}, sub_w};
            ALU_SLLW: alu_result = {{32{sll_w[31]}}, sll_w};
            ALU_SRLW: alu_result = {{32{srl_w[31]}}, srl_w};
            ALU_SRAW: alu_result = {{32{sra_w[31]}}, sra_w};
            default: alu_result = '0;
        endcase
    end

    always_comb begin
        unique case (alu_code)
            ALU_BEQ: br_taken = (op1 == op2);
            ALU_BNE: br_taken = (op1 != op2);
            ALU_BLT: br_taken = (signed'(op1) < signed'(op2));
            ALU_BGE: br_taken = (signed'(op1) >= signed'(op2));
            ALU_BLTU: br_taken = (op1 < op2);
            ALU_BGEU: br_taken = (op1 >= op2);
            ALU_JAL, ALU_JALR: br_taken = ENABLE;
            default: br_taken = DISABLE;
        endcase
    end

endmodule
