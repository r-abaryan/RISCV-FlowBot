# M7 Report: hardware safety interface, firmware safety parity, ROM layout

Logs and exit codes are in logs/m7/ (reg_summary.txt lists exit codes).

## M7A Hardware safety interface
RTL registers (safety_filter.v): 0x00 CTRL (b0 enable, b1 clear trip), 0x04 HEARTBEAT (key 0x5AFEC0DE), 0x08 STATUS (RO), 0x0C TIMEOUT.
Confirmed mismatch: soc_regs.h had TIMEOUT 0x04, HEARTBEAT 0x08, STATUS 0x0C, FORCE_DIS 0x10; both assembly files wrote the wrong offsets, so the hardware watchdog was never petted correctly. All three fixed.
New test: sim/tb_safety_hw_interface.v (make test_safety_hw): 27 checks, 0 errors (heartbeat, timeout trip, E-stop, clear/recovery, reset).
Note: the firmware kept running with the watchdog never serviced before; tb_soc_nav never reached the 2.5M-cycle default so it was not detected.

## M7B Firmware safety parity
Audit (assembly before fix): only a critical-obstacle zero-forward clamp existed. Missing versus C/Python: kinematic clamp 64, slew 8/tick, proximity cap (d-25)*5>>3, invalid distance as contact, state across ticks.
Fix: robot_nav_firmware.s now implements these, with state at 0x20003F00. Distance is the min of front sensors d2..d5 (decoded as cm = (q+127)*403>>8; q=-128 gives contact).
Verification: sw/test/test_nav_expected.py, an independent reference using the C-mirror, matches the SoC PWM values. tb_soc_nav expectations were updated (cycle 1 PWM 0x01f7/0x022e, cycle 2 0x01b9/0x022e, cycle 3 0x019a/0x024d); the old values reflected the unfiltered output. make test_nav passes.
Negative test: sim/run_wdt_negative.sh builds firmware with a 2000-cycle timeout; the watchdog trips as expected (exit 0 = trip detected). The positive run with 500000 never trips.
Limitations:
- The distance-to-cm mapping (403/256) is an approximation of the 2*(q/127+1) m encoding; the exact parity with Python float rounding is only tested on 3 vectors, not fuzzed.
- The C header changes were not compiled (no RISC-V C compiler checked this session); only the assembly path runs in RTL.
- soc_cosim_firmware.s got only the register-offset fix, not the full filter (the co-sim harness applies its own physics-side checks). It was not audited for parity.
- The 4 front sensor indices are an assumption taken from the sensor layout in the firmware mailbox; not checked against robot_env ray angles.

## M7C ROM layout
sw/test/test_rom_layout.py compares nav_weights.inc words with robot_nav.hex at the ELF symbol addresses: l1_weights@0x504 (32 words), l1_biases@0x584 (8), l2_weights@0x5a4 (4), l2_biases@0x5b4 (2): all match. A single-bit corruption self-test is detected. (make test_rom_layout)
This checks the image, not that the CPU fetches the same bytes; the end-to-end tb_soc_nav raw policy outputs matching the INT8 model supply that.

## Regression (make, exit codes in logs/m7/reg_summary.txt)
test_py, test_nna_corners, test_quant, test_safety_adv, test_safety_hw, test_trained_nna, test_nna_corners_sim, test_nav, test_soc, test_cosim: all exit 0. test_cosim: only 10 steps, ended step_limit_timeout, which is not a goal-reaching test.
Not run: synthesis, RL training, test_nna/test_safety/test_rtl targets (not individually run).

## M7D follow-up (review response)

1. **cosim_results.json**: restored to the base (92979ba) version; removed from the PR diff.
2. **SoC-executed boundary tests** (`sw/test/test_nav_boundaries.py`, `make -C sim test_nav_boundaries`).
   Patches the three sensor frames in `robot_nav_firmware.s`, assembles, runs the full soc_top RTL
   (tb_soc_nav), reads the real NNA raw outputs and PWM writes from the log, and compares the PWM
   with the independent Python mirror (`test_safety_c_mirror.f`) fed those raw outputs.
   Scenarios (3 ticks each): proximity cap (front sensor d3 at 30 cm range), invalid sensor (-128 -> contact),
   slew limit (open corridor). Each also checks the raw policy output actually demanded something the filter
   must restrict (otherwise the scenario is flagged as vacuous). Results: all 3 PASS (logs/m7/boundary_1..2.log).
   Negative controls (firmware mutated, same scenario must FAIL): no proximity cap, no stop zone,
   invalid-as-far, no slew limit: all 4 detected (logs/m7/boundary_1,3,4.log).
   **Scope of this test (what it does and does not establish):** it checks SoC-executed PWM traces
   (the PWM writes come from the real firmware running on the soc_top RTL). By design the harness kills the
   simulator (`vvp`) as soon as the initial PWM write plus 3 tick writes are logged, to save simulation time.
   It therefore does NOT run tb_soc_nav to completion and does NOT establish a clean final exit,
   end-of-test pass banner or assertion summary from tb_soc_nav. Clean tb_soc_nav completion is covered only by the
   separate test_nav target, run on the unmodified firmware.
   Runtime: ~50 s per item, run in separate invocations because of the 120 s tool-call limit; not part of the default regression.
3. **Front-sensor mapping** (`test_front_sensor_mapping.py`): robot_env ray angles are
   -90,-60,-30,-10,10,30,60,90 deg. Firmware front sensors d2..d5 = obs[2..5] = -30..+30 deg: correct.
   The 403/256 cm scale was checked exhaustively over all q in -127..127 against the env encoding
   (obs = q/127, hits = (obs+1)*2 m): firmware never over-estimates distance, max underestimate 1.13 cm.
   Caveat: this checks the intended encoding in robot_env.py, not that the pipeline feeding the mailbox packs bytes in that order (not checked).
4. **C header compile check**: `gcc -std=c99 -Wall -Wextra -Werror -fsyntax-only` on soc_regs.h,
   safety_driver.h, nna_driver.h: pass (logs/m7/c_header_hostcheck.log), and test_safety_c_compiled
   (host-compiled header vs mirror, 20000 vectors) passes. **This is host (x86/musl) compilation only. No RV32 C compiler is
   available here, so RV32 target compilation of the headers is NOT verified.**
5. **Re-runs** (logs in logs/m7/): test_safety_c_compiled, test_rom_layout, test_nav, test_front_sensor_mapping: exit 0.
   The firmware .s was not changed in this follow-up, so other earlier M7 results stand.

Still unverified: RV32 compilation of C headers; soc_cosim_firmware.s filter parity; closed-loop goal reaching;
boundary tests cover 3 scenarios at 3 ticks (not fuzzed); the stop-zone (d<=25) branch is only exercised via the invalid sensor scenario.
