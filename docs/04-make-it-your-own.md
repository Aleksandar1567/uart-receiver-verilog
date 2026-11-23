# 4. Make it your own

Copying the RTL teaches little. Changing it does. Each exercise below says
what to change, what can go wrong and how the testbench helps. Start with
`make test` passing, change one thing, and get back to passing.

## Easy

1. **Change the sample point.** Sample at ticks 6, 7, 8 instead of 7, 8, 9 and
   rerun test 4 with the transmitter 3 % and then 4 % off (`bt = BIT_NS * 1.03`).
   Where does it start failing, and does that match the tolerance formula in
   [01-uart-protocol.md](01-uart-protocol.md)?
2. **Remove the synchroniser** (use `rx` directly). Simulation still passes.
   Why can simulation never show this bug, and what would happen on an FPGA?
3. **Remove `WAIT_IDLE`** (go straight to `IDLE` after a framing error). Which
   test fails, and what does the host see during a break?
4. **Add `rx_busy` checks** to the testbench: it must be 1 from the start
   edge until the centre of the last stop bit.

## Medium

5. **Receive FIFO.** Put a 16-entry FIFO between the receiver and the host
   (store data + flags, 12 bits wide). Overrun now means "FIFO full". Extend
   test 10 to fill the FIFO exactly, then one more.
6. **UART transmitter.** Write `uart_tx.v` with the same parameters and connect
   it in loopback in a new testbench: `tx → rx`. Now the testbench model and
   your RTL check each other.
7. **Runtime configuration.** Replace the `BAUD_RATE` parameter with a 16-bit
   divisor register so software can change the baud rate. What happens to a
   frame that is being received while the divisor changes?
8. **Bus interface.** Wrap the receiver in an APB or Wishbone slave with
   `DATA` (read pops the word) and `STATUS` (flags) registers, like a 16550.

## Hard

9. **Auto-baud.** Measure the length of the start bit of a known character
   (0x55 or 0x0D) in clock cycles and compute the divisor from it.
10. **Formal verification.** With SymbiYosys, prove: `rx_valid` only rises at
    a `sample_pt` in `STOP`; the FSM never reaches an undefined state;
    `overrun_err` implies `rx_valid`.
11. **Real hardware.** Synthesise for your board, connect a USB-UART adapter,
    and show received bytes on LEDs or a 7-segment display. Type in a terminal
    with a wrong baud rate setting and watch `frame_err` / `noise_err`.

## Interview questions this project prepares you for

- Why 16× oversampling and not 1×? What is the trade-off with 8×?
- How many flip-flops do you need to synchronise an asynchronous input, and why
  is it still not a 100 % guarantee?
- What baud-rate mismatch can the receiver tolerate? Derive it.
- What is the difference between a framing error and a break?
- Why do the error flags travel with the data instead of being separate pulses?
- How do you know your testbench would catch a bug?
