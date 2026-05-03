module execute (
    input  logic [63:0] a,
    input  logic [63:0] b,
    input  logic [63:0] imm,
    input  logic        alu_src,
    input  logic [3:0]  alu_op,
    input  logic        branch,
    input  logic        jump,
    input  logic [2:0]  funct3,
    input  logic [6:0]  opcode,
    input  logic [63:0] pc,
    output logic [63:0] alu_out,
    output logic        branch_taken,
    output logic [63:0] target
);

    logic [63:0] op2;

    assign op2 = alu_src ? imm : b;

    // ALU - all 12 RV64I ops
    always_comb begin
        case (alu_op)
            4'd0:  alu_out = a + op2;
            4'd1:  alu_out = a - op2;
            4'd2:  alu_out = a & op2;
            4'd3:  alu_out = a | op2;
            4'd4:  alu_out = a ^ op2;
            4'd5:  alu_out = a << op2[5:0];
            4'd6:  alu_out = a >> op2[5:0];
            4'd7:  alu_out = $signed(a) >>> op2[5:0];
            4'd8:  alu_out = ($signed(a) < $signed(op2)) ? 64'd1 : 64'd0;
            4'd9:  alu_out = (a < op2)                   ? 64'd1 : 64'd0;
            4'd10: alu_out = op2;           // LUI  - imm direct (alu_src=1)
            4'd11: alu_out = pc + op2;      // AUIPC
            default: alu_out = 64'd0;
        endcase
    end

    // Branch condition
    always_comb begin
        branch_taken = 0;
        if (branch) begin
            case (funct3)
                3'b000: branch_taken = (a == b);
                3'b001: branch_taken = (a != b);
                3'b100: branch_taken = ($signed(a) <  $signed(b));
                3'b101: branch_taken = ($signed(a) >= $signed(b));
                3'b110: branch_taken = (a <  b);
                3'b111: branch_taken = (a >= b);
                default: branch_taken = 0;
            endcase
        end
    end

    // Target PC
    always_comb begin
        target = 64'd0;
        if (branch && branch_taken)
            target = pc + imm;
        else if (jump) begin
            if (opcode == 7'b1100111)
                target = (a + imm) & ~64'd1;   // JALR
            else
                target = pc + imm;              // JAL
        end
    end

endmodule