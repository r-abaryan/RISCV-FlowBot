# 31. M8E review fixes: strict test status, regression results, synthesis/P&R plan

Status: PR 17 stays draft. No CI dispatched, no bitstream, no hardware, no merge.

## 1. Makefile failure detection
Problem: `$(VVP) x.vvp` returns 0 on `$finish` even when a testbench printed FAIL or fails=N, and the
wrapper target piped through `grep`, which hid the simulator exit status entirely.

Fix: `sim/run_vvp.sh <vvp> <pass-regex> [timeout]` now wraps every Verilog test target (nna, safety, safety_hw,
corner cases, safety_adv, trained_nna, soc, nav, uart, ulx3s_top). It exits nonzero on:
simulator nonzero status, wall-clock timeout (exit 124 mapped), `$fatal`/`$stop`, any `[FAIL]`/FAILED/ERROR marker
(including `$readmemh` errors), nonzero `fails=`/`errors=`/`mism=` counters, or a missing success marker (silent early exit).
test_cosim is wrapped in `timeout` (Python already `sys.exit(1)`/asserts on LSB discrepancy).

The new strict runner immediately caught a defect of my own: after my first Makefile edit the wrapper target lost
its `cd $(ROOT_DIR)`, the ROM hex failed to load, and the test reported fails=3 with exit 2. Fixed.

Negative test: `make -C sim test_negative` (also first in `test_rtl`) runs `sim/negative/run_negative.sh` on deliberately
bad benches: compile error, `$fatal`, `[FAIL]` marker with a PASS line, nonzero fails counter with a PASS line,
silent early finish, `$stop`, a hang (timeout), and one good bench that must be accepted. Result: all detected, good accepted.

Known limit (found while writing the test): `$finish(1)` yields vvp exit 0 in this Icarus 12.0, so a bare nonzero
`$finish` code is not detectable; detection relies on markers/counters/pass-marker. Testbenches must print their own FAIL.
Python tests were not changed; they already use assert/sys.exit (not audited line by line).

## 2. Local regression (Icarus Verilog 12.0, this sandbox, real UART default 217 clk/bit where the bench uses it)
| Target | Result |
|---|---|
| test_negative | pass (7 detected, 1 accepted) |
| test_uart (unit) | pass |
| test_nna, test_safety, test_safety_hw, test_nna_corners_sim, test_safety_adv | pass |
| test_trained_nna | pass (25/25, 0 LSB) |
| test_soc | pass |
| test_nav | pass (Total Simulation Cycles 57389) |
| test_ulx3s_top | pass, fails=0, 148 banner bytes decoded on ftdi_rxd (4m49s; first strict run 7m35s was the failing mis-edit) |
| test_cosim | pass, 0 LSB discrepancy |

| test_py, test_quant, test_nna_corners (Python) | pass (rc 0, 58 golden/fuzz tests) |

Not run: `make all` as one command, synth_check (no Yosys).

## 3. Behaviour and latency differences caused by the real UART
Measured:
- test_cosim with the testbench UART at 4 clk/bit (as committed) and re-run at 217 clk/bit: both give mean hardware inference
  3304.9 cycles, 0 LSB discrepancy. Identical to the pre-PR-17 baseline (577afe4) re-run in this session: 3304.9.
  Reason (checked by grep): soc_cosim firmware never touches the UART, so the cosim path is not exercised by the UART change at all.
  This is a statement that the figure is unchanged, not a revalidation of control-loop latency with telemetry on.
- test_nav (robot_nav firmware) total cycles 57389 with UART at 4 clk/bit; this bench was not re-run at 217 and no
  telemetry-in-loop latency is claimed.
- Wrapper bench (217 clk/bit): banner of 148 bytes completes at simulated 14.20 ms vs. reset release; arithmetic estimate of added
  cost is 148*10*217 clocks = 321,160 clk = 12.8 ms at 25 MHz (docs/30 said 12.9; the exact product is 12.85 ms).
- Behaviour changes: writes while busy are dropped and set sticky OVERRUN (firmware polls, wrapper bench saw 0 overrun and 0
  writes-while-busy); the old firmware's back-to-back writes would lose bytes, so soc_firmware.s was changed.
Not measured: any per-step control-loop latency with real-rate telemetry. If firmware ever prints inside the control loop at
115200 baud a 10-char line costs ~86 kclk (about 3.5 ms at 25 MHz), which would dominate; this is arithmetic, and policy must be to
poll TX_BUSY outside the loop or buffer. Open question for the owner.

## 4. Proposed synthesis and three-seed 25 MHz P&R validation (NOT dispatched, approval requested)
Existing workflows, unchanged: `synth-soc-top.yml` (pinned Yosys, flat soc_top, no runtime claim) and `pnr-soc-top.yml`
(OSS CAD Suite 2026-10-14, ulx3s_top, LFE5U-85F CABGA381 speed 6, `--freq 25`, seeds 1,2,3, `--timing-allow-fail`, classified by
scripts/pnr_classify.py, artifacts uploaded always).
Plan, in order, one dispatch each, on branch flowbot/m8e-uart-tx at the final PR head:
1. synth-soc-top: confirm UART RTL synthesizes, ROM-init check passes, collect cell counts.
2. pnr-soc-top (3 seeds, 25 MHz): classify each seed.
Comparison baseline = docs/28 (commit dac57fb): LUT4 8753, CCU2C 579, TRELLIS_FF 2682, DP16KD 38, MULT18X18D 12 (pre-P&R Yosys), seeds per docs/28.
Expected qualitative change: a few FFs (divider counter about 8 bits, shift register 8, state/overrun) and some LUTs; NOT a prediction of numbers.
Acceptance checks (all from tool output): no ERROR in logs; `ftdi_rxd` still passes check_lpf_ports; no new latches/inferred
tri-states; FF/LUT delta versus baseline reported; per-seed TIMING_MET/FAILED/ROUTING_FAILURE reported, not averaged;
any failure kept as a negative result with logs.
Caveats: the new synth is the first run of the UART RTL on Yosys (my sandbox has no Yosys); P&R at 25 MHz is the board clock, and
the design's CPU clock relation to it is per existing docs; timing-met in nextpnr is not a hardware claim; 3 seeds is a small sample.
Cost: two workflows, up to 120 min each timeout. Need owner approval before dispatch (workflow_dispatch needs the workflow on the
ref; both are on main).
