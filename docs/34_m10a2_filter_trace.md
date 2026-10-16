# M10a-2: safety-filter trace of stalled episodes (diagnostic logging only)

Scope: observation only. No change to the safety filter, policies, training, firmware or RTL. Simulation only; no hardware claims.
Code: `sw/policy/m10a2_trace.py` (replay with per-step logging), `m10a2_analyze.py` (summary), `test_m10a2_trace.py` (test).
Data: `results/m10a2/trace.json` (per-step log), `results/m10a2/summary.md` (generated tables).

## Method
- Subset: the first 4 stalled episodes per policy/env cell (il101, rl1 by A, B, C) from M10a, filter on, max_steps 150, seeds 70000+i. Stalled means timeout with net displacement over the last 50 steps below 0.5 m (the M10a definition). 21 episodes (rl1 A has only 1 stalled episode).
- Logged per step: filter reason, requested v/w, permitted v/w, previous v, minimum ray distance and its ray index, d_margin, goal distance and its change, realised v, consecutive-stall counter (realised v below 0.05).
- The replay uses the same control flow as `m10a_diag.py` and only reads extra state. No random numbers are drawn.
- Equivalence check: every replayed episode matched the stored M10a result in all fields (success, collision, steps, distances, fractions, path length): 21 of 21. `test_m10a2_trace.py` checks this for 3 episodes and also that two replays give identical logs.

## Reproduce
    apk add py3-numpy            # if numpy is missing
    cd sw/policy
    python3 m10a2_trace.py 4     # exits non-zero if any replay differs from M10a; writes results/m10a2/trace.json
    python3 m10a2_analyze.py     # writes results/m10a2/summary.md
    python3 test_m10a2_trace.py

## Findings (21 episodes, last-50-step windows, 1050 steps)
1. The reason code in the stall window is CRITICAL_OBSTACLE_BRAKE in 86.4 percent of steps (907 of 1050). NORMAL and DYNAMIC_TTC_BRAKING make up the rest. In 20 of 21 episodes the step at which the stall counter first reaches 10 is a CRITICAL_OBSTACLE_BRAKE step (the other one is DYNAMIC_TTC_BRAKING).
2. The policy keeps asking to move: in 88.7 percent of window steps v_req is above 0.1 while the permitted v is below 0.02. Median v_req on CRITICAL steps is 0.41.
3. The CRITICAL steps sit right at the threshold: median min ray distance 0.384 m against d_margin 0.400 m (robot radius plus 0.15).
4. The closest ray on those steps is a side ray (index 0 or 7, at -90 or +90 degrees) in 79.2 percent of cases (718 of 907). So the robot is often held by an obstacle or wall beside it, not in front.
5. Goal progress in the window is about zero (mean change in goal distance -0.0004 m per step). The filter permits some turning (52 percent of CRITICAL steps have permitted |w| above 0.1 rad/s) but the policy's turning (mean |w_req| 0.36 rad/s) does not lead out of the zone.

## Interpretation (hypotheses supported by this trace, not proven)
- The rule in `sw/safety/safety_layer.py` uses the minimum over all 8 rays, regardless of ray direction. Any obstacle within 0.4 m at any bearing, including a side bearing, forbids forward motion (v is capped at 0 or below). A robot lying along a wall or between obstacles can then only rotate; if the policy's turn does not move it away, it stalls. That matches the data. It is consistent with the filter behaving as designed (conservative), not with a bug.
- I did not test counterfactuals (for example direction-aware margins or a recovery rule). Doing so would change the safety layer and is outside this task.
- Not checked: whether the side-ray hits are walls or obstacles (not logged), episodes outside the 21-episode subset, whether rule 4 (per-step limit) contributes (it is not a separate reason code), and any statistics beyond counts. The subset is the first 4 per cell, so it is not a random sample.

## Decision needed from owner
Options: (a) document the stall as a conservative-safety limitation; (b) design a deterministic, direction-aware or recovery rule, with its own verification and firmware/RTL parity work. Neither has been started.

---

# Addendum: owner decision, code references and limitation statement

Owner decision (this session): option (a). The stall is documented as a conservative-safety limitation. No safety behaviour, recovery rule, policy, training, firmware or RTL was changed and no new experiment was run. Everything below that is marked UNAPPROVED is a possible future design idea only.

## A. Confirmed code behaviour (read from source)
Line numbers refer to this branch.

| Item | Source | What the code does |
|---|---|---|
| Input to the filter is the minimum over all rays | `sw/policy/m6_common.py:53` and `sw/policy/m10a2_trace.py:21-23` | The caller passes `min(env.latest_hits)`. No ray direction is passed to the filter. |
| Filter signature has one scalar distance | `sw/safety/safety_layer.py:43` | `filter_action(v_raw, w_raw, min_obstacle_dist, inference_ok)`. The filter cannot distinguish front from side. |
| Margin value | `sw/policy/m6_common.py:37-41` (also `a_max=2.0`, `a_brake=1.5`; the `safety_layer.py:15` default 0.15 is overridden) | `d_margin = env.robot_radius + 0.15`. With `robot_radius = 0.25` (`sim/robot_env.py:20`) this is 0.40 m. Rays start at the robot centre. |
| Critical condition | `sw/safety/safety_layer.py:76-80` | If `min_obstacle_dist <= d_margin`: `v_safe = min(0.0, v_c2)`, `w_safe = w_c2`, reason `CRITICAL_OBSTACLE_BRAKE`. Forward velocity is forbidden; reverse and rotation (after slew limiting) are allowed. |
| Dynamic braking condition | `safety_layer.py:37-41, 73, 81-87` | `d_stop = d_margin + v_c2^2 / (2*a_brake)` for `v_c2 > 0` (a_brake 1.5). If `d_margin < min_dist < d_stop`, `v_safe = v_c2 * scale`, with scale linear from 0 at the margin to 1 at `d_stop`. Reason `DYNAMIC_TTC_BRAKING`. |
| Per-step cap (no reason code of its own) | `safety_layer.py:92-94` | If `v_safe > 0`: `v_safe = min(v_safe, max(0, min_dist - d_margin) / dt)`. It changes `v_safe` without changing the reason string. |
| Slew limiting happens before the obstacle rule | `safety_layer.py:62-70` | `v_c2` is `v_prev` moved by at most `a_max*dt`. |
| Invalid distance is treated as contact | `safety_layer.py:48-50` | NaN, inf or negative becomes 0.0. |
| Firmware version differs in form | `sw/firmware/safety_driver.h:16, 87-95` | Fixed `MIN_STOP_DISTANCE_CM 25`, a linear cap `(d_cm - 25)*5>>3`, no `d_stop` term, no reason code. The firmware margin (25 cm) is not the 0.40 m used in these closed-loop runs. I did not check how the margin is set in the firmware or RTL for the stall experiments, nor whether firmware and Python are bit-equivalent here. |

