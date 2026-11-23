# 1. The UART protocol, from the receiver's side

A UART link has **no clock wire**. Transmitter and receiver agree on a bit rate
(the *baud rate*) and a frame format up front, and the receiver works out the
timing from the data line alone.

## Frame format

```
 idle  start   D0   D1   D2   D3   D4   D5   D6   D7  [P]  stop  idle
 ‾‾‾‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾\____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
        |<-------------------- one frame -------------------->|
```

| Field | Level | Bits | Notes |
|---|---|---|---|
| idle | 1 | any | line rests high ("mark") |
| start | 0 | 1 | the falling edge is the only timing reference the receiver gets |
| data | D0 first | 5..9 | **LSB first** |
| parity | optional | 0 / 1 | even: total number of 1s (data + P) is even; odd: it is odd |
| stop | 1 | 1 or 2 | guarantees an idle → start edge before the next frame |

The short name is `<data bits><parity><stop bits>`: **8N1** is 8 data bits, no
parity, 1 stop bit (the most common), **8E1** adds even parity, **7O2** is 7
data bits, odd parity, 2 stop bits. This receiver supports all of them through
parameters.

At 115200 baud one bit lasts 1 / 115200 s ≈ **8.68 µs**, which is 434 cycles of
a 50 MHz clock.

## Why oversample?

The receiver has to sample each bit **in the middle**, where it is most stable.
It only knows where a bit starts from the falling edge of the start bit, so it:

1. watches the line at `OVERSAMPLE` × baud (16× by default, 1.84 MHz here),
2. on the falling edge starts counting ticks,
3. samples at tick 7, 8 and 9 of every bit (the centre is tick 8) and takes the
   **majority vote**, so a single corrupted sample does not corrupt the bit,
4. checks the start bit is still low at its centre; if not, the edge was a
   glitch and the receiver goes back to idle.

With 16× oversampling the start edge is located to within 1/16 of a bit.

## How much baud error is tolerated?

Transmitter and receiver clocks are never exactly equal. The error accumulates
over the frame, and the last sample (centre of the last stop bit) is the one
that drifts the most. That sample sits *n* bits after the start edge:

| Format | *n* (bits from start edge to last sample) |
|---|---|
| 8N1 | 9.5 |
| 8E1 | 10.5 |
| 8E2 | 11.5 |

The sample must stay inside its bit, i.e. within ±0.5 bit of the true centre.
Subtract the start-edge uncertainty (≈ 1/16 bit) and the majority window
(±1/16 bit) and roughly 0.375 bit of drift is left:

```
max mismatch ≈ 0.375 / n   →   8N1: ±3.9 %   8E1: ±3.6 %   8E2: ±3.3 %
```

This is the *total* error between both ends. The receiver's own error from
rounding the clock divider is part of it: with a 50 MHz clock and 115200 baud the
divider is `round(50e6 / (115200·16)) = 27`, giving 115 741 baud, **+0.47 %**.
The testbench checks frames from a transmitter that is 2 % fast and 2 % slow.

This receiver finishes the frame at the **centre** of the last stop bit, not at
its end. That leaves half a bit of slack so a slightly faster transmitter can
start the next frame without the receiver missing its start edge.

## Line conditions the receiver must report

| Condition | What happened on the wire | Flag |
|---|---|---|
| Framing error | stop bit sampled as 0 | `frame_err` |
| Parity error | parity bit does not match the data | `parity_err` |
| Noise | the three samples of some bit disagreed (bit value still decided by majority) | `noise_err` |
| Break | the whole frame, stop bit included, is 0: transmitter holds the line low | `break_det` (+ `frame_err`) |
| Overrun | a new frame finished before the host read the previous one | `overrun_err` |

Next: [Architecture](02-architecture.md).
