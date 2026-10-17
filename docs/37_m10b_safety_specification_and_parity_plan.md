# M10b: safety specification draft and Python/firmware parity plan

Status: DRAFT for owner review. Documentation only. No change to the safety filter, firmware, RTL, policies or training. Nothing here approves any deployment threshold. All physical values are TBD. Evidence class of every statement: CONFIRMED (read from source in this checkout) unless marked otherwise. No new simulation was run.

## 0. Owner decisions recorded (2026-10-16)
- D1: a new specification-derived, bit-exact integer safety model ("SIM", to be written) is the intended parity reference. The current real-valued Python filter is a LEGACY implementation: it is compared against SIM and differences are reported, but exact numerical equality with it is not required.
- D2: refactoring firmware for testability is approved in principle; it needs a separate later implementation review. Nothing is refactored here.
- D3: future physical operation must prohibit reverse motion until adequate rear sensing and safety validation exist. Documentation only; no filter change now.
- D4: whether firmware should use the side rays (+-60, +-90 deg) is NOT decided. It waits for a direction- and footprint-aware safety specification.
- D5: emergency/safety braking may override ordinary acceleration (slew) limits, subject to verified physical constraints (motor, driver, traction, tip-over; all TBD).
- D6: specify a bounded stall timeout that enters a safe stopped/fault state and reports the condition. No automatic recovery maneuver.
- D7: 25 MHz is the nominal ULX3S wrapper clock. Actual clocks must be verified, and watchdog timing derived from the confirmed frequency. The 50 MHz in firmware comments is not relied on.
- D8: installing host C/RISC-V compilers and dependencies in the isolated sandbox is permitted for later approved verification. No new parity experiments are to be run yet.
- The 25 cm (firmware) and 40 cm (simulation) margins remain UNAPPROVED for deployment.

## 1. Inspected sources
- Python: `sw/safety/safety_layer.py` (DeterministicSafetyFilter), `sw/policy/m6_common.py:make_filter`, `sim/robot_env.py`.
- Firmware C header: `sw/firmware/safety_driver.h` (`safety_filter_command`).
- Firmware as actually run on the SoC: `sw/firmware/robot_nav_firmware.s` (`run_navigation_cycle`, hand-written RV32IM assembly). It does NOT include the C header; it re-implements the filter inline.
- RTL: `rtl/safety/safety_filter.v`, `rtl/periph/soc_pwm.v`, `rtl/soc_top.v`, `fpga/ulx3s/ulx3s_top.v`.
- Existing tests: `sw/test/test_safety_c_mirror.py` (hand-written integer mirror of the C header), `test_safety_c_compiled.py`, `test_front_sensor_mapping.py`, `test_safety_fault_injection.py`.

## 2. Exact behavioural differences (three implementations, not two)
| Item | Python (`safety_layer.py`, sim config) | C header (`safety_driver.h`) | Assembly (`robot_nav_firmware.s`) |
|---|---|---|---|
| Stop margin | d_margin = robot_radius 0.25 + 0.15 = 0.40 m (`m6_common.py`) | `MIN_STOP_DISTANCE_CM` 25 cm | literal 25 cm |
| Distance input | min over all 8 rays (`min(env.latest_hits)`, rays at -90..+90 deg) | one scalar supplied by caller | min over 4 front sensors only (indices 2..5, i.e. -30,-10,+10,+30 deg); side rays at +-60 and +-90 deg are ignored |
| Distance semantics | ray from robot centre, so margin includes robot radius | unspecified; 25 cm is not demonstrably centre-referenced | q7 to cm: `((q+127)*403)>>8`, range about 0..399 cm; negative result clamped to 0 |
| Max linear speed | v_max 0.8 m/s (env); filter clamps to v_max | clamp +-64 Q7, commented about 0.50 m/s (the Q7 scale is a comment, not derived) | clamp +-64 Q7 |
| Max angular | w_max 1.5 rad/s | +-64 Q7, commented about 1.0 rad/s | +-64 |
| Accel limit | a_max 2.0 m/s^2 times dt (dt 0.1 s gives 0.2 m/s per step); alpha_max 4.0 | slew 8 Q7 per tick, tick period undefined in source | slew 8 Q7 per tick; tick period not defined in source |
| Braking rule | stopping distance = margin + v^2/(2 a_brake), a_brake 1.5; proportional scale of v between margin and stopping distance | linear cap `((d-25)*5)>>3` Q7, no a_brake, no speed dependence | same cap formula as C |
| At or below margin | v = min(0, v) (reverse allowed), rotation unchanged | `tv = min(tv, 0)` | `v = 0` if v > 0; reverse passes (only forward is limited) |
| Per-step no-overshoot rule | Rule 4: v <= (d - margin)/dt | none (cap is formula only) | none |
| Invalid distance | NaN, inf or negative gives 0 (contact) | negative clamped to 0 | negative clamped to 0; no NaN or stuck-value detection |
| Inference failure | `inference_ok` False gives zero command, reason FAILSAFE_WATCHDOG_TIMEOUT | none in filter | none inline; indirect via RTL watchdog if NNA never finishes (heartbeat is after the NNA wait) |
| Rear sensing | none | none | none |

