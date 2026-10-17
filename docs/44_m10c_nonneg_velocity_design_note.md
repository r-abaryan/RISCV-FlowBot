# M10b/M10c design note: deterministic nonnegative linear-velocity rule (U8)

Status: DESIGN AND TEST PLAN ONLY. Nothing implemented, no filter/firmware/RTL/policy change, no experiment, synthesis or CI run.
Baseline: docs/37 (branch flowbot/m10b-safety-spec, PR #21, sections 2, 5 P3, 11) and docs/41. Not repeated here; only deltas.
Evidence: everything below was READ from source in the PR #21 checkout. Nothing is simulated or tested by this note.

## 1. Rule (proposed, R-NN)
R-NN: for every tick and every input (policy output, sensors, state, fault), the linear velocity leaving the safety filter satisfies v_out >= 0.
It is applied as the LAST operation on v, after clamp, slew and proximity logic, and the stored state is the clamped value:
    v_out = max(v_out, 0);  last_v = v_out.
Reason for "last": the existing proximity stage already does min(v,0) / cap only for v>0, so reverse passes through. A final clamp does not depend on any earlier stage being right, and does not interact with sensor validity.
Scope: this is D3 (reverse prohibited until rear sensing and validation exist). It limits v only. It is removable only by a later approved change tied to rear sensing.

## 2. Exact change locations (proposed; NOT made)
| Impl | File / place | Change |
|---|---|---|
| Python (legacy) | sw/safety/safety_layer.py `filter_action`, after Rule 4, before `self.v_prev = v_safe` (about line 100) | `v_safe = max(0.0, v_safe)`. The watchdog branch already returns 0,0 |
| C header | sw/firmware/safety_driver.h `safety_filter_command`, after step 4, before "Update state" (about line 96) | `if (target_v < 0) target_v = 0;` |
| Assembly | sw/firmware/robot_nav_firmware.s, STEP C, label `15:` (`sw s2,0(t0)`) | insert `bgez s2, 15f`-style guard: `bgez s2,15f; li s2,0` before the store. Note the branch `blez s2,15f` at "proximity override" jumps to 15, so the clamp must sit AT label 15, before the sw. 2 instructions |
| Mirror | sw/test/test_safety_c_mirror.py `f()` | add `tv=max(tv,0)` as the last line before return. Its existing check `abs(st[0])<=V` stays |
Smallest scope: those 4 one-line edits plus tests. No constant, layout, RTL or policy change. Whether to also edit the legacy Python filter is a decision (D-C below), since D1 makes SIM the reference.

## 3. Interaction with other mechanisms
- Emergency braking: existing proximity logic zeroes v>0 immediately (not slew-limited, allowed by D5). With R-NN a braking request can only go to 0, never below, so braking cannot overshoot into reverse. Forward-only braking from 64 to 0 in one tick is a 64 LSB step; this is the existing D5 override, unchanged. Physical deceleration limits are TBD (a_brake).
- Slew: slew runs BEFORE the clamp. Slew can produce a negative intermediate (e.g. last_v=-8 from old state), the clamp then gives 0. Because last_v stores the clamped value, slew never starts from a negative state, so the slew limit applies to the real output |v(k)-v(k-1)|<=8 for acceleration. Test that the stored state is the clamped one (negative control: store pre-clamp value).
- Reset: last_v zeroed at boot (asm: 0x20003F00/04 set to 0, Python reset()). R-NN is true from tick 0. Open: P11 "zero until first valid sensor sample" is NOT implemented in any variant; R-NN does not provide it.
- Stale sensors: NO implementation has a staleness/timestamp check (asm reads fixed frames; Python takes a float; the only invalid case is q=-128 / NaN / negative = contact). R-NN does not substitute for P8. Needs a sensor-age input and t_sensor_max (TBD) before it can be specified bit-exactly.
- Watchdog faults: Python `inference_ok=False` returns 0,0 and resets state (satisfies R-NN). The asm has no inference-fault branch: the NNA wait loop `wait_l1` / `wait_l2` spins forever on done with no timeout, so a fault means no heartbeat and the RTL watchdog disarms (t_wd depends on B1). R-NN is not exercised there because the filter is never reached. RTL watchdog/E-stop stay independent and unchanged.
- Differential drive (NEW finding, needs your decision, D-A): the asm computes v_L = v - w, v_R = v + w with duty = ((x+128)*1000)>>8; v=0 gives duty 500 (mid scale = stopped). With v>=0 and |w|>v one wheel is still driven backwards (e.g. v=0, w=40 spins in place; v=8, w=40 reverses the inner wheel). R-NN guarantees nonnegative chassis linear velocity, NOT that no wheel turns backwards, and the robot has no rear sensing during pivots either. If "no reverse" is meant per wheel, the rule needs v_wheel>=0 and would forbid in-place rotation; that is a navigation-capability change. Also a comment in STEP D says "w_raw" but the code uses the filtered w (stale comment).

## 4. Differences between implementations (delta to docs/37 section 2)
| Item | Python | C header | Assembly |
|---|---|---|---|
| Current reverse | passes (v_safe=min(0,v_c2) when blocked, any negative otherwise) | passes | passes (`blez s2,15f`) |
| Distance input | min of all 8 rays, -90..+90 deg | caller scalar | min of bytes d2..d5 only = rays at -30, -10, +10, +30 deg (ray_angles index 2..5, sim/robot_env.py). Rays at +/-60 and +/-90 deg are ignored, so the wide-side obstacle is not seen by the asm |
| Rear | none | none | none (no rays beyond +/-90 deg exist in the sim either) |
| Margin | 0.40 m | 25 cm | 25 cm; neither approved |
| Braking cap | v-dependent stopping distance, proportional scale | linear cap (d-25)*5>>3 | same as C |
| Fault input | inference_ok | none | none (hardware watchdog only) |
Consequence: with the 4-sensor front sector, a forward-only robot with R-NN still has blind sides at +/-60..90 deg during turns. R-NN removes the rear-reverse risk only; sector coverage (docs/37 theta_cov) stays an open blocker for navigation.

## 5. Parity-test plan (tests NOT written or run)
Reference: SIM per D1 (integer Q7 model). For this task the existing `f()` in test_safety_c_mirror.py is the integer reference, amended with the R-NN line; a full SIM is a later item.
T1 (host only, seconds): mirror unit and random tests. Existing 50000-vector loop plus: `assert st[0] >= 0` always, including d<=25, d invalid, raw v in -128..-1 and starting last_v negative (inject). Independent predicates (not copied from f): P1 d<=25 => v<=0; P3 v>=0; P5 v(k)-v(k-1)<=8 when accelerating; P12 range; at v=0 PWM duty 500.
T2 (C header): compile safety_driver.h with the host compiler (D8 allows installing it; gcc status in this sandbox unverified) and compare to f() on an exhaustive grid: raw_v -128..127 x last_v 0..64 x d in {-5,0,24,25,26,30,60,100,300}, raw_w fixed. About 256*65*9 = 150k, seconds.
T3 (assembly on SoC, existing harness test_nav_boundaries.py): the policy cannot be steered to produce a negative v_raw with the three-frame patching. Plan: add a test-only patch of the firmware text inserted after the `sra s3, s3, 24` (w_raw extraction) that sets s2 to an injected value (e.g. -50, -128, +127). This is a test fixture, not a firmware change, and must be labelled so; the filter stage after it is the code under test. Add scenarios:
  - rev_clear: raw v=-50, open corridor => PWM left/right = duty(0 -/+ w) i.e. v_out=0.
  - rev_blocked: raw v=-50, d=20 cm => v_out 0 (today: passes negative).
  - rev_invalid: raw v=-128 with q=-128 sensor => 0.
  - rev_state: injected raw v = -64, +64, +64 in open corridor => expected v_out 0, 8, 16 (state stores the clamped 0). A filter that stores the pre-clamp value (-8) gives 0, 0, 8, so this detects it. Expected values come from independent predicates (v>=0; accel step <=8 from the stored output), not only from f().
  The harness runs 3 ticks per scenario; budget below.
Negative controls (mutations, same style as MUT): `no_nonneg_clamp` (delete the new guard) must be detected by rev_clear/rev_blocked; `state_unclamped` (clamp applied to the PWM path but last_v stores the pre-clamp value) must be detected by rev_state. A `clamp_before_slew` variant is NOT distinguishable in 3 ticks from the correct order (both give the same outputs), so it is covered by T1/T2 only; plus the 4 existing controls must still be detected. A control not detected = test FAIL.
Baseline step (before any change): run the same new scenarios against the CURRENT firmware and expect FAIL on rev_*. This proves the tests detect the bug. This is an experiment; needs your approval.
Also keep existing scenarios: proximity_cap, invalid_sensor, slew_open must still PASS (regression).
Not covered by T1-T3 (stays open): stale sensors (P8), reset-until-first-sample (P11), inference fault in asm (P9, hardware only), side-sector coverage, wheel-level reverse (D-A).

## 6. Test budget and effort
- Runs: T1 and T2 host-only, <1 min each (estimated, not measured). T3: 3 new scenarios (rev_clear, rev_blocked, rev_state; rev_invalid optional) + 2 new mutation controls + 4 old scenarios + 4 old controls = about 13 SoC runs max, each = assemble + iverilog sim. Time per run in this sandbox is NOT measured; docs/37 says "few hundred" is the upper end, we plan 13. Hard stop: if 15 runs exceed 30 minutes, stop and report.
- Preconditions: riscv-none-elf-as/ld/objcopy, iverilog available (check with command -v; earlier sandbox lacked the RISC-V assembler; /tmp/rv shims may be gone).
- Effort (engineering estimate): 1 session to write and baseline-run tests (T1-T3), 0.5 session for the 4 one-line edits, run, doc update. Total about 1.5 sessions. No CI beyond host tests.

## 7. Unresolved physical parameters (none invented)
Chassis size/footprint, mass, wheel diameter and track, motor/gearbox/driver, measured a_brake and stopping distance on the real floor, v_max for first tests, sensor model (range, minimum range, FOV, rate, accuracy), sensor count/placement including rear, control period and end-to-end latency t_lat, t_sensor_max, stall timeout, t_wd in seconds. The 25 cm, 40 cm and 5/8 LSB-per-cm cap are unapproved.

## 8. Hardware-operation blockers (unchanged, restated)
- B1: watchdog times are stated for 50 MHz but the ULX3S wrapper feeds 25 MHz without PLL (default 100 ms, firmware 20 ms). Not measured on a board.
- B2: unconfigured/reset pin state; driver must default off via external pulls; schematic review plus bench measurement needed.
- B3: independent hardware E-stop, motor-power cutoff, brown-out behaviour; not designed.
- U8: reverse passes the current filters; this note's R-NN is the proposed fix, but it is not implemented, and D-A (wheel-level reverse in pivots) and rear/side coverage remain.
R-NN is a software rule; it does not remove B1-B3. Physical motion, including wheels-off tests with powered motors, stays blocked.

## 9. Decisions needed before implementation
D-A: is "no reverse" chassis-level (v>=0, pivots allowed, proposed) or per-wheel (forbids pivoting)?
D-B: approve editing the safety filters (asm, C header) with R-NN as the final stage; this is safety-critical and per your rules requires explicit approval.
D-C: also edit the legacy Python filter, or only SIM and the integer mirror (D1)?
D-D: approve running the baseline (current firmware must FAIL rev_* scenarios) and the 13-run budget.
D-E: approve the test-only raw-v injection patch in the harness (alternative: search with the INT8 model for a frame that makes the real NNA output negative v; costs more and may not exist).
D-F: do we scope stale-sensor (P8/P11) as a separate follow-up PR? Recommended yes.
D-G: branch: continue on flowbot/m10b-safety-spec (PR #21 not merged) or a new flowbot/m10c-* branch from it. Recommended separate branch, separate PR.
