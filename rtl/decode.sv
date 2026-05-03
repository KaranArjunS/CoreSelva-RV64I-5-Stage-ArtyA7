module decode (
    input  logic [31:0] instr,

    output logic [4:0] rs1, rs2, rd,
    output logic [2:0] funct3,
    output logic [6:0] funct7, opcode,
    output logic [63:0] imm,

    output logic reg_write, mem_read, mem_write,
    output logic mem_to_reg, alu_src, branch, jump,
    output logic [4:0] alu_op
);

    // -------------------------
    // Field extraction
    // -------------------------
    assign opcode = instr[6:0];
    assign rd     = instr[11:7];
    assign funct3 = instr[14:12];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct7 = instr[31:25];

    // -------------------------
    // ALU ops
    // -------------------------
    localparam ADD    = 5'd0,  SUB    = 5'd1,  AND    = 5'd2;
    localparam OR     = 5'd3,  XOR    = 5'd4,  SLL    = 5'd5;
    localparam SRL    = 5'd6,  SRA    = 5'd7,  SLT    = 5'd8;
    localparam SLTU   = 5'd9,  LUI    = 5'd10, AUIPC  = 5'd11;
    localparam ADDW   = 5'd12, SUBW   = 5'd13;
    localparam SLLW   = 5'd14, SRLW   = 5'd15, SRAW   = 5'd16;

    logic [63:0] imm_raw;
    logic [63:0] shamt;
    logic use_shamt;

    // -------------------------
    // Immediate generation
    // -------------------------
    always_comb begin
        imm_raw  = 64'd0;
        shamt    = 64'd0;
        use_shamt = 0;

        case (opcode)

            // I-type
            7'b0010011, 7'b0000011, 7'b1100111, 7'b0011011: begin
                imm_raw = {{52{instr[31]}}, instr[31:20]};

                // Shift immediate detection
                if (funct3 == 3'b001 || funct3 == 3'b101) begin
                    use_shamt = 1;
                    shamt     = {58'd0, instr[25:20]};
                end
            end

            // S-type
            7'b0100011:
                imm_raw = {{52{instr[31]}}, instr[31:25], instr[11:7]};

            // B-type
            7'b1100011:
                imm_raw = {{51{instr[31]}},
                           instr[31],
                           instr[7],
                           instr[30:25],
                           instr[11:8],
                           1'b0};

            // U-type (NO forced sign extension)
            7'b0110111, 7'b0010111:
                imm_raw = {instr[31:12], 12'b0};

            // J-type
            7'b1101111:
                imm_raw = {{43{instr[31]}},
                           instr[31],
                           instr[19:12],
                           instr[20],
                           instr[30:21],
                           1'b0};

            default:
                imm_raw = 64'd0;
        endcase
    end

    assign imm = use_shamt ? shamt : imm_raw;

    // -------------------------
    // Control logic
    // -------------------------
    always_comb begin
        reg_write  = 0;
        mem_read   = 0;
        mem_write  = 0;
        mem_to_reg = 0;
        alu_src    = 0;
        branch     = 0;
        jump       = 0;
        alu_op     = ADD;

        case (opcode)

            // R-type
            7'b0110011: begin
                reg_write = 1;
                case (funct3)
                    3'b000: alu_op = funct7[5] ? SUB : ADD;
                    3'b001: alu_op = SLL;
                    3'b010: alu_op = SLT;
                    3'b011: alu_op = SLTU;
                    3'b100: alu_op = XOR;
                    3'b101: alu_op = funct7[5] ? SRA : SRL;
                    3'b110: alu_op = OR;
                    3'b111: alu_op = AND;
                endcase
            end

            // R-type W
            7'b0111011: begin
                reg_write = 1;
                case (funct3)
                    3'b000: alu_op = funct7[5] ? SUBW : ADDW;
                    3'b001: alu_op = SLLW;
                    3'b101: alu_op = funct7[5] ? SRAW : SRLW;
                endcase
            end

            // I-type
            7'b0010011: begin
                reg_write = 1;
                alu_src   = 1;
                case (funct3)
                    3'b000: alu_op = ADD;
                    3'b010: alu_op = SLT;
                    3'b011: alu_op = SLTU;
                    3'b100: alu_op = XOR;
                    3'b110: alu_op = OR;
                    3'b111: alu_op = AND;
                    3'b001: alu_op = SLL;
                    3'b101: alu_op = funct7[5] ? SRA : SRL;
                endcase
            end

            // I-type W
            7'b0011011: begin
                reg_write = 1;
                alu_src   = 1;
                case (funct3)
                    3'b000: alu_op = ADDW;
                    3'b001: alu_op = SLLW;
                    3'b101: alu_op = funct7[5] ? SRAW : SRLW;
                endcase
            end

            // LOAD
            7'b0000011: begin
                reg_write  = 1;
                mem_read   = 1;
                mem_to_reg = 1;
                alu_src    = 1;
            end

            // STORE
            7'b0100011: begin
                mem_write = 1;
                alu_src   = 1;
            end

            // BRANCH
            7'b1100011: begin
                branch = 1;
                alu_op = SUB;
            end

            // JAL
            7'b1101111: begin
                jump      = 1;
                reg_write = 1;
            end

            // JALR
            7'b1100111: begin
                jump      = 1;
                reg_write = 1;
                alu_src   = 1;
            end

            // LUI
            7'b0110111: begin
                reg_write = 1;
                alu_src   = 1;
                alu_op    = LUI;
            end

            // AUIPC
            7'b0010111: begin
                reg_write = 1;
                alu_src   = 1;
                alu_op    = AUIPC;
            end

        endcase
    end

endmodule