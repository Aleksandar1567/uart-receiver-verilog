// -----------------------------------------------------------------------------
// uart_rx.v
// Parameterisable UART receiver (8N1 / 8E1 / 8O1 / 7E2 ...).
//
//  * 2-FF synchroniser on the asynchronous RX input
//  * OVERSAMPLE x baud sampling with 3-sample majority vote at bit centre
//  * False-start (glitch) rejection on the start bit
//  * Error detection: framing, parity, noise, overrun, break
//  * Simple valid/read handshake to the user logic
//
// Frame format (LSB first):
//   idle(1) | start(0) | D0 .. D[DATA_BITS-1] | [parity] | stop(1) x STOP_BITS
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module uart_rx #(
    parameter integer CLK_FREQ   = 50_000_000, // system clock [Hz]
    parameter integer BAUD_RATE  = 115_200,    // line rate [bit/s]
    parameter integer DATA_BITS  = 8,          // 5 .. 9
    parameter integer PARITY     = 0,          // 0 = none, 1 = odd, 2 = even
    parameter integer STOP_BITS  = 1,          // 1 or 2
    parameter integer OVERSAMPLE = 16          // samples per bit (>= 4)
) (
    input  wire                 clk,
    input  wire                 rst_n,        // async active-low reset
    input  wire                 rx,           // serial input (async)

    output reg  [DATA_BITS-1:0] rx_data,      // received word
    output reg                  rx_valid,     // rx_data holds unread data
    input  wire                 rx_rd,        // read strobe: clears rx_valid / overrun_err

    output reg                  frame_err,    // stop bit sampled low     (qualified by rx_valid)
    output reg                  parity_err,   // parity mismatch          (qualified by rx_valid)
    output reg                  noise_err,    // 3 samples of a bit disagreed (qualified by rx_valid)
    output reg                  break_det,    // all-zero frame incl. stop (qualified by rx_valid)
    output reg                  overrun_err,  // frame lost: rx_valid was still set (sticky until rx_rd)
    output wire                 rx_busy       // receiver is inside a frame
);

    // ------------------------------------------------------------------
    // Parameter checks
    // ------------------------------------------------------------------
    initial begin
        if (DATA_BITS < 5 || DATA_BITS > 9)  begin $display("ERROR: uart_rx DATA_BITS must be 5..9");  $finish; end
        if (PARITY < 0 || PARITY > 2)        begin $display("ERROR: uart_rx PARITY must be 0..2");     $finish; end
        if (STOP_BITS < 1 || STOP_BITS > 2)  begin $display("ERROR: uart_rx STOP_BITS must be 1..2");  $finish; end
        if (OVERSAMPLE < 4)                  begin $display("ERROR: uart_rx OVERSAMPLE must be >= 4"); $finish; end
    end

    localparam integer MID    = OVERSAMPLE / 2;           // bit centre
    localparam integer OS_W   = $clog2(OVERSAMPLE);
    localparam integer BIT_W  = $clog2(DATA_BITS + 1);
    localparam         HAS_PAR = (PARITY != 0);

    localparam integer OS_LAST_I  = OVERSAMPLE - 1;
    localparam integer SMP_A_I    = MID - 1;
    localparam integer SMP_B_I    = MID;
    localparam integer SMP_C_I    = MID + 1;
    localparam integer BIT_LAST_I = DATA_BITS - 1;

    localparam [OS_W-1:0]  OS_LAST   = OS_LAST_I[OS_W-1:0];
    localparam [OS_W-1:0]  SMP_A     = SMP_A_I[OS_W-1:0];    // three centre samples
    localparam [OS_W-1:0]  SMP_B     = SMP_B_I[OS_W-1:0];
    localparam [OS_W-1:0]  SMP_C     = SMP_C_I[OS_W-1:0];    // decision point
    localparam [BIT_W-1:0] BIT_LAST  = BIT_LAST_I[BIT_W-1:0];
    localparam             STOP_LAST = (STOP_BITS == 2);

    localparam [2:0] S_IDLE      = 3'd0,
                     S_START     = 3'd1,
                     S_DATA      = 3'd2,
                     S_PARITY    = 3'd3,
                     S_STOP      = 3'd4,
                     S_WAIT_IDLE = 3'd5;

    // ------------------------------------------------------------------
    // Oversampling tick
    // ------------------------------------------------------------------
    wire tick;

    baud_gen #(
        .CLK_FREQ  (CLK_FREQ),
        .BAUD_RATE (BAUD_RATE),
        .OVERSAMPLE(OVERSAMPLE)
    ) u_baud_gen (
        .clk  (clk),
        .rst_n(rst_n),
        .tick (tick)
    );

    // ------------------------------------------------------------------
    // 2-FF synchroniser (reset to idle level '1')
    // ------------------------------------------------------------------
    reg rx_meta, rx_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    // ------------------------------------------------------------------
    // Receiver datapath / FSM
    // ------------------------------------------------------------------
    reg [2:0]           state;
    reg [OS_W-1:0]      os_cnt;
    reg [BIT_W-1:0]     bit_cnt;
    reg                 stop_cnt;
    reg [DATA_BITS-1:0] shift_reg;
    reg                 par_bit;
    reg                 s0, s1;        // first two of the three centre samples
    reg                 noise_acc;
    reg                 ferr_acc;

    // Majority vote of samples MID-1, MID, MID+1 (3rd sample is the current input)
    wire vote       = (s0 & s1) | (s0 & rx_sync) | (s1 & rx_sync);
    wire noisy      = ~((s0 == s1) && (s1 == rx_sync));
    wire sample_pt  = tick && (os_cnt == SMP_C);

    // Expected parity bit for the received data
    wire exp_par    = (PARITY == 2) ? (^shift_reg) : ~(^shift_reg);

    // Frame-completion qualifiers (valid while sampling the last stop bit)
    wire last_stop  = (state == S_STOP) && sample_pt && (stop_cnt == STOP_LAST);
    wire ferr_final = ferr_acc | ~vote;
    wire perr_final = HAS_PAR && (par_bit != exp_par);
    wire brk_final  = ferr_final && (shift_reg == {DATA_BITS{1'b0}}) && (!HAS_PAR || !par_bit);

    assign rx_busy = (state != S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            os_cnt      <= {OS_W{1'b0}};
            bit_cnt     <= {BIT_W{1'b0}};
            stop_cnt    <= 1'b0;
            shift_reg   <= {DATA_BITS{1'b0}};
            par_bit     <= 1'b0;
            s0          <= 1'b1;
            s1          <= 1'b1;
            noise_acc   <= 1'b0;
            ferr_acc    <= 1'b0;
            rx_data     <= {DATA_BITS{1'b0}};
            rx_valid    <= 1'b0;
            frame_err   <= 1'b0;
            parity_err  <= 1'b0;
            noise_err   <= 1'b0;
            break_det   <= 1'b0;
            overrun_err <= 1'b0;
        end else begin
            // Host read: release the holding register (may be overridden below
            // by a frame completing in the same cycle).
            if (rx_rd) begin
                rx_valid    <= 1'b0;
                overrun_err <= 1'b0;
            end

            // Oversample counter and centre-sample capture (inside a frame only)
            if (state != S_IDLE && state != S_WAIT_IDLE && tick) begin
                os_cnt <= (os_cnt == OS_LAST) ? {OS_W{1'b0}} : os_cnt + 1'b1;
                if (os_cnt == SMP_A) s0 <= rx_sync;
                if (os_cnt == SMP_B) s1 <= rx_sync;
            end

            case (state)
                S_IDLE: begin
                    os_cnt <= {OS_W{1'b0}};
                    if (!rx_sync)
                        state <= S_START;           // falling edge -> candidate start bit
                end

                S_START: if (sample_pt) begin
                    if (vote) begin
                        state <= S_IDLE;            // glitch, not a real start bit
                    end else begin
                        state     <= S_DATA;
                        bit_cnt   <= {BIT_W{1'b0}};
                        noise_acc <= noisy;
                        ferr_acc  <= 1'b0;
                    end
                end

                S_DATA: if (sample_pt) begin
                    shift_reg <= {vote, shift_reg[DATA_BITS-1:1]};   // LSB first
                    noise_acc <= noise_acc | noisy;
                    if (bit_cnt == BIT_LAST) begin
                        state    <= HAS_PAR ? S_PARITY : S_STOP;
                        stop_cnt <= 1'b0;
                    end else begin
                        bit_cnt <= bit_cnt + 1'b1;
                    end
                end

                S_PARITY: if (sample_pt) begin
                    par_bit   <= vote;
                    noise_acc <= noise_acc | noisy;
                    state     <= S_STOP;
                end

                S_STOP: if (sample_pt) begin
                    if (last_stop) begin
                        // Leave at the centre of the last stop bit so the next
                        // start edge can be caught even with baud mismatch.
                        if (rx_valid && !rx_rd) begin
                            overrun_err <= 1'b1;    // holding register full: drop frame
                        end else begin
                            rx_data    <= shift_reg;
                            rx_valid   <= 1'b1;
                            frame_err  <= ferr_final;
                            parity_err <= perr_final;
                            noise_err  <= noise_acc | noisy;
                            break_det  <= brk_final;
                        end
                        state <= ferr_final ? S_WAIT_IDLE : S_IDLE;
                    end else begin
                        ferr_acc  <= ferr_acc | ~vote;
                        noise_acc <= noise_acc | noisy;
                        stop_cnt  <= 1'b1;
                    end
                end

                S_WAIT_IDLE: begin
                    // After a framing error / break, wait for the line to return high
                    os_cnt <= {OS_W{1'b0}};
                    if (rx_sync)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
