module regfile (
    input  logic        clk,
    input  logic        we,
    input  logic [4:0]  rs1, rs2, rd,
    input  logic [63:0] wd,
    output logic [63:0] rd1, rd2
);

    logic [63:0] regs [31:0];

    initial begin
        integer i;
        for (i = 0; i < 32; i = i + 1)
            regs[i] = 64'd0;
    end

    // Write - x0 permanently excluded, dead regs[0] write removed
    always_ff @(posedge clk) begin
        if (we && (rd != 5'd0))
            regs[rd] <= wd;
    end

    logic [63:0] rdata1, rdata2;
    assign rdata1 = regs[rs1];
    assign rdata2 = regs[rs2];

    // Read with WB bypass and x0 hard-wire
    always_comb begin
        if (rs1 == 5'd0)
            rd1 = 64'd0;
        else if (we && (rd == rs1) && (rd != 5'd0))
            rd1 = wd;
        else
            rd1 = rdata1;

        if (rs2 == 5'd0)
            rd2 = 64'd0;
        else if (we && (rd == rs2) && (rd != 5'd0))
            rd2 = wd;
        else
            rd2 = rdata2;
    end

endmodule