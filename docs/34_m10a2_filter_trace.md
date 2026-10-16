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