Consequences (CONFIRMED by reading):
1. The M9b/M10a results are for the Python 0.40 m, all-8-ray filter. They do not describe the firmware (25 cm, 4 front rays, different cap). This is risk R1 in docs/35.
2. The assembly, not the C header, is what runs. The compiled-header test only proves the header equals its Python mirror. Correction found late: `sw/test/test_nav_boundaries.py` (M7D) already runs the patched assembly on the full soc_top RTL in iverilog and compares PWM with the integer mirror `f()`, with mutation negative controls. So an L2-style path exists, but with a small number of hand-picked scenarios (not re-run in this session; it needs riscv-none-elf binutils and iverilog, availability not checked). The parity plan extends it rather than building a new harness.
3. Side rays ignored in assembly means a wall at 60 or 90 deg could be touched with no firmware reaction. This is a safety-relevant sensor-coverage gap, not an optimisation.
4. Units: Q7 to m/s and rad/s conversions are comments only. The Python env maps action 1.0 to 0.8 m/s while firmware clamp 64/128 is claimed 0.5 m/s: the two do not share a scale source.
5. Time bases differ: sim dt = 0.1 s; firmware control period is whatever the loop takes (cosim measured about 3,302 cycles of compute per cycle, not a defined period).

## 3. RTL watchdog and E-stop (CONFIRMED)
- `actuator_disarm = !rst_n || !reg_enable || flag_tripped || pin_estop_button`; combinational from the pin, so asserted E-stop disarms immediately; latching occurs when the block is enabled.
- Watchdog counts down from `reg_timeout_val` (reset default 2,500,000 cycles; comment says 50 ms at 50 MHz). Firmware sets 500,000 (comment: 10 ms at 50 MHz). ULX3S wrapper uses a 25 MHz clock without PLL, so these durations double (20 ms and 100 ms) unless the clock assumption changes. TBD, to be checked.
- Heartbeat requires key 0x5AFEC0DE at 0x50000604. Writing clear with E-stop pressed is refused. `reg_enable` is software writable: firmware can write enable=0, which disarms (safe direction), but note `reg_enable` reset value is 1.
- `soc_pwm.v` zeroes outputs when disarm_in or !pwm_en. The disarm acts on PWM outputs only; whether it removes motor power depends on the external driver (TBD hardware).
- Not provided by RTL: obstacle distance, speed limiting, sensor validity. By design (RTL is not obstacle avoidance).
- ULX3S E-stop pin is DIP sw[0] with UNVERIFIED polarity; this is a bring-up placeholder, not a physical E-stop. A hardware E-stop that cuts motor power independent of the FPGA is required and is not designed (docs/36 proposal is separate and unmerged).
- Firmware pets the watchdog after the filter every cycle, even when the filter output is zero; this is correct (liveness of the control loop) but means the watchdog does not detect "robot stuck braking".

## 4. Parameterized safety specification (draft)
Symbols. All TBD unless stated. Nothing below is an approved value.

