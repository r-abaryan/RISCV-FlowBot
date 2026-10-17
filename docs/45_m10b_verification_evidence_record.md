# M10b verification evidence record

Status: documentation only. No tests were rerun to write this record. No RTL, firmware or safety logic was changed. This is not a hardware-readiness claim.

## Tested commit
- This document is committed on a documentation branch on top of main; the documentation commit SHA is NOT the tested SHA. Tests ran on main a6fb987 only, with no code differences from the documentation commit.
- main a6fb98766b512545308d5cf4f68d98095fba2c9f (merge of PR 25, M10c nonnegative velocity). All evidence below applies to this SHA, except where marked as previously reported.
- Environment: sandbox with iverilog, make, numpy, riscv-none-elf binutils. Level: SIMULATED (iverilog RTL simulation of soc_top; Python/C mirrors). Not synthesized, routed, board-tested or robot-tested.

## 1. Assembly / SoC parity: test_nav_boundaries default suite
Command, once per item: `cd sw/test && python3 test_nav_boundaries.py <kind:name>`. Logs are archived in `docs/evidence/m10b_nav_boundaries_logs.tar.gz` (sha256 in the adjacent `.sha256` file: 767002aee17f7f647e7be0521afaaf18fa7111a1d71aadb53b14c19ae4e4a204). Each log holds the test output line, RESULT and rc/secs; no secrets or machine paths. Verify with `sha256sum -c`.

| Item | Result | Time |
|---|---|---|
| scen:proximity_cap | PASS | 98 s |
| scen:invalid_sensor | PASS | 93 s |
| scen:slew_open | PASS | 93 s |
| mut:no_proximity_cap | PASS (mutation detected on proximity_cap) | 94 s |
| mut:no_stop_zone | PASS (detected on invalid_sensor) | 95 s |
| mut:invalid_as_far | PASS (detected on invalid_sensor) | 94 s |
| mut:no_slew | PASS (detected on slew_open) | 93 s |

Execution mode: SPLIT. Seven separate single-item invocations, each building the RTL in a fresh temp directory. The combined default run (no arguments, one process) was NOT executed, because it would exceed the session time budget. Equivalence rests on code reading of main(): the default run expands to the same seven items. That is an inference, not a measured result.

Scope: 3 scenarios x 3 ticks = 9 ticks, plus 4 mutation (negative) controls. This is a SPOT CHECK of the assembly firmware on the SoC RTL against the reference filter. It is not exhaustive assembly parity.

## 2. C / reference parity (previously reported, not rerun here)
Reported by the preceding session: C versus integer mirror passed 151,725 grid cases and 20,000 compiled vectors; 16 fault-injection cases passed on the mirror; 0 negative velocity outputs. These figures come from that session's report. The run logs are not in the repository and were not regenerated now, so treat them as reported, not independently reproducible from the repo today.

## 3. Not run / outside the default suite
- M10c reverse-clamp items (rev_clear, rev_blocked, rev_state, rev, revbase, revmut and mutations no_clamp, store_preclamp) are not part of the default suite, need BASE_REV, and were NOT run in this session.
- test_m10c_nonneg_grid.py was not rerun in this session.
- Combined single-process default run: not run.

## 4. What belongs to main versus PRs
- main a6fb987: all evidence above (the tested tree already includes PR 25 changes, i.e. the M10c clamp in the assembly, C driver, mirror and Python layer, and the rebuilt robot_nav.hex).
- PR-specific commits (for example 91d73a8 and 56435fd of PR 25): their own test claims are documented in docs/43 and 44; nothing from this session verifies them separately. No open-PR evidence is included here.
- Earlier evidence (docs/42, PR 24 UART/synthesis) is separate and not covered here.

## 5. Unresolved (unchanged)
- B1, B2, B3 blockers.
- Reverse-motion enforcement: only chassis v >= 0 at the filter output; the wheel mixer can still drive a wheel backwards in a pivot.
- Sensor coverage (side/rear, direction-aware) and sensor validity.
- Physical stopping thresholds: the 25 cm firmware margin and 40 cm simulation margin are not approved; no thresholds derived from real dimensions, braking, sensor accuracy and latency.
- Independent safety-property verification is NOT complete: the properties checked so far use the same reference model as the implementation.

## 6. Remaining-verification checklist
- [ ] Run the combined default test_nav_boundaries in one process (needs a runner with more than 12 minutes).
- [ ] Run the M10c rev/revbase/revmut items with BASE_REV, and test_m10c_nonneg_grid.py.
- [ ] Commit logs or CI artifacts for the 151,725 / 20,000 / 16-case runs so they can be reproduced from the repo.
- [ ] Add independent property checks (not derived from the reference model).
- [ ] Extend assembly/SoC scenarios beyond 9 ticks.
- [ ] Resolve B1/B2/B3, reverse-motion enforcement, sensor coverage, derive stopping thresholds (owner decisions).

## 7. Recommended next bounded step
With owner approval, run the M10c rev-mode items from a main checkout (single invocations, about 95 s each) and record results in this document. Do that before any further safety-logic work.
