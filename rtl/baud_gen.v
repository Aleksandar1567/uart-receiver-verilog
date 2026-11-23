// -----------------------------------------------------------------------------
// baud_gen.v
// Generates a single-cycle enable pulse ("tick") at OVERSAMPLE x BAUD_RATE.
// The divisor is rounded to the nearest integer to minimise baud error.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module baud_gen #(
    parameter integer CLK_FREQ   = 50_000_000,
    parameter integer BAUD_RATE  = 115_200,
    parameter integer OVERSAMPLE = 16
) (
    input  wire clk,
    input  wire rst_n,
    output reg  tick
);

    localparam integer DIVISOR = (CLK_FREQ + (BAUD_RATE * OVERSAMPLE) / 2)
                                 / (BAUD_RATE * OVERSAMPLE);
    localparam integer CNT_W   = (DIVISOR > 1) ? $clog2(DIVISOR) : 1;
    localparam integer     CNT_LAST_I = DIVISOR - 1;
    localparam [CNT_W-1:0] CNT_LAST   = CNT_LAST_I[CNT_W-1:0];

    initial begin
        if (DIVISOR < 1) begin
            $display("ERROR: baud_gen DIVISOR < 1 (CLK_FREQ too low for BAUD_RATE*OVERSAMPLE)");
            $finish;
        end
    end

    reg [CNT_W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b0;
        end else if (cnt == CNT_LAST) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b1;
        end else begin
            cnt  <= cnt + 1'b1;
            tick <= 1'b0;
        end
    end

endmodule
