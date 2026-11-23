// -----------------------------------------------------------------------------
// tb_wave.v
// Short directed run that dumps a VCD used to draw the waveforms in docs/img.
// 8E1 @ 115200 baud, 50 MHz clock:
//   1. good frame 0x4B
//   2. start-bit glitch (rejected)
//   3. frame 0xC3 with a wrong parity bit
//   4. break (line held low), then line back to idle
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_wave;

    localparam integer CLK_FREQ  = 50_000_000;
    localparam integer BAUD_RATE = 115_200;
    localparam real    CLK_PERIOD = 1.0e9 / CLK_FREQ;
    localparam real    BIT_NS     = 1.0e9 / BAUD_RATE;

    reg  clk = 1'b0, rst_n = 1'b0, rx = 1'b1, rx_rd = 1'b0;
    wire [7:0] rx_data;
    wire rx_valid, frame_err, parity_err, noise_err, break_det, overrun_err, rx_busy;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    uart_rx #(.CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE), .PARITY(2)) dut (
        .clk(clk), .rst_n(rst_n), .rx(rx),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_rd(rx_rd),
        .frame_err(frame_err), .parity_err(parity_err), .noise_err(noise_err),
        .break_det(break_det), .overrun_err(overrun_err), .rx_busy(rx_busy)
    );

    // Host reads each word half a bit after it arrives
    always @(posedge rx_valid) begin
        #(BIT_NS / 2);
        @(posedge clk) rx_rd <= 1'b1;
        @(posedge clk) rx_rd <= 1'b0;
    end

    task send(input [7:0] d, input bad_par);
        integer i;
        begin
            rx = 1'b0; #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin rx = d[i]; #(BIT_NS); end
            rx = (^d) ^ bad_par; #(BIT_NS);
            rx = 1'b1; #(BIT_NS);
        end
    endtask

    initial begin
        $dumpfile("build/tb_wave.vcd");
        $dumpvars(0, tb_wave);
        #(100) rst_n = 1'b1;
        #(BIT_NS * 2);

        send(8'h4B, 1'b0);
        #(BIT_NS * 3);

        rx = 1'b0; #(BIT_NS * 3.0 / 16.0); rx = 1'b1;
        #(BIT_NS * 3);

        send(8'hC3, 1'b1);
        #(BIT_NS * 3);

        rx = 1'b0; #(BIT_NS * 14); rx = 1'b1;
        #(BIT_NS * 4);
        $finish;
    end

endmodule
