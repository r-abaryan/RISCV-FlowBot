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
