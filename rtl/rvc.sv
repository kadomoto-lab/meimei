// RVC (RV64C) expander: 16-bit compressed instruction -> equivalent 32-bit instruction.
// Used by the IFU (predecode), so the backend only sees 32-bit encodings plus an "rvc" flag
// (the instruction length matters for link values and the fall-through pc).
// Reserved / illegal encodings expand to 0 (decoded as a no-op: there are no traps).
package mm_rvc_pkg;

    function automatic logic [31:0] enc_i(logic [11:0] imm, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op);
        return {imm, rs1, f3, rd, op};
    endfunction
    function automatic logic [31:0] enc_s(logic [11:0] imm, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [6:0] op);
        return {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    endfunction
    function automatic logic [31:0] enc_r(logic [6:0] f7, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3, logic [4:0] rd, logic [6:0] op);
        return {f7, rs2, rs1, f3, rd, op};
    endfunction
    function automatic logic [31:0] enc_b(logic [12:0] imm, logic [4:0] rs2, logic [4:0] rs1, logic [2:0] f3);
        return {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
    endfunction
    function automatic logic [31:0] enc_j(logic [20:0] imm, logic [4:0] rd);
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    function automatic logic [31:0] rvc_expand(logic [15:0] h);
        logic [2:0]  f3;
        logic [4:0]  rd, rs2, rdp, rs1p, rs2p;
        logic [11:0] imm6, nz4spn, uw, ud, ldsp, lwsp, sdsp, swsp, nz16;
        logic [5:0]  sh;
        logic [12:0] boff;
        logic [20:0] joff;
        f3   = h[15:13];
        rd   = h[11:7];
        rs2  = h[6:2];
        rdp  = {2'b01, h[4:2]};
        rs1p = {2'b01, h[9:7]};
        rs2p = {2'b01, h[4:2]};
        imm6   = {{7{h[12]}}, h[6:2]};
        nz4spn = {2'b00, h[10:7], h[12:11], h[5], h[6], 2'b00};
        uw     = {5'd0, h[5], h[12:10], h[6], 2'b00};
        ud     = {4'd0, h[6:5], h[12:10], 3'b000};
        ldsp   = {3'd0, h[4:2], h[12], h[6:5], 3'b000};
        lwsp   = {4'd0, h[3:2], h[12], h[6:4], 2'b00};
        sdsp   = {3'd0, h[9:7], h[12:10], 3'b000};
        swsp   = {4'd0, h[8:7], h[12:9], 2'b00};
        nz16   = {{3{h[12]}}, h[4:3], h[5], h[2], h[6], 4'b0000};
        sh     = {h[12], h[6:2]};
        boff   = {{5{h[12]}}, h[6:5], h[2], h[11:10], h[4:3], 1'b0};
        joff   = {{10{h[12]}}, h[8], h[10:9], h[6], h[7], h[2], h[11], h[5:3], 1'b0};
        rvc_expand = '0;
        unique case (h[1:0])
            2'b00: unique case (f3)
                3'd0: if (nz4spn != '0) rvc_expand = enc_i(nz4spn, 5'd2, 3'd0, rdp, 7'b0010011);   // C.ADDI4SPN
                3'd1: rvc_expand = enc_i(ud, rs1p, 3'd3, rdp, 7'b0000111);                         // C.FLD
                3'd2: rvc_expand = enc_i(uw, rs1p, 3'd2, rdp, 7'b0000011);                         // C.LW
                3'd3: rvc_expand = enc_i(ud, rs1p, 3'd3, rdp, 7'b0000011);                         // C.LD
                3'd5: rvc_expand = enc_s(ud, rs2p, rs1p, 3'd3, 7'b0100111);                        // C.FSD
                3'd6: rvc_expand = enc_s(uw, rs2p, rs1p, 3'd2, 7'b0100011);                        // C.SW
                3'd7: rvc_expand = enc_s(ud, rs2p, rs1p, 3'd3, 7'b0100011);                        // C.SD
                default: ;
            endcase
            2'b01: unique case (f3)
                3'd0: rvc_expand = enc_i(imm6, rd, 3'd0, rd, 7'b0010011);                          // C.ADDI
                3'd1: if (rd != '0) rvc_expand = enc_i(imm6, rd, 3'd0, rd, 7'b0011011);            // C.ADDIW
                3'd2: rvc_expand = enc_i(imm6, 5'd0, 3'd0, rd, 7'b0010011);                        // C.LI
                3'd3: begin
                    if (rd == 5'd2) begin
                        if (nz16 != '0) rvc_expand = enc_i(nz16, 5'd2, 3'd0, 5'd2, 7'b0010011);    // C.ADDI16SP
                    end else if (imm6 != '0) begin
                        rvc_expand = {{15{h[12]}}, h[6:2], rd, 7'b0110111};                        // C.LUI
                    end
                end
                3'd4: unique case (h[11:10])
                    2'd0: rvc_expand = enc_i({6'd0, sh}, rs1p, 3'd5, rs1p, 7'b0010011);            // C.SRLI
                    2'd1: rvc_expand = enc_i({6'b010000, sh}, rs1p, 3'd5, rs1p, 7'b0010011);       // C.SRAI
                    2'd2: rvc_expand = enc_i(imm6, rs1p, 3'd7, rs1p, 7'b0010011);                  // C.ANDI
                    default: begin
                        if (!h[12]) unique case (h[6:5])
                            2'd0: rvc_expand = enc_r(7'h20, rs2p, rs1p, 3'd0, rs1p, 7'b0110011);   // C.SUB
                            2'd1: rvc_expand = enc_r(7'h00, rs2p, rs1p, 3'd4, rs1p, 7'b0110011);   // C.XOR
                            2'd2: rvc_expand = enc_r(7'h00, rs2p, rs1p, 3'd6, rs1p, 7'b0110011);   // C.OR
                            default: rvc_expand = enc_r(7'h00, rs2p, rs1p, 3'd7, rs1p, 7'b0110011);// C.AND
                        endcase
                        else if (h[6:5] == 2'd0) rvc_expand = enc_r(7'h20, rs2p, rs1p, 3'd0, rs1p, 7'b0111011);  // C.SUBW
                        else if (h[6:5] == 2'd1) rvc_expand = enc_r(7'h00, rs2p, rs1p, 3'd0, rs1p, 7'b0111011);  // C.ADDW
                    end
                endcase
                3'd5: rvc_expand = enc_j(joff, 5'd0);                                              // C.J
                3'd6: rvc_expand = enc_b(boff, 5'd0, rs1p, 3'd0);                                  // C.BEQZ
                default: rvc_expand = enc_b(boff, 5'd0, rs1p, 3'd1);                               // C.BNEZ
            endcase
            2'b10: unique case (f3)
                3'd0: rvc_expand = enc_i({6'd0, sh}, rd, 3'd1, rd, 7'b0010011);                    // C.SLLI
                3'd1: rvc_expand = enc_i(ldsp, 5'd2, 3'd3, rd, 7'b0000111);                        // C.FLDSP
                3'd2: if (rd != '0) rvc_expand = enc_i(lwsp, 5'd2, 3'd2, rd, 7'b0000011);          // C.LWSP
                3'd3: if (rd != '0) rvc_expand = enc_i(ldsp, 5'd2, 3'd3, rd, 7'b0000011);          // C.LDSP
                3'd4: begin
                    if (!h[12]) begin
                        if (rs2 == '0) begin
                            if (rd != '0) rvc_expand = enc_i(12'd0, rd, 3'd0, 5'd0, 7'b1100111);   // C.JR
                        end else rvc_expand = enc_r(7'h00, rs2, 5'd0, 3'd0, rd, 7'b0110011);       // C.MV
                    end else begin
                        if (rs2 == '0) begin
                            if (rd != '0) rvc_expand = enc_i(12'd0, rd, 3'd0, 5'd1, 7'b1100111);   // C.JALR
                            else          rvc_expand = 32'h00100073;                               // C.EBREAK
                        end else rvc_expand = enc_r(7'h00, rs2, rd, 3'd0, rd, 7'b0110011);         // C.ADD
                    end
                end
                3'd5: rvc_expand = enc_s(sdsp, rs2, 5'd2, 3'd3, 7'b0100111);                       // C.FSDSP
                3'd6: rvc_expand = enc_s(swsp, rs2, 5'd2, 3'd2, 7'b0100011);                       // C.SWSP
                default: rvc_expand = enc_s(sdsp, rs2, 5'd2, 3'd3, 7'b0100011);                    // C.SDSP
            endcase
            default: ;
        endcase
    endfunction
endpackage
