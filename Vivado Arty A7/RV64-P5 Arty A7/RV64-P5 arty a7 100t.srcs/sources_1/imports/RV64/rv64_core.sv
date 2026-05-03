module rv64_core (
    input  logic clk,
    input  logic rst,
    output logic [6:0] seg
);

// ========a=================
// PC
// =========================
logic [63:0] pc, pc_next;

always_ff @(posedge clk or posedge rst) begin
    if (rst)
        pc <= 0;
    else if (flush)
        pc <= pc_next;
    else if (!stall)
        pc <= pc_next;
end

// =========================
// MEMORY
// =========================
logic [31:0] imem [0:1023];
logic [63:0] dmem [0:1023];

initial begin
    $readmemh("program.mem", imem);
end

initial begin
    integer i;
    for (i = 0; i < 1024; i = i + 1)
        dmem[i] = 64'd0;
end

// =========================
// PIPELINE REGS
// =========================
typedef struct packed {
    logic [63:0] pc;
    logic [31:0] instr;
} if_id_t;

typedef struct packed {
    logic [63:0] pc;
    logic [63:0] rs1_val, rs2_val;
    logic [63:0] imm;
    logic [4:0]  rs1, rs2, rd;
    logic [2:0]  funct3;
    logic [6:0]  funct7, opcode;
    logic        reg_write, mem_read, mem_write;
    logic        mem_to_reg, alu_src, branch, jump;
    logic [3:0]  alu_op;
} id_ex_t;

typedef struct packed {
    logic [63:0] alu_out;
    logic [63:0] rs2_val;
    logic [4:0]  rd;
    logic        reg_write, mem_read, mem_write, mem_to_reg;
    logic        jump, branch;
    logic        branch_taken;
    logic [63:0] target;
    logic [2:0]  funct3;
    logic [63:0] pc;
} ex_mem_t;

typedef struct packed {
    logic [63:0] alu_out;
    logic [63:0] mem_data;
    logic [4:0]  rd;
    logic        reg_write, mem_to_reg;
    logic        jump;
    logic [63:0] pc;
} mem_wb_t;

if_id_t  if_id;
id_ex_t  id_ex;
ex_mem_t ex_mem;
mem_wb_t mem_wb;

// =========================
// REGFILE
// =========================
logic [63:0] rs1_data, rs2_data, wb_data;

regfile rf (
    .clk(clk),
    .we(mem_wb.reg_write),
    .rs1(if_id.instr[19:15]),
    .rs2(if_id.instr[24:20]),
    .rd(mem_wb.rd),
    .wd(wb_data),
    .rd1(rs1_data),
    .rd2(rs2_data)
);

// =========================
// HAZARD + FORWARDING
// =========================
logic stall, flush;
logic [1:0] forwardA, forwardB;

always_comb begin
    forwardA = 2'b00;
    forwardB = 2'b00;

    if (ex_mem.reg_write && !ex_mem.mem_read &&
        ex_mem.rd != 0 && ex_mem.rd == id_ex.rs1)
        forwardA = 2'b10;
    else if (mem_wb.reg_write &&
             mem_wb.rd != 0 && mem_wb.rd == id_ex.rs1)
        forwardA = 2'b01;

    if (ex_mem.reg_write && !ex_mem.mem_read &&
        ex_mem.rd != 0 && ex_mem.rd == id_ex.rs2)
        forwardB = 2'b10;
    else if (mem_wb.reg_write &&
             mem_wb.rd != 0 && mem_wb.rd == id_ex.rs2)
        forwardB = 2'b01;
end

// =========================
// FETCH
// =========================
logic [31:0] instr_raw, instr_f;
logic        pc_valid, instr_valid;
logic        flush_d;

always_ff @(posedge clk or posedge rst) begin
    if (rst)
        flush_d <= 0;
    else
        flush_d <= flush;
end

assign pc_valid    = (pc[63:12] == 0);
assign instr_raw   = pc_valid ? imem[pc[11:2]] : 32'h00000013;

