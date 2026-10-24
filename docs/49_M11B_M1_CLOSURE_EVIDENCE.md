# 49 — M11b Milestone 1 closure: tests, evidence and simulation-runner cleanup

Status: **Milestone 1 accepted by owner (2026-10-24) as simulation-verified for the tested
workload**, subject to the limitations in section 5. Everything here is **RTL simulation only**
(Icarus Verilog 12.0, `vvp -N`). Nothing here is synthesized, routed, board-tested or robot-tested.
B1 (measured board clock), B2 (pin state of an unconfigured FPGA) and B3 (physical E-stop)
remain **OPEN**.

Previous docs: `docs/48` (M1 implementation + pause snapshot). This commit adds only test
harness, test runner, Makefile targets and documentation. **No functional RTL (`rtl/`), firmware
(`sw/`) or FPGA (`fpga/`) file is changed**, and the M11a bitstream and provenance are untouched.

Labels used below:
- **MEASURED**: ran in simulation, the log exists (logs are not committed, see section 4).
- **CODE**: concluded from reading source, not executed.
- **PROPOSAL**: a design suggestion; not implemented.

---

## 1. What this commit adds

| File | Kind | Purpose |
|---|---|---|
| `sim/run_vvp_checked.sh` | runner | Runs `vvp -N`. Positive mode: PASS only if exit code is 0, **every** `--require` marker is in the log, and there is no `FATAL` / `[WDTMON-FAIL]` / `[WDTMON-INCOMPLETE]`. Negative mode (`--expect-fail`): PASS only if exit code is non-zero, **not** a kill/timeout code (124 or >128), and every expected marker is present. |
| `sim/test_run_vvp_checked.sh` | runner self-test | SIGTERM-killed run, SIGKILL-killed run, missing marker, `$fatal` and usage errors must be handled correctly. |
| `sim/uart_stall_inject.v` | test-only module | Forces `u_uart.busy=1` from reset (`STALL_MODE=0`) or from the pass token (`STALL_MODE=1`); logs `[STALL]` lines when the watchdog trips. |
| `sim/pwm_idle_probe.v` | test-only module | After the pass token: counts PWM register writes, measures pin high-time over a `PROBE_WIN` window, prints `[PWMPROBE-END]`. Fatal if the window does not fit or is empty. |
| `sim/wdt_kick_monitor.v` | test-only (modified) | At the TB cycle limit before the post-pass window ends it now prints `[WDTMON-INCOMPLETE] ... NO PASS verdict` (it used to print PASS). It also hooks the TB time limit and prints its summary plus `[WDTMON-INCOMPLETE]` there (it used to print nothing). |
| `sim/tb_soc_nav.v` | testbench (modified) | On a time-limit failure it prints `[TB] TIME LIMIT: cycles, test_passed, RAM[4095], trap, disarm, wdt_expired, pwm_cmd` before `$fatal`. No change to pass/fail logic. |
| `sim/run_wdt_negative.sh` | runner (modified) | Uses `vvp -N`. Exit codes 124, 137 and 143 (timeout, SIGKILL, SIGTERM) are now rejected, so a killed run can't count as a "trip detected". |
| `sim/Makefile` | build (modified) | `VVP ?= vvp -N`; `test_nav` and `test_nav_div217` go through the checked runner; new targets `test_wdt_uart_stall`, `char_pwm_idle`, `test_sim_termination`, `test_vvp_runner`. `DIV217_POST_PASS`, `CHAR_DIVS`, `CHAR_POST_PASS` and `CHAR_PROBE_WIN` can be overridden for slow hosts. |
| `.gitignore` | repo | Ignores `sim/*.log` (logs written by the runners). |

Not included on purpose: `sim/tb_pwm_period.v` (PWM pin-period unit test from the 2026-10-20
investigation). It belongs to Milestone 2 (PWM scale) and stays untracked.