| Param | Meaning | Value |
|---|---|---|
| R_body | circumscribed radius of real chassis (non-circular footprint) | TBD |
| v_max | maximum commanded linear speed | TBD (sim 0.8 m/s; firmware claimed 0.5 m/s; neither approved) |
| w_max | maximum angular speed | TBD |
| a_brake | guaranteed worst-case deceleration on real floor with real load | TBD (sim assumes 1.5 m/s^2, unmeasured) |
| t_ctrl | control period | TBD (sim 0.1 s; firmware not defined) |
| t_lat | sensor-to-actuator worst-case latency (sensor update, compute, PWM, driver) | TBD |
| t_wd | RTL watchdog timeout | TBD (firmware 500,000 cycles; clock frequency TBD) |
| e_s | sensor distance error bound, incl. min range, angular beam width, dropouts | TBD |
| d_sensor_ref | sensor offset from the body edge | TBD |
| theta_cov | sensor angular coverage, including rear | TBD (sim: 8 front-half rays, no rear) |
| d_react | reaction distance = v_max * (t_ctrl + t_lat) | derived |
| d_brake | v_max^2 / (2 a_brake) | derived |
| d_stop_min | R_body-referenced minimum clearance required before motion toward an obstacle: d_react + d_brake + e_s + d_margin_extra | derived, TBD |

Design rule (proposal): the stop threshold, speed cap and slew limit must be computed from the parameter table, not typed as literals; one parameter file feeds Python, the C header and the assembly constants (generated), so that parity is by construction plus test.

## 5. Safety properties (to be proved by test, simulation or analysis; none is verified for hardware)
Notation: d_dir(theta) = measured clearance in direction theta, v signed (positive forward), d_c = d_stop_min.
- P1 Forward proximity: if forward-sector clearance <= d_c then v_cmd <= 0.
- P2 Forward speed cap: v_cmd > 0 implies v_cmd <= f(d) where f is the speed from which a stop is possible within d - d_c given a_brake, t_ctrl and t_lat. Monotone non-decreasing in d.
- P3 Reverse (D3): future physical operation prohibits reverse motion (v_cmd >= 0 always) until adequate rear sensing and safety validation exist; only after that may reverse be allowed, and only if rear clearance is valid and > d_c. Currently there is no rear sensing so reverse must be prohibited (v_cmd >= 0 always) or limited to a stop. Note that the current Python/firmware filters permit reverse whenever blocked ahead; this is a behaviour the spec forbids until rear sensing exists (a finding, not yet a change).
- P4 Rotation: rotation in place must not be allowed if any point of the real footprint swept by the rotation can reach an obstacle closer than d_c. For a circular body this is trivially satisfied; for a non-circular body TBD (R6). Until footprint is known, rotation inside d_c is allowed only at reduced w_max_blocked (TBD).
- P5 Slew: |v_cmd(k) - v_cmd(k-1)| <= a_max * t_ctrl, same for w. Must also hold when braking is commanded by the filter, or braking itself is bounded by a_brake (D5: ordinary acceleration is slew-limited, but emergency/safety braking may override the slew limit, subject to verified physical constraints (a_brake, traction, tip-over, driver behaviour; all TBD). The braking override must itself be specified and bounded, and P5 then applies to non-safety changes only).
- P6 Braking sufficiency: from any admissible state, the commanded profile ends at v = 0 before clearance reaches R_body-referenced contact, given the parameter table.
- P7 Stall handling: stalls are a liveness failure, not a safety failure. The filter must never trade P1-P6 for liveness. Recovery behaviours (direction-aware filter, backing up) are out of scope of M10b and need P3 and rear sensing first. Per D6, the spec includes a bounded stall timeout (duration TBD) after which the system enters a safe stopped/fault state and reports the condition; leaving that state needs deliberate action. No automatic recovery maneuver is specified.
- P8 Sensor failure: invalid reading (NaN, out of range, negative, stuck for N cycles, missing update) is treated as contact in that direction and forces v_cmd <= 0 (forward sectors). Sensor timeout (no fresh sample within t_sensor_max, TBD) forces zero command. Detection of stuck-at values is not implemented today.
- P9 Inference/compute failure: if the NNA does not complete, no new command is issued and heartbeat is withheld, so RTL disarms within t_wd.
- P10 Emergency stop: E-stop asserted implies PWM outputs zero within one clock (RTL, simulated) AND motor power cut by an independent hardware path (TBD, not designed). E-stop reset requires deliberate action and must not auto-restart motion; clear is refused while pressed (implemented in RTL, simulated).
- P11 Power-up/reset: outputs disarmed during reset (implemented); after reset firmware must command zero until the first valid sensor sample (TBD, not verified).
- P12 Arithmetic: for all int8 inputs and all prior states the output is in range and no overflow occurs in the Q7 arithmetic (the compiled test covers the C header only).

