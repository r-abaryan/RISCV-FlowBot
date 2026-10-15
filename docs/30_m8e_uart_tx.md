# M8E: synthesizable UART TX (115200 8N1 at 25 MHz)

Scope: rtl/periph/soc_uart.v, a parameter on soc_top, firmware polling fix, tests. Not touched: safety filter, PWM/motor path, LPF, ulx3s_top.v, CI. No bitstream, no synthesis run (Yosys not available this session), no hardware test.

## Register semantics (base 0x5000_0100, addresses unchanged)
| Offset | Access | Meaning |
|---|---|---|
| 0x00 TXDATA | W | bits 7:0 byte to send. Accepted only if idle. If busy the byte is dropped, OVERRUN is set, the bus is acked normally (no stall). |
| 0x00 TXDATA | R | last accepted byte |
| 0x04 STATUS | R | bit0 TX_READY (1 = idle), bit1 OVERRUN (sticky) |
| 0x04 STATUS | W | write 1 to bit1 clears OVERRUN |
| 0x08 TX_BUSY | R | bit0 = 1 while a frame is in flight (= not TX_READY). Same address and meaning the existing firmware already polled. |

Frame: idle high, start 0, 8 data bits LSB first, stop 1, no parity. CLKS_PER_BIT = 217 (25 MHz / 217 = 115,207 baud, +0.006 percent). Busy clears after the stop bit has lasted one full bit period. Async reset aborts a frame and forces the pin high.

Parameter: `soc_top.UART_CLKS_PER_BIT` (default 217) passes through to soc_uart.

## Compatibility changes
- Before, TXDATA writes were accepted at any time and nothing was serialised. Now back-to-back writes lose bytes unless firmware polls 0x08 (or 0x04 bit0).
- robot_nav_firmware.s already polled 0x08 bit0 before each byte (uart_puts), so it needed no change.
- soc_firmware.s (the smoke firmware) wrote bytes back to back. It now polls 0x08 before each byte. firmware.hex was regenerated from it.
- Legacy testbenches (tb_soc_top, tb_soc_nav, tb_soc_cosim) instantiate soc_top with UART_CLKS_PER_BIT=4 so their cycle budgets stay valid. The cosim cycle-latency figures were measured with an instant-ready UART and the cosim testbench now uses divider 4, so those figures are not re-derived here. On the board the real divider adds roughly 148 bytes x 2170 cycles = about 321k cycles (about 12.85 ms) to the banner. That is arithmetic, not a measurement.
- Simulation-only stdout echo is kept under `ifndef SYNTHESIS`, and now only echoes accepted bytes.

## Tests
- `make -C sim test_uart` (tb_soc_uart.v, divider 8, 15 checks, all pass): idle high in reset, STATUS/TX_BUSY values, busy after write, write-while-busy dropped + OVERRUN set, readback unchanged, W1C clear, ready returns, only one frame emitted, polled back-to-back bytes 0x53,0x00,0xFF,0x0A in order, start/stop/duration of every frame, reset mid-frame, clean state after reset. Added to test_rtl.
- `make -C sim test_ulx3s_top` (tb_ulx3s_top.v, divider 217, about 5 min wall in this sandbox, not in test_rtl): an independent receiver on `ftdi_rxd` decodes the real pin. Checks: LED disarm in reset, pin idle in reset, no UART activity in reset, 148 bytes received, bytes and order equal msg_boot exactly, start/stop framing on every frame, firmware never wrote while busy, OVERRUN stays 0, LED activity, pin high on reset mid-transmission, UART idle in reset, banner restarts after reset. Result: all pass, fails=0. The old KNOWN GAP pass check is gone.
- Re-ran after the change: test_soc and test_nav pass (the 2 co-sim and full regression targets were not rerun).

## Not verified
- Synthesis and timing of the new UART (not run). Electrical output on the board, FTDI level and baud accuracy in practice. Button and switch polarity (unchanged from M8D).
- The testbench reads internal signals of u_soc.u_uart by hierarchical name, so it is simulation only.
- The wrapper testbench checks only the first banner; later firmware text is not compared.
