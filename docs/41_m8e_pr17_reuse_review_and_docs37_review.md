# 41. M8E PR 17 reuse review and docs/37 review (documentation only)

Status: review, no RTL, firmware or safety changes, no builds or tests run. Evidence: source read from GitHub (PR 17 head fcc567b, 4 commits, 30 behind main, merge base 577afe4) against current main. The branch flowbot/m8e-uart-tx no longer exists on GitHub; the commit is still readable by SHA.

## A. PR 17 reuse
PR 17 state: closed, NOT merged. Its own docs claim: test_uart 15 checks pass, test_soc and test_nav rerun pass, cosim and full regression not rerun, wrapper test (about 5 min) pass, CI synth/PnR Fmax 31.7 to 35.6 MHz pre-bitstream. I did not re-run any of it; those are the PR's claims.

| Item | Verdict |
|---|---|
| soc_uart.v serializer (8N1, CLKS_PER_BIT param, async reset high, busy/overrun) | REUSE core, but REMAP registers (below). Needs review vs current main file |
| soc_top.v UART_CLKS_PER_BIT parameter | REUSE; main's soc_top has changed since, reapply as a small patch, not a file copy |
| tb_soc_uart.v (divider 8, 15 checks) | REUSE with edits to the new register map and new overrun semantics |
| tb_ulx3s_top.v independent receiver decoding the real ftdi_rxd pin | REUSE, strongest test; slow, keep outside test_rtl |
| soc_firmware.s polling fix | REUSE (needed, smoke firmware writes 4 bytes back to back); firmware.hex must be regenerated |
| Legacy tb divider = 4 override | REUSE idea; cosim cycle latency (3,302 cycles) was measured with instant UART, must not be re-quoted |
| docs/30-32 (PR numbering) | DO NOT copy: numbers 30-35 are already used on main; renumber, and re-derive synth/PnR numbers (artifacts need login, may expire) |
| sim/negative/*, run_vvp.sh, Makefile changes | Unrelated to UART in the PR's scope; main differs (Makefile has changed). Do not carry over blindly |
| 52 files changed total | most are logs/docs; RTL+TB scope is about 6 files |

Needs updating vs D-A / D-B: PR 17 put ready at 0x04 (bit0 = READY, bit1 = overrun) and TX_BUSY at 0x08. Owner decision: STATUS at 0x08, bit0 = TX busy. So 0x04 READY must go.

## B. Register-map users on main (all found by git grep)
| User | What it assumes | Needed change |
|---|---|---|
| rtl/periph/soc_uart.v | 0x04 read = 1 (ready); TXDATA write only echoes | implement map below |
| sw/firmware/robot_nav_firmware.s (uart_puts, line ~418) | polls 0x08 bit0 busy | none (already correct) |
| sw/firmware/soc_firmware.s | writes 4 bytes to 0(s2) without polling | add 0x08 busy poll; regenerate firmware.hex |
| sw/include/soc_regs.h + robot_drivers.h | STATUS 0x08, bit0 TX_BUSY, bit1 RX_VALID, RXDATA 0x04, BAUD 0x0C | add UART_STATUS_TX_OVERRUN and clear semantics; mark RX_VALID reserved 0 (no RX in RTL) |
| sw/firmware/soc_regs.h + main.c | STATUS at 0x04, bit0 busy | change to 0x08 (main.c is not built into any loaded image; compile-only fix, low risk) |
| rtl/bus/soc_interconnect.v, soc_pkg.sv | address decode only | none |
| tb_safety_hw_interface.v | includes a regs header | check; not read in detail |
| Python cosim / docs | none found referencing UART status | docs only |

## C. Proposed final map (base 0x5000_0100)
- 0x00 TXDATA: W bits 7:0. If idle: accept, start frame. If busy: bus acked in the same way, byte discarded, OVERRUN set. R: last accepted byte.
- 0x04 RXDATA: R 0 (no RX).
- 0x08 STATUS: R bit0 TX_BUSY (1 from accept until stop bit completes), bit1 reserved 0 (RX_VALID, matches header), bit2 TX_OVERRUN sticky. W: writing 1 to bit2 clears it (write-1-to-clear); writes to other bits ignored. A clear and a dropped write in the same cycle: the new overrun wins (flag stays set). Reset clears it.
- 0x0C BAUD: R 0, writes ignored (baud fixed by parameter). Decision needed if owner wants a runtime divider.
Decision for owner: OVERRUN at bit2 instead of PR 17's bit1, to avoid colliding with the header's RX_VALID bit1.

## D. Tests (smallest set)
1. tb_soc_uart (divider 8): idle high in reset; busy bit timing = 10 bit periods; frame bits LSB first; write while busy acked with no stall and no extra frame; OVERRUN sets, readback of last accepted byte unchanged; W1C clears; clear of bit0/bit1 ignored; set-vs-clear same-cycle; reset mid-frame returns pin high and clears flags; back-to-back polled bytes 0x53 0x00 0xFF 0x0A.
2. tb_ulx3s_top (divider 217): independent receiver decodes banner from the real pin; the one slow test.
3. Existing regression targets unchanged (test_soc, test_nav, cosim with divider override). Cosim latency numbers flagged as not UART-inclusive.
4. Not covered: synthesis/timing, baud error on the board (217 gives +0.006 percent in theory), FTDI level, anything board-tested.

## E. Smallest scope and effort (estimates, not measured)
Files: soc_uart.v, soc_top.v (param), soc_firmware.s, firmware.hex, soc_regs.h x2, main.c, tb_soc_uart.v, optionally tb_ulx3s_top.v, one doc. Effort about 0.5 day with reuse (down from about 1 day), plus the slow wrapper run and CI synth/PnR rerun in the background. Regression of all targets: not yet run on main.

## F. Review of docs/37 (PR 21), no safety logic changed
Inconsistencies / gaps found:
1. S5 effort total: table sums 0.5+1+0.5+1.5..2.5+0.5 = 4.0 to 5.0 days; matches. OK.
2. Section 3 says watchdog defaults 2,500,000 cycles is 50 ms at 50 MHz; at 25 MHz it is 100 ms, firmware 500,000 is 20 ms. Section 3 states this, but P9/P10 text and S3-S5 do not carry t_wd as a gating parameter, and section 8 still lists the clock as only a missing spec. U5 correct but should be a blocker for P9 evidence. Also the 25 MHz vs 33 MHz estimated Fmax margin (docs/28) is not mentioned.
3. P10 requires PWM zero "within one clock" but the disarm is combinational from an unsynchronised pin (ulx3s switch). No metastability/synchroniser or debounce requirement is specified. Missing requirement.
4. P10 / sec 3: reg_enable resets to 1 and is software writable; the spec does not state whether the watchdog must be armed from reset (a firmware that never enables it leaves no watchdog trip). Missing: required reset state of watchdog and who may disable it.
5. Pin state while the FPGA is unconfigured or in reset: not specified (docs/40 risk). Needs a P-level requirement: motor driver must default-off through pull resistors, independent of FPGA.
6. P3 forbids reverse, but the finding that current filters permit reverse is not tied to a blocking item in section 9. Add as unresolved before any physical motion. Also the policy output itself can command reverse; the requirement should state clamping at the filter, not the policy.
7. P8 requires stuck-sensor detection and sensor timeout, but no sensor interface (hardware sensors are not yet wired, section 8). The Q7 range of 4 m full-scale is a sim assumption; min-range behaviour (reading 0 or max when too close) is not specified.
8. P11 first valid sample requirement has no definition of "valid" (depends on sensor model).
9. P5 and D5: braking override is not bounded; P5 then says it applies to non-safety changes only, leaving no bound on safety changes until a_brake is known. Acceptable as draft but flag in U3 that sim a_brake = 1.5 m/s^2 is unmeasured.
10. P4/P1 forward sector vs the existing 4-front-sensor min; section 10 notes f() uses a scalar. Spec does not define the forward sector angular width.
11. Missing requirement: Python/firmware version identification and a build-hash check so tested image equals deployed image.
12. Missing requirement: power loss / brown-out / FPGA reconfiguration behaviour and an independent hardware E-stop, listed as TBD only in P10.
13. Missing requirement: UART console must not be able to influence actuation or the safety path (relevant because M8E touches the bus); and a UART busy state must not delay heartbeat or safety filter.
14. Section 0 D7 notes verified clock; there is no requirement for a hardware clock-loss check (watchdog uses the same clock it monitors; clock stop disables the watchdog). Missing.
15. U7: no approval for implementation; consistent. D8 says toolchains permitted, not yet installed.
Unverified in this review: I did not re-read source for each cited line number; source claims in docs/37 are taken from the document except where noted.