## 6. Test plan (deterministic; not implemented, not run; no new experiments until approved)
Two kinds of test are kept separate, because they answer different questions.

| | Parity tests | Safety-property tests |
|---|---|---|
| Question | Does implementation X compute the same output as the reference SIM for the same input? | Does the output satisfy P1-P12, whatever the reference says? |
| Oracle | SIM (D1), bit-exact | Independent property predicates written from the spec, not derived from SIM code |
| Applies to | C header, assembly, (legacy Python compared and reported only) | SIM itself, then every implementation |
| A pass means | implementation matches SIM | behaviour is within the spec for tested inputs |
| Limit | if SIM is wrong, a matching implementation is wrong too | tested inputs only; not a proof; not hardware evidence |
A parity pass never substitutes for a property pass: SIM must first pass the property tests, then implementations are compared to SIM. Differences from the legacy Python filter are listed and classified, not required to be zero.

### 6.1 Parity tests (reference: SIM)
Goal: show the assembly filter (the code that runs), the C header and the Python filter agree under an explicit mapping, and document every intentional divergence instead of leaving it implicit. Decision D1 below determines the reference.

Levels:
- L0 SIM vs legacy real-valued Python filter (informational, per D1): define SIM as a bit-exact integer model (Q7, cm, shifts) of the specification. Compare it with the legacy filter configured with the same parameters and REPORT the differences (speed-dependent braking, no-overshoot rule, reverse, side rays, etc.). No equality is required; each difference is classified INTENTIONAL, LEGACY-BUG or TBD.
- L1 C header vs SIM: extend the existing compiled test (needs host gcc; not present in this sandbox right now: `command -v gcc` returned nothing, installable via apk, unverified).
- L2 Assembly vs SIM on RV32IM: run the filter section of `robot_nav_firmware.s` in the existing RTL simulation (iverilog plus PicoRV32) or an RV32IM instruction-set simulator. Preferred: a small dedicated firmware/testbench that preloads memory (last_v, last_w, sensor words, v_raw, w_raw), runs the filter section, and writes outputs; the filter section must be callable in isolation, which requires a firmware refactor (out of scope now; if refactoring is not approved, extract through testbench memory preload and PC breakpoints instead).
- L3 End-to-end cosim: existing `soc_closed_loop_cosim.py` compared against SIM on a fixed set of short episodes.

