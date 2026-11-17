package cpu_pkg;

    localparam int XLEN = 64;

    // control signals
    typedef enum logic {
        DISABLE = 1'b0,
        ENABLE  = 1'b1
    } ctrl_t;

    // op_code
    typedef enum logic [6:0] {
        OPIMM   = 7'b0010011,
        OPIMM32 = 7'b0011011,   // RV64I: ADDIW, SLLIW, SRLIW, SRAIW
        OPREG   = 7'b0110011,
        OPREG32 = 7'b0111011,   // RV64I: ADDW, SUBW, SLLW, SRLW, SRAW
        LUI     = 7'b0110111,
        AUIPC   = 7'b0010111,
        LOAD    = 7'b0000011,
        STORE   = 7'b0100011,
        BRANCH  = 7'b1100011,
        JAL     = 7'b1101111,
        JALR    = 7'b1100111
    } op_code_t;

    // alu_code
    typedef enum logic [4:0] {
        ALU_ADD  = 5'd0,
        ALU_SUB  = 5'd1,
        ALU_XOR  = 5'd2,
        ALU_OR   = 5'd3,
        ALU_AND  = 5'd4,
        ALU_SLT  = 5'd5,
        ALU_SLTU = 5'd6,
        ALU_SLL  = 5'd7,
        ALU_SRL  = 5'd8,
        ALU_SRA  = 5'd9,
        ALU_LUI  = 5'd10,
        ALU_BEQ  = 5'd11,
        ALU_BNE  = 5'd12,
        ALU_BLT  = 5'd13,
        ALU_BGE  = 5'd14,
        ALU_BLTU = 5'd15,
        ALU_BGEU = 5'd16,
        ALU_JAL  = 5'd17,
        ALU_JALR = 5'd18,
        ALU_ADDW = 5'd19,       // RV64I word operations (32-bit result, sign-extended)
        ALU_SUBW = 5'd20,
        ALU_SLLW = 5'd21,
        ALU_SRLW = 5'd22,
        ALU_SRAW = 5'd23
    } alu_code_t;

    // alu_op1
    typedef enum logic {
        ALU_OP1_RS1 = 1'b0,
        ALU_OP1_PC  = 1'b1
    } alu_op1_t;

    // alu_op2
    typedef enum logic {
        ALU_OP2_RS2 = 1'b0,
        ALU_OP2_IMM = 1'b1
    } alu_op2_t;

    // load
    typedef enum logic [2:0] {
        LOAD_DISABLE = 3'b000,
        LOAD_LB      = 3'b001,
        LOAD_LH      = 3'b010,
        LOAD_LW      = 3'b011,
        LOAD_LD      = 3'b100,  // RV64I
        LOAD_LBU     = 3'b101,
        LOAD_LHU     = 3'b110,
        LOAD_LWU     = 3'b111   // RV64I
    } load_type_t;

    // store (widened to 3 bits for SD)
    typedef enum logic [2:0] {
        STORE_DISABLE = 3'b000,
        STORE_SB      = 3'b001,
        STORE_SH      = 3'b010,
        STORE_SW      = 3'b011,
        STORE_SD      = 3'b100  // RV64I
    } store_type_t;

endpackage
