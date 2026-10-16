# M10a: timeout diagnosis (simulation only, no hardware claims)

Code: `sw/policy/m10a_diag.py`, `m10a_summ.py`. Raw data: `results/m10a/diag.json`. Table: `results/m10a/summary.md`.
Setup: policies il101 and rl1 (one training seed each), envs A/B/C, safety filter on (F) or off (N), max_steps 150 and 300.
Seeds 70000 to 70039 (n = 40 per cell). These are disjoint from the training seeds (2000 to 6999) and from the M9b evaluation seeds (60000 and up).
"slow frac" is the fraction of steps with realised v below 0.05 m/s. "disp_last" is the net displacement over the final 50 steps.
Both are computed over timeout episodes only.

## Observations (from the table)
1. With the filter on, nearly all failures are timeouts and there are zero collisions. With the filter off, the timeouts mostly turn into collisions
   (il101 B: timeout 0.500 to 0.000, collision 0.000 to 0.400; rl1 B: timeout 0.325 to 0.025, collision 0.000 to 0.300).
2. Filtered timeouts are standstills. The median net displacement over the last 50 steps is about 0.00 m in most cells, and the slow fraction is 0.5 to 0.9.
   Examples: il101 B F, rl1 B F, il101 A F. In C the median displacement is 0.03 to 0.21 m. That is small, but the noise there may be moving the robot slightly.
3. Doubling max_steps from 150 to 300 recovers little in A and B (il101 B: 0.500 to 0.500; rl1 B: 0.675 to 0.700). It recovers more in C
   (il101 C: 0.475 to 0.650, rl1 C: 0.650 to 0.750), so some C timeouts are slow progress and not deadlock.
4. The filter intervention rate is higher in B and C (0.26 to 0.47 of steps) than in A (0.10 to 0.30).

## Interpretation
- **Supported by the data:** most timeouts with the filter on are not "ran out of time". They are the robot stopped or nearly stopped,
  at a median of about 0.55 to 0.95 of the start distance from the goal. The filter converts what would be collisions into stalls.
- **Not verified:** the exact mechanism. I did not log the filter's reason code per step, so I have not shown whether the stall comes from the
  brake/margin rule holding v at 0 near obstacles (d_margin = robot radius + 0.15 m) while the policy keeps pushing into the obstacle.
  That is the likely cause, but it is a hypothesis.
- Both policy types show it. The RL policy has fewer stalls than IL, but the effect is not specific to either training method.

## Decision recommendation (for owner)
- **Do not retrain RL (M10b) yet.** Retraining the policy does not address a filter/policy deadlock, and the reward terms were not shown to be the cause.
  I did not compare reward terms, as the plan said. The stall evidence makes that comparison lower priority.
- Next cheap step (M10a-2): log the filter reason per step on stalled episodes and confirm the mechanism.
  Then decide between (a) documenting it as a known conservative-safety limitation, (b) adding a deterministic recovery behaviour
  (for example rotate in place when stalled, with the rule still bounded by the same safety limits) to the filter.
  Option (b) changes the safety layer, so it needs your decision and its own verification (RTL/firmware parity would also be affected).
- Caveats: n = 40 per cell, one training seed per method, no confidence intervals computed here. Differences of 0.05 to 0.10 between cells are within noise.
