# PR 18 readiness review, open safety risks, and M10b outline

Status: documentation only. No change to the safety filter, policy, firmware, RTL or study results. Simulation only; no hardware claims.

## 1. Evidence classes used in docs 30 to 35
- CONFIRMED (code): read directly from source in this checkout.
- OBSERVED (data): measured in logged simulation runs, with the stated subset and sample size.
- HYPOTHESIS: plausible, not tested. Must not be cited as a finding.

## 2. Confirmed from source (code reading, no run needed)
| Item | Python (sim) | Firmware | RTL |
|---|---|---|---|
| Stop/margin distance | 0.40 m (d_margin = robot radius + 0.15 (0.40 m)), `m6_common.py`, `safety_layer.py` | 25 cm, `MIN_STOP_DISTANCE_CM` in `sw/firmware/safety_driver.h:16` | none |
| Cap formula beyond margin | TTC-style scaling plus per-step cap | `((d_cm - 25) * 5) >> 3` Q7 per period, `safety_driver.h:92` | none |
| Distance-based filtering | yes | yes | NO. `rtl/safety/safety_filter.v` is a heartbeat/E-stop watchdog with no distance input. It cannot be parity-tested against the Python filter. |
- Consequence: the filter whose behaviour was studied in M9b/M10a (Python, 0.40 m) is not the filter in firmware (25 cm, different formula). Results on stalls and collisions do NOT transfer to firmware. Parity was not tested.
- Rays: 8 rays at -90, -60, -30, -10, +10, +30, +60, +90 degrees (`sim/robot_env.py:30-33`). No rear coverage. Rays are 20 degrees apart around the front axis (-10 and +10) and 20 to 30 degrees elsewhere; sub-ray-spacing obstacles can fall between rays. The filter receives only the minimum over rays.

## 3. Observed (data)
- M10a (docs/33, n = 40 per cell, one training seed per method): see that document for the filter on/off timeout and stall counts; they are not restated here.
- M10a-2: in a non-random subset of 21 stalled episodes (1050 window steps), CRITICAL_OBSTACLE_BRAKE in 86.4 percent of steps; closest ray is a side ray (index 0 or 7) in 79.2 percent of critical steps. See docs/34.

## 4. Hypotheses, untested
- That the side-ray rule causes the stall and a direction-aware margin would release it (all 8 distances and wall/pillar identity were not logged).
- That the per-step cap contributes to stalls (no reason code).
- That the stall mechanism generalises to other policies or arenas.

## 5. Unresolved safety risks (explicit register)
| ID | Risk | Status |
|---|---|---|
| R1 | Margin mismatch: Python 0.40 m vs firmware 25 cm (and differing cap formulas). Safety behaviour studied in simulation is not the behaviour that would run on the SoC. | OPEN, not tested, intended deployment margin undecided |
| R2 | Rear sector unsensed in simulation; unknown for the physical robot. Any reverse or recovery manoeuvre would be blind. | OPEN |
| R3 | No RTL distance-based safety filter exists; the only RTL safety block is a watchdog. Deterministic distance safety currently depends on firmware correctness. | OPEN, architectural |
| R4 | Stalls: filter gives safety, not liveness. Acceptability for the application undecided. | OPEN, owner decision |
| R5 | Single-scalar minimum input cannot distinguish front from side or approach from retreat. | CONFIRMED limitation |
| R6 | Rotation allowed in the critical branch assumes a circular footprint. | OPEN |
| R7 | Collisions of 0 in M9b are simulator-only with a circular robot, ideal rays and the Python filter. No sensor noise model validation against hardware. | OPEN |

## 6. PR 18 review results (2026-10-16)
- Remote head 5805a74 before this commit; PR open, draft true, merged false, base main (GitHub API). 22 commits, 305 files.
- Diff vs main: 264 study files, results/m9b and m10a/m10a2, sw/policy (m9b/m10a scripts, 5 model files), docs, 1 script, 1 sw/test. Modified (not added) existing files: sim/Makefile, sim/generate_tb_trained.py, sw/policy/train_policy.py. No changes under rtl/ or sw/firmware/.
- Manifest: results/m9b/study_manifest.sha256 has 264 lines, file set equals results/m9b/study exactly; `scripts/verify_m9b_manifest.sh` printed OK for 264 files. weights.sha256: 11 of 11 OK. Episode count in study files: 13200.
- Tests run: test_m9b_stats.py PASS (10 checks); test_m10a2_trace.py PASS; sw/test/test_rom_bounds.py: 2 passed, 2 SKIPPED (ELF cross-checks: no toolchain/ELF), result PARTIAL; make -C sim test_rl_nna exit 0 (25/25 vectors, 0 LSB); make -C sim test_trained_nna exit 0. Not run: full regression, cosim, M9b study, synthesis.
- Manifest limitation: it proves files are unchanged since being hashed, not that they were produced by the recorded code; the study is not re-run.

## 7. M10b outline: safety specification and cross-layer parity (NOT retraining, NOT started)
Goal: one written safety specification and demonstrated equivalence of Python, firmware and (where applicable) RTL implementations. No policy change.
1. Safety specification (owner decisions needed first): intended margin(s), sensor geometry of the physical robot including rear coverage, footprint, max speeds and rates, required behaviour when stalled (stop, escalate, recover), fault and invalid-reading handling.
2. Single source of truth: a table-driven spec (units, Q formats, thresholds) from which the Python reference and firmware constants are derived or checked.
3. Python reference filter as golden model; define exact integer semantics (rounding, saturation, units cm vs m).
4. Firmware parity: host-compiled build of `safety_driver.h` run against the golden model on a directed plus randomised vector set, including boundary values at margin, negative or invalid distance, and saturation. Report exact mismatch count.
5. RTL decision: either add a distance filter in RTL (new design, needs review) or document that distance safety is firmware-only and keep the watchdog as the independent layer. Owner decision.
6. Parity on the SoC: run the same vectors on the RV32IM simulation (existing picorv32 testbench flow) and compare to the golden model.
7. Safety properties as tests: never forward speed above cap, braking always allowed, monotonic in distance, output within actuator limits, deterministic.
8. Re-run (small, defined) M10a stall measurement only after parity, with the decided margin, as a characterisation, not a tuning.
Exit criteria: spec signed off by owner; zero mismatches over the vector set between golden and firmware (and RTL if built); risk register R1 to R3 updated with outcomes. Out of scope: retraining, reward changes, changing the stall behaviour.
Open questions for owner: deployment margin, physical sensor layout, acceptable stall behaviour, whether RTL filter is wanted.