assign instr_valid = pc_valid &&
                     (instr_raw[1:0] == 2'b11) &&
                     !flush_d;

assign instr_f     = instr_valid ? instr_raw : 32'h00000013;

always_ff @(posedge clk or posedge rst) begin
    if (rst)
        if_id <= '{pc: 64'd0, instr: 32'h00000013};
    else if (flush)
        if_id <= '{pc: 64'd0, instr: 32'h00000013};
    else if (!stall) begin
        if_id.pc    <= pc;
        if_id.instr <= instr_f;
    end
end

// =========================
// DECODE
// =========================
logic [4:0]  rs1, rs2, rd;
logic [2:0]  funct3;
logic [6:0]  funct7, opcode;
logic [63:0] imm;
logic        reg_write, mem_read, mem_write;
logic        mem_to_reg, alu_src, branch, jump;
logic [3:0]  alu_op;

decode dec_i (
    .instr(if_id.instr),
    .rs1(rs1), .rs2(rs2), .rd(rd),
    .funct3(funct3), .funct7(funct7), .opcode(opcode),
    .imm(imm),
    .reg_write(reg_write), .mem_read(mem_read), .mem_write(mem_write),
    .mem_to_reg(mem_to_reg), .alu_src(alu_src),
    .branch(branch), .jump(jump), .alu_op(alu_op)
);

// =========================
// STALL (LOAD-USE)
// =========================
always_comb begin
    stall = id_ex.mem_read &&
            (id_ex.rd != 0) &&
            ((id_ex.rd == rs1) || (id_ex.rd == rs2));
end

// =========================
// ID → EX
// =========================
always_ff @(posedge clk or posedge rst) begin
    if (rst || flush || stall) begin
        id_ex <= '{
            pc: 64'd0, rs1_val: 0, rs2_val: 0, imm: 0,
            rs1: 0, rs2: 0, rd: 0,
            funct3: 0, funct7: 0, opcode: 0,
            reg_write: 0, mem_read: 0, mem_write: 0,
            mem_to_reg: 0, alu_src: 0, branch: 0, jump: 0,
            alu_op: 0
        };
    end
    else begin
        id_ex.pc        <= if_id.pc;
        id_ex.rs1_val   <= rs1_data;
        id_ex.rs2_val   <= rs2_data;
        id_ex.imm       <= imm;
        id_ex.rs1       <= rs1;
        id_ex.rs2       <= rs2;
        id_ex.rd        <= rd;
        id_ex.funct3    <= funct3;
        id_ex.funct7    <= funct7;
        id_ex.opcode    <= opcode;
        id_ex.reg_write <= reg_write;
        id_ex.mem_read  <= mem_read;
        id_ex.mem_write <= mem_write;
        id_ex.mem_to_reg<= mem_to_reg;
        id_ex.alu_src   <= alu_src;
        id_ex.branch    <= branch;
        id_ex.jump      <= jump;
        id_ex.alu_op    <= alu_op;
    end
end

// =========================
// FORWARDING MUX
// =========================
logic [63:0] fwdA, fwdB;

always_comb begin
    case (forwardA)
        2'b10:   fwdA = ex_mem.alu_out;
        2'b01:   fwdA = wb_data;
        default: fwdA = id_ex.rs1_val;
    endcase
    case (forwardB)
        2'b10:   fwdB = ex_mem.alu_out;
        2'b01:   fwdB = wb_data;
        default: fwdB = id_ex.rs2_val;
    endcase
end

// =========================
// EXECUTE
// =========================
logic [63:0] alu_out_ex, target;
logic        branch_taken;

execute exe_i (
    .a(fwdA), .b(fwdB),
    .imm(id_ex.imm), .alu_src(id_ex.alu_src), .alu_op(id_ex.alu_op),
    .branch(id_ex.branch), .jump(id_ex.jump),
    .funct3(id_ex.funct3), .opcode(id_ex.opcode), .pc(id_ex.pc),
    .alu_out(alu_out_ex), .branch_taken(branch_taken), .target(target)
);

// =========================
// EX → MEM
// =========================
always_ff @(posedge clk or posedge rst) begin
    if (rst)
        ex_mem <= '0;
    else if (flush)
        ex_mem <= '{
            alu_out: 0, rs2_val: 0, rd: 0,
            reg_write: 0, mem_read: 0, mem_write: 0, mem_to_reg: 0,
            jump: 0, branch: 0, branch_taken: 0, target: 0,
            funct3: 0, pc: 0
        };
    else begin
        ex_mem.alu_out      <= alu_out_ex;
        ex_mem.rs2_val      <= fwdB;
        ex_mem.rd           <= id_ex.rd;
        ex_mem.reg_write    <= id_ex.reg_write;
        ex_mem.mem_read     <= id_ex.mem_read;
        ex_mem.mem_write    <= id_ex.mem_write;
        ex_mem.mem_to_reg   <= id_ex.mem_to_reg;
        ex_mem.branch       <= id_ex.branch;
        ex_mem.jump         <= id_ex.jump;
        ex_mem.branch_taken <= branch_taken;
        ex_mem.target       <= target;
        ex_mem.funct3       <= id_ex.funct3;
        ex_mem.pc           <= id_ex.pc;
    end
end

// =========================
// MEMORY + IO (FPGA CLEAN FINAL)
// =========================
logic        addr_is_io;
logic [63:0] mem_data_comb, rdata, w_next;
logic [2:0]  off;
logic        addr_valid;

logic [7:0]  mem_byte;
logic [15:0] mem_hword;
logic [31:0] mem_word;

// -------- IO registers --------
logic [3:0]  digit_reg;
logic [31:0] timer;

// -------- Display wire --------
logic [6:0] seg_wire;

