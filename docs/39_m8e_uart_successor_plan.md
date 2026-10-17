# M8E UART successor: plan against current main

> **HISTORICAL PLAN, SUPERSEDED BY PR #24 (2026-10-17).** This document is kept as the planning record only. The work it proposed was implemented in PR #24 (branch flowbot/m8e-uart-tx-db, RTL commit a42f89a; evidence in docs/42 on that branch, which is not part of this PR). Where this text differs from PR #24, PR #24 wins:
> - Testbench: planned `sim/tb_soc_uart_tx.v`; implemented as `tb_soc_uart.v`.
> - Register map (D-A): STATUS at 0x08, bit 0 TX_BUSY, bit 2 sticky overrun (write-1-to-clear); implemented.
> - Write while busy (D-B): byte dropped and overrun set; implemented.
> - Divider: fixed 217 (25 MHz / 115200); implemented.
> - The "about 8 MHz Fmax margin" in section 5 is outdated: PR #24 CI estimates 33.74, 34.74 and 34.77 MHz versus the 25 MHz constraint (pre-bitstream nextpnr estimate; run 39029631056, SHA a42f89a).
> - UART RX (needed for the Pi link) is NOT implemented and remains a separate future milestone.
> PR #24 is simulation and CI synthesis evidence only. It is not board-tested, and until PR #24 is merged this plan is not reflected on main.
> Still-useful content: the checklist in docs/40 and the review in docs/41 are retained.

Status: PLAN ONLY. No RTL, firmware or testbench was changed. Nothing was simulated or run in this session. Evidence class: CONFIRMED means read from source on main at 0f42040.

## 1. Starting point
- README says the old M8E branch (PR 17, synthesizable UART TX) is not on main. Its commits are not in this checkout, so the successor is written fresh and is not a cherry-pick. Earlier session notes said it was merged; the README and GitHub state should be re-checked by the owner before work starts.
- CONFIRMED: `rtl/periph/soc_uart.v` has no serializer. A write latches `tx_byte` and, only when SYNTHESIS is undefined, prints to stdout. `uart_tx` is never driven by data. The pin therefore stays idle in hardware.
- CONFIRMED: status reads at offset 0x04 return constant 1 ("TX ready"). Offset 0x08 returns 0.

## 2. Register-map conflict found (must be resolved first)
| Source | TXDATA | STATUS | Meaning of status bit 0 |
|---|---|---|---|
| `soc_uart.v` | 0x00 | 0x04 | 1 = ready (constant) |
| `sw/firmware/soc_regs.h` and `main.c` | 0x00 | 0x04 | main.c treats bit 0 as BUSY (loops while set). Against the current RTL this would hang forever |
| `sw/include/soc_regs.h`, `robot_drivers.h` | 0x00 | 0x08 (RX data at 0x04, BAUD at 0x0C) | busy |
| `robot_nav_firmware.s` (the firmware that is loaded) | 0x00 | 0x08 | busy; reads 0 from current RTL, so it never waits |
Proposal (needs owner decision D-A): adopt the `sw/include/soc_regs.h` map and the assembly convention (STATUS at 0x08, bit 0 = TX busy). It is the one the loaded firmware already uses. Fix `sw/firmware/soc_regs.h` and `main.c` in the same change, or mark them legacy.
Not checked: which of these headers any current build target compiles.

## 3. Proposed minimal design
- Parameter CLK_HZ (default 25000000) and BAUD (default 115200); divider = CLK_HZ/BAUD = 217 (rounded). Bit rate error about 0.006 percent (calculated, not measured).
- 8N1 transmitter, one-byte holding register, busy bit set from accept until stop bit completes.
- Write while busy: DECISION D-B. Options: (a) drop silently (matches current firmware poll loop, which already waits), (b) stall the bus (no ack), which could block the CPU and the watchdog heartbeat path, so NOT recommended. Recommend (a) plus a sticky overrun flag at STATUS bit 2.
- No RX, no FIFO, no interrupts in this step. RX for the Pi link is a separate later milestone (docs/38 spec, not started).
- The simulation `$write` stays under `ifndef SYNTHESIS` so existing tests are unchanged.
- Does not touch the safety filter, watchdog, E-stop or actuator path. Bus-timing effect: the write ack is unchanged, so CPU timing and the cycle counts in existing cosim logs should not change. This must be verified, not assumed, by re-running the existing cosim regression.

## 4. Tests (all simulation, small)
1. Unit testbench `sim/tb_soc_uart_tx.v`: write 0x55, 0xA5, 0x00, 0xFF, check start/data LSB-first/stop bit times at 217 clocks per bit, busy timing, overrun flag, back-to-back writes with polling.
2. Extend `sim/tb_ulx3s_top.v`: decode the firmware banner from `ftdi_rxd` and compare with the string. Invert the known pin-gap check only for items actually fixed.
3. Re-run existing targets (`make -C sim` regression list) and compare output and cycle counts against main. Record the commands and outputs.
4. Yosys: synthesis-only check that the module maps (no timing claim). Re-run of full PnR is CI-costly and needs approval.
Effort estimate (not measured): about 1 day including regression.

## 5. Out of scope and risks
- Banner decode in simulation proves RTL behaviour only. It is not board-tested.
- The 25 MHz clock and Fmax margin (about 8 MHz per docs/28) mean any added logic should be re-checked by PnR before a bitstream.
- Baud correctness on the real FTDI link is unverified until M11.

## 6. Decisions requested
D-A register map (section 2). D-B write-while-busy behaviour (section 3). D-C approval to start implementation on a new branch from main, separate from the M10b and M12 documentation PRs.