Unchanged and still using plain `vvp`: `sw/test/test_nav_boundaries.py` and
`sim/soc_closed_loop_cosim.py`. Both start `vvp` with `subprocess` and check results
themselves; `test_nav_boundaries` deliberately kills `vvp` early once it has the frames it needs.
They aren't affected by the exit-code issue in section 2.5, but they are not covered by the
checked runner either.

## 2. Measured results (MEASURED)

Firmware: `sw/firmware/robot_nav.hex` from milestone 1 (`018a8ff`). Watchdog timeout 500,000
cycles. Monitor budget 250,000 cycles (50%).

### 2.1 UART divider-217 watchdog regression (positive)
- Full run (closure review, firmware at `0adc7ac`, ended normally, not via the checked runner):
  `make test_nav_div217`, 1,000,000-cycle post-pass window, which covers the whole ~352k-cycle
  pass banner. Result: `[WDTMON-PASS]`, refreshes=16586, **max refresh gap 3,462 cycles**,
  minimum countdown 496,539 (99.3% of the timeout left), no trip.
- With the checked runner (this commit): `make test_nav_div217 DIV217_POST_PASS=20000`,
  CHECKED PASS, exit code 0, max gap 3,462, 99.3% left. This **shortened window does not cover
  the banner**. It only confirms the harness and runner work.

### 2.2 UART-stall negative controls (divider 16)
`make test_wdt_uart_stall`, exit code 0 (both controls failed as expected):
- Mode 0, stuck from reset: `[STALL] cyc=500090 flag_wdt_expired=1 disarm=1 pwm_cmd L=0 R=0`, vvp exit code 1.
- Mode 1, stuck at the pass token (cyc 122,274): tripped at cyc 622,105 (499,831 cycles later), disarm=1, PWM 0/0, vvp exit code 1.

So a stuck UART does not keep the watchdog alive. **Not run at divider 217.**

### 2.3 Idle-state PWM persistence (characterization, not acceptance)
`make char_pwm_idle` (bounded windows, see section 5), exit code 0 for each:
- div 16 (`CHAR_POST_PASS=200000 CHAR_PROBE_WIN=131072`): `en=1 dutyL=410 dutyR=589 disarm=0 writes_after_pass=0`; pin high L=820/131073 (6,256 ppm = 0.63%), R=1178/131073 (8,987 ppm = 0.90%).
- div 217 (`CHAR_DIVS=217 CHAR_POST_PASS=70000 CHAR_PROBE_WIN=65536`): same register state, 410/589 high counts per period (6,256 / 8,987 ppm), `writes_after_pass=0`.

After the pass token the last command stays applied with the gate enabled, and nothing writes
PWM again. This is the known M2 issue (section 6), and this test records it rather than accepting it.

### 2.4 Termination paths (all must fail, none may PASS)
`make test_sim_termination`, exit code 0:
- T1: gap budget 100 cycles, so the monitor reports `[WDTMON-FAIL] max refresh gap 3462 > budget 100`, vvp exit code 1.
- T2: `NAV_MAX_CYCLES=60000` (before the pass token): `[WDTMON-INCOMPLETE] run ended by TB cycle limit ... NO PASS verdict`, vvp exit code 1, no `WDTMON-PASS` in the log.
- T3: `NAV_TIME_LIMIT_NS=2 ms`: monitor summary plus `[WDTMON-INCOMPLETE] run ended by TB time limit`, and `[TB] TIME LIMIT: cycles=99995 test_passed=0 RAM[4095]=0x00000000 trap=0 disarm=0 wdt_expired=0 pwm_cmd L=441 R=558`, vvp exit code 1.

Note: the TB cycle counter stops at the pass token, so `NAV_MAX_CYCLES` only limits the run
before the pass token.

