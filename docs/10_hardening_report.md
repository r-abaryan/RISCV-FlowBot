# Verification and Engineering Hardening Report

**Project:** RISC-V Robot Control SoC (`rv32im-robot-soc`)  
**Status:** Verification Hardened & Regression Certified  
**Date:** October 2026  

---

## 1. Executive Summary

This engineering hardening effort elevates the RV32IM Robotics SoC from an experimental prototype to a robust, reproducible, and battle-tested open-source hardware implementation. 

Key hardening milestones achieved:
1. **Path Portability & Offline Reproducibility**: Root and simulation Makefiles dynamically resolve absolute paths; CPU source (`picorv32.v`) is fully tracked locally; simulation ROM paths are parameterized via macro defines (`ROM_INIT_FILE`).
2. **Assertion-Driven Verification & Watchdogs**: All testbenches (`tb_nna_top.v`, `tb_safety_filter.v`, `tb_soc_top.v`, `tb_soc_nav.v`, `tb_nna_corner_cases.v`, `tb_safety_adversarial.v`) employ non-zero `$fatal(1, ...)` exit codes and hard watchdog timeouts to eliminate hangs.
3. **INT8 Quantization Fuzzing & Corner-Case Stress Testing**:
   - `sw/test/test_nna_corners.py`: 1,000 randomized Monte-Carlo vectors plus saturation boundaries (+127/-128), zero scaling, identity pass-through, and bias dominance.
   - `sim/tb_nna_corner_cases.v`: 8 targeted RTL corner cases covering maximum saturation clamps, alternating sign cancellation, shift=0 arithmetic, parameter validation traps ($K \pmod 4 \ne 0$), and hardware buffer auto-copy layer chaining.
4. **Adversarial Hardware Safety Interlock Verification**:
   - `sim/tb_safety_adversarial.v`: Corrupted heartbeat key injection, concurrent E-stop race condition override, fail-safe register disablement (`reg_enable=0`), and asynchronous reset glitch immunity.
5. **Architectural Vulnerability Resolution**: Identified and resolved a safety flaw where software could clear a latched trip while the physical emergency stop bumper remained actively compressed. Physical E-stop assertion now enforces unconditional hardware trip locking.

---

## 2. Corner-Case Verification Matrix

### 2.1 INT8 Neural Accelerator (`rv_nna`)

| Test ID | Test Scenario | Expected Outcome | RTL Result | Status |
| :--- | :--- | :--- | :--- | :--- |
| **NNA-01** | Max Positive Accumulation ($16 \times 127 \times 127$) | Saturate to $+127$ (`0x7F`) | Clamped to `0x7f7f7f7f` | **PASS** |
| **NNA-02** | Max Negative Accumulation ($16 \times 127 \times -128$) | Saturate to $-128$ (`0x80`) | Clamped to `0x80808080` | **PASS** |
| **NNA-03** | Max Negative Product + ReLU | Clamped to $0$ (`0x00`) | Output `0x00000000` | **PASS** |
| **NNA-04** | Alternating Sign Cancellation ($X=[127, -127], W=[127, 127]$) | Exact cancellation to 0 | Output `0x00000000` | **PASS** |
| **NNA-05** | Extreme Bias Override (Negative Dot Product + Positive Bias) | Correct signed offset | Output `0x32` (+50) | **PASS** |
| **NNA-06** | Shift = 0 Requantization ($25 \times 3 \gg 0$) | Direct scale without shift | Output `0x4B` (75) | **PASS** |
| **NNA-07** | Parameter Error Handling ($K=5$, invalid alignment) | Core flags `STATUS.ERROR=1` and aborts | Aborted with error bit | **PASS** |
| **NNA-08** | Hardware Auto-Copy Output Buffer to Input Buffer | Core chains output to input in hardware | Input buffer auto-populated | **PASS** |
| **NNA-FUZZ**| 1,000 Random Monte Carlo Vectors in Python Reference | Bit-exact requantization alignment | 1,000 / 1,000 matched | **PASS** |

### 2.2 Deterministic Safety Interlock (`safety_filter`)

| Test ID | Adversarial Scenario | Safety Expectation | RTL Result | Status |
| :--- | :--- | :--- | :--- | :--- |
| **SAFE-01**| Corrupted Heartbeat Key Injection (`0xDEADBEEF`, bit flips) | Ignore keys, countdown expires, disarm | Watchdog tripped, motor disarmed | **PASS** |
| **SAFE-02**| Heartbeat Write vs Physical E-Stop Collision | Physical E-stop unconditionally overrides bus write | Combinational override, trip latched | **PASS** |
| **SAFE-03**| Trip Clear Attempt While Physical E-Stop Active | Hardware rejects clear command while button held | Trip remain latched; motors disarmed | **PASS** |
| **SAFE-04**| Firmware Disable Attempt (`reg_enable = 0`) | Disabling module must force fail-safe disarm | Motors immediately disarmed | **PASS** |
| **SAFE-05**| Boundary Timeout ($T = 1$ clock cycle) | Immediate clean expiration without deadlock | Watchdog expired, trip latched | **PASS** |
| **SAFE-06**| Asynchronous Reset Glitch Immunity | Actuator disarm asserts combinatorially on `!rst_n` | Instant disarm during glitch | **PASS** |

---

## 3. Discovered Hardware Bugs & Hardening Fixes

### Issue 1: Premature Interlock Clearance Under Active E-Stop
- **Component**: `rtl/safety/safety_filter.v`
- **Vulnerability**: In the initial design, a bus write with bit 1 set to `SAFETY_CTRL` unconditionally cleared `flag_tripped = 0`. If firmware wrote this register while the robot's physical collision bumper was still compressed against an obstacle, `flag_tripped` was briefly cleared, risking accidental motor re-engagement upon bumper release without an intentional user clear command.
- **Root Cause**: `bus_wdata[1]` cleared `flag_tripped` without checking `pin_estop_button`.
- **Resolution**: Updated `safety_filter.v`:
  ```verilog
  if (bus_wdata[1] && !pin_estop_button) begin
      flag_tripped     <= 1'b0;
      flag_wdt_expired <= 1'b0;
      wdt_countdown    <= reg_timeout_val;
  end
  ```
  Hardware now physically refuses to clear the trip state until the external emergency stop input is deasserted.

### Issue 2: Simulation Hang Risks
- **Component**: Testbenches (`tb_nna_top.v`, `tb_safety_filter.v`, `tb_soc_top.v`, `tb_soc_nav.v`)
- **Vulnerability**: Unbounded polling loops (`while (!bus_ready)` or `while (!done)`) lacked simulation watchdog timers, causing CI or regression runners to hang indefinitely if a regression occurred.
- **Resolution**: Added independent `initial begin #TIMEOUT; $fatal(1, ...); end` watchdog threads across all testbenches.

---

## 4. Test Suite Execution & Verification

Run the full hardened test suite with:

```bash
# Run all software and RTL regressions
make all

# Or run individual sub-suites:
make test_py          # Python reference, safety layer, E2E policy
make test_nna_corners # Python INT8 1,000-vector fuzzing suite
make sim_all          # All Icarus Verilog testbenches
make sim_nav          # Full-system end-to-end robot navigation simulation
```

All 6 testbenches run deterministically, report explicit PASS statuses, and exit with code `0`.
