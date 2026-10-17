# M10c: nonnegative chassis linear velocity (v >= 0) at the safety-filter output

Context: PR 21 docs/37 section 11 and notes/m10c_nonneg_velocity_design_note.md (design note, not in this branch).
Owner decisions D-A..D-G apply.

## Rule
The final linear velocity leaving the filter is never negative. It is the last operation on v, so the stored last_v is the clamped value.

## Verified placement
In robot_nav_firmware.s, label 15 is reached by every path (including the blez s2 skip, stop zone and cap path) after slew and proximity override, immediately before the store of last_v and before the drive-step mix. The guard `bgez s2,16f; li s2,0` sits before `sw s2,0(t0)`, so output and state are the same clamped register.

## Changes (implemented)
- sw/firmware/robot_nav_firmware.s: 2-instruction guard.
- sw/firmware/safety_driver.h: clamp before state update.
- sw/test/test_safety_c_mirror.py: mirror f().
- sw/safety/safety_layer.py: Rule 5 after Rule 4.
- Tests: sw/test/test_m10c_nonneg_grid.py (new), sw/test/test_nav_boundaries.py (rev/revbase/revmut modes, test-only injection built in a temp copy of the assembly).

## Not changed / still open
Wheel mixer (left = v - w, right = v + w) is unchanged: a single wheel can still run backwards in a pivot. This is NOT complete no-reverse safety.
Stale sensors, watchdog/inference faults, direction-aware and side/rear coverage (D-F), blockers B1, B2, B3, sensor validity, and the unapproved 25 cm / 40 cm margins remain open. No physical safety readiness is claimed.
sw/firmware/robot_nav.hex is NOT regenerated in this PR (it matches the pre-change source); it must be rebuilt in a separate approved step.