// -------- Address decode --------
// RAM: 0x0000 - 0x7FFF
assign addr_valid = (ex_mem.alu_out[63:13] == 0);

// IO: 0x800 - 0x8FF (simple + fast decode)
assign addr_is_io =
    (ex_mem.alu_out[11:0] >= 12'h800) &&
    (ex_mem.alu_out[11:0] <  12'h900);

// -------- Address breakdown --------
assign off   = ex_mem.alu_out[2:0];
assign rdata = addr_valid ? dmem[ex_mem.alu_out[11:3]] : 64'd0;

// -------- Sub-word extraction --------
always_comb begin
    mem_byte  = rdata[off*8 +: 8];
    mem_hword = rdata[{off[2:1], 1'b0, 3'b0} +: 16];
    mem_word  = rdata[{off[2], 5'b0} +: 32];
end

// -------- Store merge --------
always_comb begin
    w_next = rdata;

    if (ex_mem.mem_write && addr_valid && !addr_is_io) begin
        case (ex_mem.funct3)
            3'b000: w_next[off*8           +: 8]  = ex_mem.rs2_val[7:0];
            3'b001: w_next[{off[2:1],4'b0} +: 16] = ex_mem.rs2_val[15:0];
            3'b010: w_next[{off[2],5'b0}   +: 32] = ex_mem.rs2_val[31:0];
            3'b011: w_next                         = ex_mem.rs2_val;
            default: ;
        endcase
    end
end

// -------- LOAD (MEM + IO) --------
always_comb begin
    mem_data_comb = 64'd0;

    if (ex_mem.mem_read) begin

        // ===== IO READ =====
        if (addr_is_io) begin
            case (ex_mem.alu_out[3:0])
                4'h0: mem_data_comb = {60'd0, digit_reg};
                4'h8: mem_data_comb = {32'd0, timer};
                default: mem_data_comb = 64'd0;
            endcase
        end

        // ===== RAM READ =====
        else if (addr_valid) begin
            case (ex_mem.funct3)
                3'b000: mem_data_comb = {{56{mem_byte[7]}},  mem_byte};
                3'b100: mem_data_comb = {56'd0,               mem_byte};
                3'b001: mem_data_comb = {{48{mem_hword[15]}}, mem_hword};
                3'b101: mem_data_comb = {48'd0,               mem_hword};
                3'b010: mem_data_comb = {{32{mem_word[31]}},  mem_word};
                3'b110: mem_data_comb = {32'd0,               mem_word};
                3'b011: mem_data_comb = rdata;
                default: mem_data_comb = 64'd0;
            endcase
        end
    end
end

// -------- RAM WRITE --------
always_ff @(posedge clk) begin
    if (ex_mem.mem_write && addr_valid && !addr_is_io)
        dmem[ex_mem.alu_out[11:3]] <= w_next;
end

// -------- IO WRITE --------
always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
        digit_reg <= 4'd0;
    end
    else if (ex_mem.mem_write && addr_is_io) begin
        case (ex_mem.alu_out[3:0])
            // SAFE + FAST: just take lower 4 bits
            4'h0: digit_reg <= ex_mem.rs2_val[3:0];
            default: ;
        endcase
    end
end

// -------- TIMER --------
always_ff @(posedge clk or posedge rst) begin
    if (rst)
        timer <= 0;
    else
        timer <= timer + 1;
end

// -------- DISPLAY --------
seven_seg disp (
    .digit(digit_reg),
    .seg(seg_wire)
);

// -------- OUTPUT --------
assign seg = seg_wire;

// =========================
// MEM → WB
// =========================
always_ff @(posedge clk or posedge rst) begin
    if (rst)
        mem_wb <= '0;
    else begin
        mem_wb.alu_out    <= ex_mem.alu_out;
        mem_wb.mem_data   <= mem_data_comb;   // FIX: was mem_data (registered)
        mem_wb.rd         <= ex_mem.rd;
        mem_wb.reg_write  <= ex_mem.reg_write;
        mem_wb.mem_to_reg <= ex_mem.mem_to_reg;
        mem_wb.jump       <= ex_mem.jump;
        mem_wb.pc         <= ex_mem.pc;
    end
end

// =========================
// WRITEBACK
// =========================
always_comb begin
    if (mem_wb.jump)
        wb_data = mem_wb.pc + 4;
    else
        wb_data = mem_wb.mem_to_reg ? mem_wb.mem_data : mem_wb.alu_out;
end

// =========================
// PC LOGIC (FPGA SAFE)
// =========================
always_comb begin
    pc_next = pc + 4;
    flush   = 1'b0;

    // Jump has priority
    if (ex_mem.jump) begin
        flush   = 1'b1;
        pc_next = ex_mem.target;
    end
    // Then branch
    else if (ex_mem.branch && ex_mem.branch_taken) begin
        flush   = 1'b1;
        pc_next = ex_mem.target;
    end
end

endmodule