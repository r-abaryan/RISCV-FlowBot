# 48. M11b milestone 1: watchdog heartbeat budget, B1 timing comments, div217 regression

Status: **implemented and simulated only.** Not synthesized/routed with this firmware, not board-tested, not robot-tested.
Branch: `flowbot/m11b-wdt-budget-and-motor-contract` (shared with milestone 2; one PR after both milestones are reviewed).
Base: main 5d292e4.

## 1. Defect being fixed (found in M11b investigation, 2026-10-20)
At the board UART divider (217 = 25 MHz / 115200) the navigation firmware hit a real watchdog trip after its PASS token.
`uart_puts` busy-waits on TX for every byte and did not refresh the watchdog. The 162-byte pass banner takes about
351,540 cycles at divider 217 (my estimate: 162 x 10 bits x 217). Together with the work done before the idle loop,
the 500,000-cycle timeout expired.
- Old firmware, divider 217, run 1M cycles past PASS: last refresh at cycle 934,115, **watchdog expiry at cycle 1,434,117**.
- The default `test_nav` misses this: it runs at divider 16 and stops at the PASS token.

## 2. Changes
| File | Change | Functional? |
|---|---|---|
| `sw/firmware/robot_nav_firmware.s` | `uart_puts` and `uart_put_nibble` write the heartbeat key once per byte, only **after** the TX-busy wait completes | yes (firmware) |
| `sw/firmware/robot_nav_firmware.s` | timeout now comes from named constants `CLK_HZ=25000000`, `WDT_TIMEOUT_MS=20` giving `WDT_TIMEOUT_CYCLES=500000`. **The value is unchanged**; the old comment ("10 ms @ 50 MHz") was wrong for the ULX3S wrapper | no (value identical) |
| `sw/firmware/robot_nav.hex` | rebuilt from the source above (538 to 543 words) | yes |
| `rtl/safety/safety_filter.v` | **comment only**: reset default 2,500,000 cycles = 100 ms at the nominal 25 MHz clock (was "50ms at 50MHz") | no |
| `sim/wdt_kick_monitor.v` | new passive monitor. `$fatal` on any trip, on fewer than 2 refreshes, or on a max refresh gap > 250,000 cycles (50 % of the timeout) | test only |
| `sim/tb_soc_nav.v` | optional macros `NAV_MAX_CYCLES`, `NAV_TIME_LIMIT_NS`, `NAV_POST_PASS_CYCLES`; the defaults keep the old behaviour | test only |
| `sim/Makefile` | new target `test_nav_div217` (not in `test_rtl`, because it is slow) | test only |
| `sim/run_wdt_negative.sh` | overrides `.equ WDT_TIMEOUT_CYCLES` instead of the old literal `li t1, 500000` line | test only |

Why the kick comes after TX-ready: if the UART stalls (TX busy never clears), the firmware stops refreshing and the
watchdog still trips. A kick placed before the wait would hide a stuck UART. Worst-case kick gap inside the print loop
is about one byte time plus loop overhead.

Not changed: the RTL watchdog logic, the reset default value (2.5M cycles), the 500,000-cycle firmware timeout, the
E-stop/disarm path, the policy and the safety-filter thresholds.

## 3. Evidence (Icarus Verilog, local sandbox, 2026-10-21)
| Test | Result |
|---|---|
| `make -C sim test_nav_div217` (new firmware; divider 217; 1M cycles past PASS) | **PASS**: 16,586 refreshes, max gap 3,462 cycles (budget 250,000), min countdown 496,539/500,000 (99.3 % margin), no trip, PASS token at cycle 1,105,354, all 8 nav assertions pass |
| Same testbench + monitor with the **old** hex (1f5de894...) | **FAIL as expected**: watchdog expiry at cycle 1,434,117, exit 1. The regression detects the defect |
| `make -C sim test_nav` (divider 16) | PASS, all 8 assertions; PWM values unchanged |
| `make -C sim test_rtl` | PASS (exit 0) |
| `make -C sim test_wdt_negative` (2,000-cycle timeout must trip) | PASS (trip detected) |
| `make -C sim test_rom_layout` | PASS (expected-PWM reference matches) |
| `make -C sim test_ulx3s_top` | PASS: 89 bytes received, 0 frame errors, 0 mismatches |
| `scripts/extract_expected_banner.py` | 148 bytes; banner sha256 7d45b9f1...34a3 (banner text unchanged) |

Before the fix (main), at divider 217 up to the PASS token: max gap 418,563 cycles (16.2 % margin).

## 4. Consequences and open items
- **Firmware hash changed:** robot_nav.hex sha256 `3922377e4cd33f132a2ad68138ee165ac05c8f6773a6b85a456ea0a33c2dbe76`
  (was `1f5de894...1464`). The M11a bitstream in docs/47 (73c761bf...57ae) was built from the **old** firmware.
  It does not contain this fix. A new bitstream run is needed (CI) before any board test of this firmware. Not done here.
- **B1 stays OPEN.** The 25 MHz clock is nominal (from the wrapper, no PLL). It has not been measured on a board. The
  firmware timeout is 20 ms only if the clock really is 25 MHz. The RTL reset default is 100 ms at 25 MHz; whether
  that is acceptable is a safety-spec decision (docs/46), not made here.
- The 250,000-cycle gap budget is a test acceptance criterion, not a safety threshold.
- Other blocking prints remain only where each byte waits on TX-ready, and each of those now kicks. Code paths
  outside `uart_puts`/`uart_put_nibble` that busy-wait for a long time would still need review if added later.
- Milestone 2 (PWM scale + sign-magnitude motor contract) is still to do on the same branch.
