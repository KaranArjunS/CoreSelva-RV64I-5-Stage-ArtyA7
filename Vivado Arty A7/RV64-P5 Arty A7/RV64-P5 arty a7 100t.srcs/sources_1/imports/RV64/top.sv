module top (
    input  logic clk,        // 100 MHz FPGA clock
    input  logic rst_btn,    // reset button
    output logic [6:0] seg
);

// =========================
// RESET SYNC (clean)
// =========================
logic rst_sync;

always_ff @(posedge clk) begin
    rst_sync <= rst_btn;
end

// =========================
// CLOCK DIVIDER (VISIBLE SPEED)
// =========================
// ~1 Hz (adjust as needed)
logic [31:0] div_cnt;
logic slow_clk;

always_ff @(posedge clk or posedge rst_sync) begin
    if (rst_sync) begin
        div_cnt  <= 0;
        slow_clk <= 0;
    end else begin
        if (div_cnt == 50_000_000) begin   // 100MHz / 50M = 2Hz toggle
            div_cnt  <= 0;
            slow_clk <= ~slow_clk;
        end else begin
            div_cnt <= div_cnt + 1;
        end
    end
end

// =========================
// CPU INSTANCE
// =========================
rv64_core cpu (
    .clk(slow_clk),   // IMPORTANT: slow clock for visibilty
    .rst(rst_sync),
    .seg(seg)
);

endmodule