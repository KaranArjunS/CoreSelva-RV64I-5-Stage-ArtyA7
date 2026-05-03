module rv64_tb;

// =============================================================
// Clock & Reset
// =============================================================
logic clk, rst;
rv64_core dut (.clk(clk), .rst(rst));
always #5 clk = ~clk;

// =============================================================
// Expected values for final register check
// =============================================================
logic [63:0] expected [32];

initial begin
    // defaults
    foreach (expected[i]) expected[i] = 64'hDEAD_BEEF_DEAD_BEEF;

    // Block 1 - forwarding
    expected[1]  = 64'h63;               // addi x1,x0,99 (branch block overwrites)
    expected[2]  = 64'h4d;               // addi x2,x0,77
    expected[3]  = 64'h00;               // addi x3,x0,0 (after jalr return)
    expected[4]  = 64'h2a;               // addi x4,x0,42 (subroutine)
    expected[5]  = 64'h09;               // add chain
    // Block 2 - loads
    expected[6]  = 64'h09;               // ld x6,0(x0)
    expected[7]  = 64'h06;               // ld x7,8(x0)
    expected[8]  = 64'h0f;               // add x8,x6,x7
    // Block 3 - sign extension
    expected[9]  = 64'hff;
    expected[10] = 64'hffffffff;         // lw  sign-extends 0xFF
    expected[11] = 64'hff;               // lwu zero-extends
    expected[12] = 64'hffffffffffffffff; // lb  sign-extends 0xFF byte
    expected[13] = 64'hff;               // lbu zero-extends
    // Block 4 - SLT
    expected[14] = 64'h0a;
    expected[15] = 64'h14;
    expected[16] = 64'h01;               // slt  10<20
    expected[17] = 64'h00;               // slt  20<10 false
    expected[18] = 64'h01;               // sltu
    // Block 5 - shifts
    expected[19] = 64'h01;
    expected[20] = 64'h80;               // slli 1<<7
    expected[21] = 64'h10;               // srli 128>>3
    expected[22] = 64'h10;               // srai positive
    expected[23] = 64'hffffffffffffffff; // addi -1
    expected[24] = 64'hffffffffffffffff; // srai -1 >>4
    // Block 6 - LUI/AUIPC
    expected[25] = 64'h1000;
    expected[26] = 64'h74;               // auipc at PC=0x74
    expected[27] = 64'h1074;
    // Block 7 - branches
    expected[28] = 64'h05;
    expected[29] = 64'h05;
end

// =============================================================
// Cycle counter & last-write tracker
// =============================================================
int cycle;
logic [63:0] reg_prev [32];

// =============================================================
// Simulation
// =============================================================
initial begin
    clk = 0; rst = 1; cycle = 0;

    $readmemh("program.mem", dut.imem);
    foreach (dut.dmem[i]) dut.dmem[i] = 64'd0;
    dut.dmem[0] = 64'h5; // preload

    #20; rst = 0;
    #2000;

    $display("\n");
    $display("================================================================");
    $display("  SIMULATION COMPLETE - FINAL REGISTER FILE");
    $display("================================================================");
    $display("  %-6s  %-20s  %-20s  %s", "REG", "VALUE", "EXPECTED", "STATUS");
    $display("  %-6s  %-20s  %-20s  %s", "---", "-----", "--------", "------");

    for (int i = 1; i < 30; i++) begin
        if (expected[i] !== 64'hDEAD_BEEF_DEAD_BEEF) begin
            string status;
            status = (dut.rf.regs[i] === expected[i]) ? "PASS" : "FAIL <<<";
            $display("  x%-5d  0x%-18h  0x%-18h  %s",
                i, dut.rf.regs[i], expected[i], status);
        end
    end

    $display("================================================================");
    $display("  DATA MEMORY DUMP (first 8 doublewords)");
    $display("================================================================");
    $display("  %-10s  %s", "ADDR", "VALUE");
    for (int i = 0; i < 8; i++)
        $display("  dmem[%0d]    0x%h", i, dut.dmem[i]);
    $display("================================================================\n");

    $finish;
end

// =============================================================
// Per-cycle writeback log - only prints when a register changes
// =============================================================
always_ff @(posedge clk) begin
    if (!rst) begin
        cycle <= cycle + 1;

        // Detect register writes
        if (dut.mem_wb.reg_write && dut.mem_wb.rd != 0) begin
            automatic int rd   = dut.mem_wb.rd;
            automatic logic [63:0] val = dut.wb_data;
            if (val !== reg_prev[rd]) begin
                if (dut.mem_wb.mem_to_reg)
                    $display("[cyc %3d] LOAD  x%-2d <- 0x%h  (from mem)",
                        cycle, rd, val);
                else if (dut.mem_wb.jump)
                    $display("[cyc %3d] JAL   x%-2d <- 0x%h  (ret addr)",
                        cycle, rd, val);
                else
                    $display("[cyc %3d] WB    x%-2d <- 0x%h",
                        cycle, rd, val);
                reg_prev[rd] <= val;
            end
        end

        // Detect control transfers
        if (dut.flush)
            $display("[cyc %3d] JUMP/BR  -> PC 0x%h",
                cycle, dut.pc_next);

        // Detect stalls
        if (dut.stall)
            $display("[cyc %3d] STALL    (load-use hazard)",
                cycle);

        // Detect stores
        if (dut.ex_mem.mem_write &&
            (^dut.ex_mem.alu_out !== 1'bx) &&
            dut.ex_mem.alu_out[63:13] == 0)
            $display("[cyc %3d] STORE    dmem[0x%h] <- 0x%h",
                cycle, dut.ex_mem.alu_out,
                dut.ex_mem.rs2_val);
    end
end

// Init reg_prev
initial foreach (reg_prev[i]) reg_prev[i] = 64'hx;

endmodule
