# M5 Safety hardening: partial (Python reference model only)

Test: sw/test/test_safety_fault_injection.py (wired into make -C sim test_py). Result: 16 of 16 pass.

## Matrix
| Fault | Expected | Result |
|---|---|---|
| NaN/inf policy v or w (5 cases) | finite, in envelope, finite state | pass |
| Distance NaN / negative / -inf | forward motion blocked | pass after fix |
| Stuck max-forward policy toward wall (3 m) | margin 0.15 m never violated | pass after fix |
| Inference watchdog false | zero output | pass |
| 20000 random faulty inputs (fixed seed 1234) | finite, in envelope | pass |

## Defects found and fixed in sw/safety/safety_layer.py
1. NaN distance compared false against every threshold, so forward motion was allowed. Now invalid distance is treated as 0 (contact).
2. Stuck policy ended 0.14997 m, below the 0.15 m margin, because braking scale was proportional. Added per-period cap: v <= (dist - margin)/dt.

## NOT done / unverified
- The RTL safety_filter.v is only the hardware watchdog/e-stop; it does not implement these rules. The velocity rules run in firmware/Python. I did not check whether the C firmware matches the Python model, so fixes 1 and 2 are not yet ported to C.
- No formal checks, no jerk limit (only acceleration limit exists), no RTL fault-injection of the cosim loop.
- Sensor dropout is only modeled as an invalid distance value, not stale/frozen data.
- RTL regression not re-run (RTL unchanged).

## Update: C driver port
sw/firmware/safety_driver.h now applies the proximity stop after the slew limiter, treats negative distance as contact, and caps v per period at (dist-25)*5/8 Q7 LSB. Before, slew limiting could leave v up to 8 LSB forward at an obstacle (bug found by mirror test).
Verification: sw/test/test_safety_c_mirror.py is an integer Python mirror, not compiled C (no C compiler or RISC-V gcc in sandbox). Hand-sync risk remains. The hand-written assembly firmware (robot_nav_firmware.s) has its own simpler front-distance check and was not changed. RTL not touched, regression not re-run.

## Reconciliation with the post-merge-verification-fixes branch (this session)
- d4a1f02 (Python filter fixes + fault-injection tests) is content-identical to 1024af6 on that branch, apart from docs.
- 7abf3ff adds the C-side port (sw/firmware/safety_driver.h) and sw/test/test_safety_c_mirror.py. Both were MISSING from 1024af6/44d7eec, so the earlier branch had the Python fix but not the firmware fix. They are needed and included here.
- test_safety_c_mirror.py is a hand-written Python mirror. To avoid trusting it, test_safety_c_compiled.py now compiles the real header with the host gcc (harness: sw/test/safety_driver_harness.c, -Wall -Werror) and compares 20000 random vectors. Mutation check: changing the proximity cap shift in the header from >>3 to >>2 makes it FAIL (1391 mismatches, exit 1). Without a C compiler the test prints SKIP (not a pass).
- This compiles for the host, not for RV32; target-compiler behaviour (int promotion, etc.) is not verified.

## Evidence from this session (make -C sim, gcc 15 / iverilog 12 on Alpine)
| Command | Exit | Log |
|---|---|---|
| make -C sim test_py | 0 | logs/evidence/m5_test_py.log |
| make -C sim test_safety | 0 | logs/evidence/m5_test_safety.log |