Vector sets (all seeds fixed, generated by a committed script, results committed as CSV with hash):
1. Boundary values: d = margin-1, margin, margin+1 cm and the cap-formula switchpoints; v_raw and w_raw at -128, -127, -65, -64, -1, 0, 1, 63, 64, 65, 127; last_v/last_w at the same set and at +-(slew) boundaries; sensor q values -128, -127, -1, 0, 1, 126, 127; each of the 8 sensors individually minimal (to expose the front-only rule in the assembly); ties between sensors.
2. Exhaustive small sweeps: the input space of one step (v_raw 256 x last_v 256 x d 0..400) is about 26M, feasible for the integer model on the host, but not on the RTL simulator; use exhaustive on host levels (L0, L1), and stratified plus boundary subsets (a few thousand) on L2.
3. Randomised: fixed-seed (documented) sequences of 50,000 steps on host; 2,000 on L2; includes sensor dropouts (negative, -128), sudden obstacle appearance, and alternating signs.
4. (Moved to 6.2.)
5. Divergence report: each mismatch is classified INTENTIONAL (spec'd), BUG, or TBD, and listed in a table with the owner decision.

Pass criteria (parity): L1 and L2: bit-exact equality with SIM on all vectors; L0: no pass/fail, difference report only. Failures are reported, not suppressed. Test results to be labelled simulated (RTL sim) or host-tested; none is board-tested.

### 6.2 Safety-property tests (independent of parity)
Predicates for P1, P2, P3 (reverse prohibited, D3), P5 (non-safety changes), P6, P7 (stall timeout reaches the safe/fault state within the bound, D6), P8, P11 and P12 are written directly from section 5 and run on every vector of the sets above, first on SIM, then on each implementation, plus fault-injection sequences (sensor dropout, stuck value, no update, stall). Properties that depend on TBD parameters are run with explicitly labelled placeholder values and are reported as parameter-dependent, not as approval of those values. RTL watchdog and E-stop properties (P9, P10) use the existing RTL simulation, with the clock taken from the verified frequency (D7). Results are labelled simulated or host-tested; none is board-tested or robot-tested.

## 7. Implementation plan and effort estimates (engineering estimates, not measured)
| Step | Content | Estimate |
|---|---|---|
| S1 | Owner decisions D1-D8 (recorded in section 0); remaining open items in section 9 | done / owner time |
| S2 | Parameter file plus generator for Python/C/asm constants (docs-only first, no firmware change until approved) | 0.5 day |
| S3 | SIM (spec-derived integer model), property predicates, L0 difference report | 1 day |
| S4 | L1: compile header, compare to SIM | 0.5 day (plus toolchain install, permitted by D8, not yet done) |
| S5 | L2: extend `test_nav_boundaries.py` patching to many vectors (each patch needs an assemble plus SoC run, so keep to a few hundred) | 1.5 to 2.5 days |
| S6 | Findings report: divergences table, sensor-coverage fix proposal | 0.5 day |
| S7 | Spec amendment once hardware values are known | depends on hardware |
Total about 4 to 5 days of agent work after decisions; CI cost small (host tests only plus a short RTL sim). No change to the filter occurs in M10b unless you approve it separately.

## 8. Missing hardware specifications (needed before any threshold can be derived)
Chassis dimensions and footprint shape; mass and load; wheel diameter and track width; motor and gearbox model; measured stopping distance and deceleration on the real floor; maximum safe speed target; motor driver and its enable/brake behaviour; distance sensor model (range, min range, field of view, update rate, accuracy, failure modes); sensor placement and count including rear; whether sensors are wired to the SoC and the sensor-to-register scale (the Q7 to cm map assumes 4 m full scale); encoder resolution; E-stop button type and power-cut topology; battery and brown-out behaviour; board clock (25 MHz wrapper vs 50 MHz comments); control loop period.

## 9. Decision status
Resolved: D1-D8, see section 0.
Unresolved or deferred:
- U1 (from D4): side-ray use in firmware, pending a direction- and footprint-aware specification.
- U2 (from D2): the firmware refactor design needs its own implementation review before any code change.
- U3 (from D5): the limits on braking override (a_brake, jerk, traction, tip-over) are TBD hardware values.
- U4 (from D6): stall timeout duration, the stall definition and the fault-state exit procedure are TBD.
- U5 (from D7): the actual clock (PLL settings, board oscillator) is not yet verified; the watchdog timeout in seconds is therefore unconfirmed.
- U6: all hardware values in section 8 and the TBD rows of section 4 (R_body, v_max, w_max, a_brake, t_ctrl, t_lat, t_wd, e_s, sensor model and placement, E-stop design). Until they exist, no margin or threshold can be derived or approved; the 25 cm and 40 cm margins stay unapproved.
- U7: approval to start implementation (S2 onward) and any parity experiment; none given.

## 10. Limitations of this document
Not verified: Q7 scale, real brake capability, the assembly's behaviour on any vectors beyond existing tests, ULX3S pin polarities. The coverage of `test_nav_boundaries.py` (scenario count, which sensors it varies) was not audited. Also the mirror `f()` takes one scalar distance, so it does not model the 4-front-sensor minimum. The time-base and clock claims come from code comments, not measurement.

## 11. Review addendum (from docs/41 review): explicit requirements and blocking items
Status: draft requirements derived from a documentation review. No RTL, firmware or safety logic was changed. Nothing here is verified on hardware.

### 11.1 Prominent blockers
**B1. 25 MHz watchdog timing discrepancy (BLOCKING for P9 and P10 evidence).** RTL comments assume 50 MHz. The ULX3S wrapper feeds the 25 MHz board clock without a PLL (not measured on a board). At 25 MHz the reset default of 2,500,000 cycles is 100 ms (comment says 50 ms), and the firmware value of 500,000 cycles is 20 ms (comment says 10 ms). Requirement: t_wd must be stated in seconds against the verified clock, carried into P9/P10 and into S3 to S5 as a gating parameter, and rechecked against the control period and braking distance. The estimated Fmax margin at 25 MHz versus 33 MHz (docs/28) must be considered when the clock choice is made. Until U5 is closed, no watchdog-time claim may be made.
**B2. Unconfigured-pin and reset-state behaviour (BLOCKING before any motor is connected).** FPGA pins are undefined or weakly pulled while unconfigured, during configuration and in reset. Requirement: the motor driver must default to off through external pull resistors (or an equivalent hardware gate), independent of FPGA state; this must be shown by schematic review and a bench measurement of the driver enable and PWM inputs during power-up, reconfiguration and reset. Not designed, not tested.

**B3. Independent hardware E-stop, motor-power cutoff and brown-out (BLOCKING before any physical motion, including wheels-off-ground tests with a powered motor supply).**
- B3a. A physical, accessible, latching E-stop must remove motor POWER (series contactor or relay, or an equivalent power-path cut) with no dependence on the FPGA, firmware, the neural policy or the RTL watchdog. The RTL `actuator_disarm` is a second, independent layer, not a substitute.
- B3b. The motor-power cutoff must be fail-safe: loss of the control signal, a broken wire or a de-energised coil must leave motor power off.
- B3c. Brown-out, logic-supply sag and FPGA reconfiguration must leave motors off, by hardware (supervisor or pull-downs), not by firmware. Motor-supply sag must not reset or corrupt the logic supply unnoticed.
- B3d. Evidence required before closure: schematic review plus a bench measurement (motors disconnected or wheels lifted) of E-stop-to-power-off, power-up, brown-out and reconfiguration. Not designed, not purchased, not tested. Docs/36 and docs/38 do not yet fix a circuit for this.

### 11.2 Further requirements (R) and blocking items (U)
- R-E1: E-stop pin input needs a synchroniser and a debounce or glitch-filter policy. Disarm today is combinational from an unsynchronised pin; the P10 "within one clock" wording must state what is meant for an asynchronous input. The ULX3S switch polarity is unverified and is a bring-up placeholder, not an E-stop.
- R-W1: The required reset state of the watchdog must be stated. `reg_enable` resets to 1 and is software writable; require who may disable it and that a firmware which never enables or services it still ends in a disarmed state. A disarm write is the safe direction, but the requirement must be explicit.
- R-W2: Clock loss: the watchdog uses the clock it monitors, so a stopped clock disables it. Require an independent hardware check (or external supervisor), or record it as an accepted risk with owner sign-off.
- R-P1: see B3 (promoted to a prominent blocker).
- U8 (blocking before physical motion): P3 forbids reverse, but the current filters let reverse pass and the policy can command it. The requirement is that reverse is clamped at the deterministic filter, not left to the policy.
- R-S1: Sensor timeout and stuck-sensor detection (P8) need a sensor model; define minimum-range behaviour (reads 0 or max) and the meaning of a "valid" sample for P11. The Q7 4 m scale is a simulation assumption.
- R-S2: Define the angular width of the forward sector used for the minimum in P1/P4; the existing filter model takes one scalar.
- U3 addendum: the simulation a_brake of 1.5 m/s^2 is unmeasured; P5 leaves safety changes unbounded until a_brake is known.
- R-V1: Python, firmware and image version identification and a build-hash check, so the tested image equals the deployed image.
- R-U1: The UART console must not influence actuation or the safety path, and a UART busy or overrun state must not delay the heartbeat or the safety filter. (The D-B UART in PR 24 drops a write while busy instead of stalling the bus; simulation only, and the heartbeat timing with the real 217-clock divider is not measured.)

### 11.3 Coverage of the 15 findings in docs/41 section F
| docs/41 finding | Covered by |
|---|---|
| 1 effort sum | no change needed (reviewer found it consistent) |
| 2 25 MHz watchdog time | B1 |
| 3 E-stop synchroniser/debounce | R-E1 |
| 4 watchdog reset state | R-W1 |
| 5 unconfigured pins | B2 |
| 6 reverse | U8 |
| 7 sensor timeout/min range | R-S1 |
| 8 definition of valid sample | R-S1 |
| 9 braking bound | U3 addendum |
| 10 forward sector width | R-S2 |
| 11 build hash | R-V1 |
| 12 power loss/brown-out/independent E-stop | B3 (was only R-P1) |
| 13 UART not in safety path | R-U1 |
| 14 clock loss | R-W2 |
| 15 U7 consistent | no change needed |
