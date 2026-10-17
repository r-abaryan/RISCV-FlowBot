# M10c: nonnegative chassis linear velocity (v >= 0) at the safety-filter output

Context: PR 21 docs/37 section 11 and docs/44_m10c_nonneg_velocity_design_note.md.
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

## Rebuilt firmware image (provenance)
- Source: sw/firmware/robot_nav_firmware.s (sha256 113e7e4d597b8f2843f44036ff026d86c981b704454cb2febe3ab9a9a4cb854e), PR 25 branch.
- Toolchain: riscv-none-elf-as / ld / objcopy, GNU Binutils 2.44 (Alpine package in the session sandbox).
- Build (run in sw/firmware, same commands as sim/Makefile target firmware):
  riscv-none-elf-as -march=rv32im -mabi=ilp32 robot_nav_firmware.s -o robot_nav.o
  riscv-none-elf-ld -m elf32lriscv -T linker.ld robot_nav.o -o robot_nav.elf
  riscv-none-elf-objcopy -O binary robot_nav.elf robot_nav.bin
  python3 make_hex.py robot_nav.bin robot_nav.hex   (533 words)
- sha256: robot_nav.elf 4b6895f8cc0677d24436082a9514a6993f8ba8535375d7dda149cdc66e61eb03;
  robot_nav.bin 31f7ac9a21ec3dbda466c9e69e68909411ba696f16ea6fd0d951be3352c20ea7 (2132 B);
  robot_nav.hex 1f5de89445ebf7753cba1caf8c17b72289319749053aa51a19f03300cabb1464.
- Only robot_nav.hex is tracked (elf/bin are gitignored). Built fresh; the old ELF was not reused.
- Control: the same toolchain rebuilding the pre-change source (082fd98) reproduced the old committed hex byte for byte, so the new hex differs only through the M10c change (2124 B to 2132 B).
- Status: assembled and simulated only. Not synthesized, not board-tested.