### 2.5 Simulator exit status (the investigation behind this cleanup)
- Plain `vvp` traps SIGTERM (for example from `timeout`) and **exits 0**, so a killed run looks like a pass. `vvp -N` exits 1. During the closure review three runs were cut off this way and logged exit code 0. They were renamed `*_KILLED*` / `*_INCOMPLETE*` and not used as evidence.
- `make test_vvp_runner`: all 9 self-test cases pass (clean pass accepted; missing marker, `$fatal`, SIGTERM-killed and SIGKILL-killed runs rejected; negative mode: `$fatal` accepted, a clean run rejected, a killed run rejected; calling without any marker is a usage error with exit code 2).

### 2.6 Other regressions with the new `VVP = vvp -N` (exit code 0 unless stated)
- `make test_rtl`: all subtests pass (NNA, safety filter, safety HW, NNA corners, adversarial, SoC, UART).
- `make test_nav`: CHECKED PASS ("All 8 Navigation SoC Hardware Assertions PASSED").
- `make test_rom_layout`: pass (layout, self-test, nav expected-PWM reference).
- `make test_wdt_negative`: `NEGATIVE TEST PASS (rc=1, trip detected)`.
- `make test_ulx3s_top`: `fails=0`, make exit code 0 (1 min 20 s).
- Not run in this pass: `test_nav_boundaries` (~7 min, unchanged code path), `test_cosim`, `test_py`, `test_quant`, `test_trained_nna`, `test_rl_nna`, synthesis/PnR (no expensive CI, per the owner's instruction).

## 3. Code-based conclusions (CODE, not executed)
- **The watchdog shows the CPU is alive, not that the motor command is fresh.** The idle loop keeps kicking the watchdog while the last PWM command (410/589, gate enabled) stays applied. Nothing in RTL bounds how old an applied motor command can be.
- **There is effectively one PWM writer**, the navigation step in `robot_nav`, but nothing enforces this. Any code path can store to the PWM registers.
- **On a watchdog trip, RTL disarm forces the PWM command to 0** no matter what the firmware does. This was observed at divider 16 in 2.2 and not tested at divider 217.

## 4. Reproduction and evidence handling
Run from `sim/` with Icarus Verilog 12 and the `riscv-none-elf` toolchain:
```
make test_vvp_runner
make test_rtl test_nav test_rom_layout test_wdt_negative
make test_wdt_uart_stall            # ~7-8 min
make test_sim_termination           # ~2-3 min
make test_nav_div217                # full 1M-cycle post-pass window (~8+ min on a normal host)
make char_pwm_idle                  # characterization; slow at defaults
```
Logs go to `sim/*.log`, which is git-ignored. Logs from the closure review were kept outside the
repo by the agent and are not committed (generated output).

## 5. Limitations
1. Simulation only. Nothing here verifies timing, real UART hardware, the board clock (B1), pin state before configuration (B2) or the physical E-stop (B3).
2. The full-banner divider-217 run with the **checked runner** could not finish on the agent host: heavy CPU steal (~23% of a core available) against a 600 s call limit, three attempts at `DIV217_POST_PASS=400000`. Full-banner evidence is the run in 2.1, which ended normally with the same firmware and monitor budget, before the runner existed. The default `make test_nav_div217` (1M window) still needs a run on a normal host or CI.
3. The idle-PWM characterization used shortened windows (200k / 70k post-pass cycles, 2 / 1 PWM periods measured), not the 1M default.
4. UART-stall negative controls were run at divider 16 only.
5. One firmware/workload (the 3 canned sensor cases in `robot_nav`). The 3,462-cycle maximum gap holds for that workload only.
6. The PWM pin duty scale problem (16-bit counter vs 0..1000 command, 0.76% at "stop" 500) is **unchanged**. It is Milestone 2 scope.

## 6. Proposals carried into Milestone 2 (PROPOSAL, not implemented)
Safe idle behaviour (explicit command clearing before idle), a single `motor_set` path with
writer verification, an RTL actuator-command freshness timeout, sign-magnitude command
representation and PWM frequency, reset/disarm/coast/brake/enable semantics, and pin-level and
negative-control tests. The detailed proposal is prepared separately for owner review. None of it
is implemented on this branch.