Confirmed consequence: because the filter receives a single minimum over all rays, any surface (wall or pillar) whose ray distance is at or below 0.40 m at any bearing makes the critical branch fire and forbids forward motion. This follows from the code and does not depend on the trace. Rays are cast (front half-plane only, -90 to +90 degrees) against the arena walls and the circular pillars (`sim/robot_env.py` raycast), so "obstacle" here includes walls.

The ray at 0.40 m from a centre with radius 0.25 means the robot body is 0.15 m from the surface along that ray.

## B. What the trace shows versus what is still a hypothesis
Confirmed by logged data (21 stalled episodes, 1050 window steps, non-random subset):
- CRITICAL_OBSTACLE_BRAKE in 86.4 percent of window steps; policy requests forward above 0.1 while permitted is below 0.02 in 88.7 percent; median min ray distance 0.384 m against 0.400 m; the closest ray is a side ray (index 0 or 7) in 79.2 percent of critical steps.

Hypothesis (not tested): that the stall is caused by the side-ray rule, meaning that a direction-aware margin would release these episodes. The data are consistent with it, but:
- The closest ray being a side ray does not show that the front was clear. Only the minimum and its index were logged, not all 8 distances.
- Whether the side hit is a wall or a pillar is not logged.
- A counterfactual run would be needed, and it was not done. It might also expose collisions that the current conservative rule prevents.
- The cause of the policy's failure to turn away (policy behaviour, versus the filter slew limit on w, versus the environment) is not separated.
- Whether the stall is a property of the filter, of these arenas, or of these policies is open. Do not generalise to other policies or arenas.

## C. Limitation statement (accepted)
The current deterministic filter is conservative by design. It guarantees no forward motion when any ray is within 0.40 m, at the cost of liveness: a robot that ends up within 0.40 m of a surface at a side bearing can stall indefinitely if the policy does not rotate or reverse away. In the M10a-2 subset this was the dominant stall mode. Timeouts attributed to it are safety-preserving and should be reported as stalls, not as policy collisions or successes. The filter provides a safety property (no forward drive into the margin), not a progress guarantee.

## D. Possible future design options (UNAPPROVED, not designed, not implemented, not evaluated)
Each would change safety behaviour and would need its own review, tests, and Python/firmware/RTL parity work before any use.
1. Direction-aware margin: apply the critical rule only to rays within a forward cone (or weight by heading), using a smaller side margin. Risk: turning or curved motion can sweep the body into a side obstacle; needs a swept-footprint argument.
2. Sign-aware motion check: forbid only motion components that reduce clearance on the closest ray, using requested v and w.
3. Deterministic recovery rule: after N consecutive stalled steps, command a bounded reverse or rotate-away manoeuvre. Risk: the simulated rays span only -90 to +90 degrees (`sim/robot_env.py:30-33`), so there is no rear sensing and a reverse manoeuvre would be blind; added state to verify.
4. Escalation to the CPU or a supervisor: report the stall to the host and stop, with no autonomous manoeuvre. Lowest risk, no liveness gain.
5. Policy-side mitigation (training with the filter in the loop). Not a safety-layer change, but it is out of scope for this decision.
6. Do nothing and report the stall rate as a known limitation.

## E. Unresolved safety questions
1. Is the 0.40 m margin (robot radius plus 0.15) the intended value for deployment? The firmware uses 25 cm; the relationship is not documented here.
2. The simulated rays cover only -90 to +90 degrees (confirmed in source), so the rear is unsensed. Is that true of the physical robot, and is reverse motion acceptable there?
3. Is a stall (safe stop) acceptable for the intended application, or must the robot guarantee progress or an escape?
4. Does the per-step cap (`safety_layer.py:92-94`) contribute to stalls? It has no reason code.
5. Is the rule allowing rotation while in the critical branch safe for a non-circular or real-world footprint? The simulation robot is a circle.
6. Python filter, firmware driver and any RTL filter parity at 0.40 m was not checked.

## F. Checks run for this addendum
Documentation consistency only: line references above were grepped against the source files in this checkout; no simulations were run. See the session report for the results of those checks.

## G. Addendum (see docs/35)
Code reading since this note: firmware margin is 25 cm (`safety_driver.h:16`) and `rtl/safety/safety_filter.v` has no distance input, so the Python/RTL parity question in E6 is moot: there is no RTL distance filter. Python vs firmware parity remains untested. Also the 8 rays are at -90, -60, -30, -10, +10, +30, +60, +90 degrees. Tracked as risks R1 to R3 in docs/35.
