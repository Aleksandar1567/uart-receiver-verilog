// -----------------------------------------------------------------------------
// tb_uart_rx.v
// Self-checking testbench for uart_rx.
//
// A behavioural UART transmitter drives the line; a monitor reads every
// received word and compares it against a scoreboard of expected results.
//
// Test list
//   1. Reset values
//   2. Directed patterns (0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80 ...)
//   3. Random data, back-to-back and with random idle gaps
//   4. Baud-rate mismatch (+/- 2 %)
//   5. Parity error injection           (only when PARITY != 0)
//   6. Framing error injection
//   7. Break condition (line held low)
//   8. Start-bit glitch rejection
//   9. Noise detection (single corrupted sample, majority vote recovers)
//  10. Overrun detection
//
// Override parameters from the command line, e.g.
//   iverilog -P tb_uart_rx.PARITY=2 -P tb_uart_rx.STOP_BITS=2 ...
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_uart_rx;

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    parameter integer CLK_FREQ   = 50_000_000;
    parameter integer BAUD_RATE  = 115_200;
    parameter integer DATA_BITS  = 8;
    parameter integer PARITY     = 0;
    parameter integer STOP_BITS  = 1;
    parameter integer OVERSAMPLE = 16;
    parameter integer N_RANDOM   = 200;
    parameter integer SEED       = 1350;

    localparam real    CLK_PERIOD = 1.0e9 / CLK_FREQ;     // ns
    localparam real    BIT_NS     = 1.0e9 / BAUD_RATE;    // ns (nominal)
    localparam integer DIVISOR    = (CLK_FREQ + (BAUD_RATE * OVERSAMPLE) / 2)
                                    / (BAUD_RATE * OVERSAMPLE);
    localparam integer MID        = OVERSAMPLE / 2;
    localparam [DATA_BITS-1:0] DMASK = {DATA_BITS{1'b1}};

    // ------------------------------------------------------------------
    // DUT signals
    // ------------------------------------------------------------------
    reg                  clk = 1'b0;
    reg                  rst_n = 1'b0;
    reg                  rx_line = 1'b1;   // driven by the behavioural transmitter
    reg                  glitch  = 1'b0;   // XOR'ed onto the line for noise tests
    wire                 rx = rx_line ^ glitch;
    reg                  mon_rd  = 1'b0;   // read strobe from the monitor
    reg                  host_rd = 1'b0;   // read strobe from directed tests
    wire                 rx_rd = mon_rd | host_rd;

    wire [DATA_BITS-1:0] rx_data;
    wire                 rx_valid;
    wire                 frame_err, parity_err, noise_err, break_det, overrun_err;
    wire                 rx_busy;

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    uart_rx #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .DATA_BITS (DATA_BITS),
        .PARITY    (PARITY),
        .STOP_BITS (STOP_BITS),
        .OVERSAMPLE(OVERSAMPLE)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .rx         (rx),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .rx_rd      (rx_rd),
        .frame_err  (frame_err),
        .parity_err (parity_err),
        .noise_err  (noise_err),
        .break_det  (break_det),
        .overrun_err(overrun_err),
        .rx_busy    (rx_busy)
    );

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    localparam integer SB_DEPTH = 4096;

    reg [DATA_BITS-1:0] sb_data  [0:SB_DEPTH-1];
    reg                 sb_ferr  [0:SB_DEPTH-1];
    reg                 sb_perr  [0:SB_DEPTH-1];
    reg                 sb_brk   [0:SB_DEPTH-1];
    reg                 sb_noise [0:SB_DEPTH-1];
    integer             wr_ptr = 0;
    integer             rd_ptr = 0;

    integer errors   = 0;
    integer checks   = 0;
    reg     auto_read = 1'b1;

    task expect_frame(input [DATA_BITS-1:0] d, input ferr, input perr,
                      input brk, input noise);
        begin
            sb_data [wr_ptr % SB_DEPTH] = d;
            sb_ferr [wr_ptr % SB_DEPTH] = ferr;
            sb_perr [wr_ptr % SB_DEPTH] = perr;
            sb_brk  [wr_ptr % SB_DEPTH] = brk;
            sb_noise[wr_ptr % SB_DEPTH] = noise;
            wr_ptr = wr_ptr + 1;
        end
    endtask

    task check(input cond, input [8*64-1:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("[%0t] FAIL: %0s", $time, msg);
            end
        end
    endtask

    // Monitor: pops one word per rx_valid and compares with the scoreboard
    always @(posedge clk) begin
        mon_rd <= 1'b0;
        if (auto_read && rx_valid && !rx_rd) begin
            mon_rd <= 1'b1;
            checks = checks + 1;
            if (rd_ptr >= wr_ptr) begin
                errors = errors + 1;
                $display("[%0t] FAIL: unexpected word 0x%0h (ferr=%b perr=%b brk=%b noise=%b)",
                         $time, rx_data, frame_err, parity_err, break_det, noise_err);
            end else begin
                if (rx_data    !== sb_data [rd_ptr % SB_DEPTH] ||
                    frame_err  !== sb_ferr [rd_ptr % SB_DEPTH] ||
                    parity_err !== sb_perr [rd_ptr % SB_DEPTH] ||
                    break_det  !== sb_brk  [rd_ptr % SB_DEPTH] ||
                    noise_err  !== sb_noise[rd_ptr % SB_DEPTH]) begin
                    errors = errors + 1;
                    $display("[%0t] FAIL: word %0d got 0x%0h f=%b p=%b b=%b n=%b, exp 0x%0h f=%b p=%b b=%b n=%b",
                             $time, rd_ptr,
                             rx_data, frame_err, parity_err, break_det, noise_err,
                             sb_data[rd_ptr % SB_DEPTH], sb_ferr[rd_ptr % SB_DEPTH],
                             sb_perr[rd_ptr % SB_DEPTH], sb_brk[rd_ptr % SB_DEPTH],
                             sb_noise[rd_ptr % SB_DEPTH]);
                end
                rd_ptr = rd_ptr + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Behavioural transmitter
    // ------------------------------------------------------------------
    function par_of(input [DATA_BITS-1:0] d);
        par_of = (PARITY == 2) ? ^d : ~^d;
    endfunction

    // bt: bit time in ns, bad_par: invert parity bit, bad_stop: drive stop bit(s) low
    task send_frame(input [DATA_BITS-1:0] d, input bad_par, input bad_stop, input real bt);
        integer i;
        begin
            rx_line = 1'b0; #(bt);                         // start
            for (i = 0; i < DATA_BITS; i = i + 1) begin
                rx_line = d[i]; #(bt);
            end
            if (PARITY != 0) begin
                rx_line = par_of(d) ^ bad_par; #(bt);
            end
            for (i = 0; i < STOP_BITS; i = i + 1) begin
                rx_line = ~bad_stop; #(bt);
            end
            rx_line = 1'b1;
        end
    endtask

    task send_ok(input [DATA_BITS-1:0] d);
        begin
            expect_frame(d, 1'b0, 1'b0, 1'b0, 1'b0);
            send_frame(d, 1'b0, 1'b0, BIT_NS);
        end
    endtask

    task idle_bits(input integer n);
        begin
            rx_line = 1'b1;
            #(BIT_NS * n);
        end
    endtask

    task wait_drain;
        begin
            idle_bits(2);
            repeat (10) @(posedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    integer        k, seed, gap;
    reg [DATA_BITS-1:0] d;
    real           bt;

    initial begin
        seed = SEED;
        $display("==============================================================");
        $display(" UART RX testbench: %0d baud, %0d%s%0d, clk %0d Hz, divisor %0d",
                 BAUD_RATE, DATA_BITS,
                 (PARITY == 0) ? "N" : (PARITY == 1) ? "O" : "E",
                 STOP_BITS, CLK_FREQ, DIVISOR);
        $display("==============================================================");

        `ifdef DUMP
            $dumpfile("tb_uart_rx.vcd");
            $dumpvars(0, tb_uart_rx);
        `endif

        // ---- 1. Reset ------------------------------------------------
        repeat (5) @(posedge clk);
        check(rx_valid === 1'b0 && rx_busy === 1'b0 && overrun_err === 1'b0, "reset values");
        rst_n = 1'b1;
        idle_bits(2);
        $display("[T1] reset ............................ done");

        // ---- 2. Directed patterns -----------------------------------
        send_ok(8'h00 & DMASK);
        send_ok(8'hFF & DMASK);
        send_ok(8'h55 & DMASK);
        send_ok(8'hAA & DMASK);
        send_ok(8'h01 & DMASK);
        send_ok(8'h80 & DMASK);
        send_ok(8'h0F & DMASK);
        send_ok(8'hF0 & DMASK);
        wait_drain;
        $display("[T2] directed patterns ................ done");

        // ---- 3. Random data -----------------------------------------
        for (k = 0; k < N_RANDOM; k = k + 1) begin
            d   = $random(seed);
            gap = $random(seed) & 3;           // 0..3 idle bits, 0 = back-to-back
            send_ok(d);
            if (gap) idle_bits(gap);
        end
        wait_drain;
        $display("[T3] %0d random frames ............... done", N_RANDOM);

        // ---- 4. Baud mismatch ---------------------------------------
        bt = BIT_NS * 1.02;                    // transmitter 2 % slow
        for (k = 0; k < 20; k = k + 1) begin
            d = $random(seed);
            expect_frame(d, 1'b0, 1'b0, 1'b0, 1'b0);
            send_frame(d, 1'b0, 1'b0, bt);
        end
        bt = BIT_NS * 0.98;                    // transmitter 2 % fast
        for (k = 0; k < 20; k = k + 1) begin
            d = $random(seed);
            expect_frame(d, 1'b0, 1'b0, 1'b0, 1'b0);
            send_frame(d, 1'b0, 1'b0, bt);
        end
        wait_drain;
        $display("[T4] baud mismatch +/-2%% .............. done");

        // ---- 5. Parity error ----------------------------------------
        if (PARITY != 0) begin
            for (k = 0; k < 8; k = k + 1) begin
                d = $random(seed);
                expect_frame(d, 1'b0, 1'b1, 1'b0, 1'b0);
                send_frame(d, 1'b1, 1'b0, BIT_NS);
                send_ok(d ^ DMASK);            // following good frame must be clean
            end
            wait_drain;
            $display("[T5] parity error injection ........... done");
        end else begin
            $display("[T5] parity error injection ........... skipped (PARITY=0)");
        end

        // ---- 6. Framing error ---------------------------------------
        for (k = 0; k < 8; k = k + 1) begin
            d = ($random(seed) & DMASK) | 1;   // non-zero so it is not a break
            expect_frame(d, 1'b1, 1'b0, 1'b0, 1'b0);
            send_frame(d, 1'b0, 1'b1, BIT_NS);
            idle_bits(1);
            send_ok(d);
        end
        wait_drain;
        $display("[T6] framing error injection .......... done");

        // ---- 7. Break -----------------------------------------------
        // Line held low for ~3 frames must produce exactly one break word.
        // With odd parity an all-zero frame also has a wrong parity bit.
        expect_frame({DATA_BITS{1'b0}}, 1'b1, (PARITY == 1), 1'b1, 1'b0);
        rx_line = 1'b0;
        #(BIT_NS * (DATA_BITS + STOP_BITS + 2) * 3);
        idle_bits(2);
        check(dut.state == 3'd0, "receiver back in IDLE after break");
        send_ok(8'hA5 & DMASK);
        wait_drain;
        $display("[T7] break detection .................. done");

        // ---- 8. Start-bit glitch ------------------------------------
        for (k = 0; k < 8; k = k + 1) begin
            rx_line = 1'b0;
            #(BIT_NS * 3.0 / 16.0);            // 3/16 bit wide low pulse
            rx_line = 1'b1;
            idle_bits(2);
            check(dut.state == 3'd0 && !rx_valid, "glitch rejected");
        end
        send_ok(8'h3C & DMASK);
        wait_drain;
        $display("[T8] start-bit glitch rejection ....... done");

        // ---- 9. Noise on one sample ---------------------------------
        // Corrupt only the MID sample of data bit 3; majority vote must recover
        // the correct value but flag noise_err.
        d = 8'h96 & DMASK;
        expect_frame(d, 1'b0, 1'b0, 1'b0, 1'b1);
        fork
            send_frame(d, 1'b0, 1'b0, BIT_NS);
            begin
                wait (dut.state == 3'd2 && dut.bit_cnt == 3);
                @(posedge clk);
                while (!(dut.tick && dut.os_cnt == MID - 1)) @(posedge clk);
                @(negedge clk) glitch = 1'b1;
                repeat (DIVISOR) @(posedge clk);
                @(negedge clk) glitch = 1'b0;
            end
        join
        send_ok(8'h69 & DMASK);
        wait_drain;
        $display("[T9] noise detection .................. done");

        // ---- 10. Overrun --------------------------------------------
        auto_read = 1'b0;
        send_frame(8'h11 & DMASK, 1'b0, 1'b0, BIT_NS);
        idle_bits(1);
        check(rx_valid && rx_data == (8'h11 & DMASK) && !overrun_err, "first word held");
        send_frame(8'h22 & DMASK, 1'b0, 1'b0, BIT_NS);
        idle_bits(1);
        check(overrun_err === 1'b1, "overrun flagged");
        check(rx_data == (8'h11 & DMASK), "old data preserved on overrun");
        @(posedge clk) host_rd <= 1'b1;
        @(posedge clk) host_rd <= 1'b0;
        @(posedge clk);
        check(!rx_valid && !overrun_err, "rx_rd clears valid and overrun");
        auto_read = 1'b1;
        send_ok(8'h33 & DMASK);
        wait_drain;
        $display("[T10] overrun detection ............... done");

        // ---- Summary ------------------------------------------------
        check(rd_ptr == wr_ptr, "all expected words received");
        $display("--------------------------------------------------------------");
        $display(" words checked: %0d   checks: %0d   errors: %0d", rd_ptr, checks, errors);
        if (errors == 0)
            $display(" RESULT: PASS");
        else
            $display(" RESULT: FAIL");
        $display("--------------------------------------------------------------");
        $finish;
    end

    // Global watchdog
    initial begin
        #(BIT_NS * 20 * (N_RANDOM + 400));
        $display("RESULT: FAIL (timeout)");
        $finish;
    end

endmodule
