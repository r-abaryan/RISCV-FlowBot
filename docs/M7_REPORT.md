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
