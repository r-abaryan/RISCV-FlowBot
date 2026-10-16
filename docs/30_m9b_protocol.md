# M9b protocol: RL seed 1 vs IL across IL seeds and harder environments (simulation only)

Status: protocol FIXED before any M9b execution (written 2026-10-16, before the pilot). Simulation only. No hardware, FPGA or bitstream claim.
Owner approval: pilot and environments B and C approved; the full experiment needs a separate approval.

## Policies
- RL seed 1: frozen ARS state `sw/policy/m6_state/ars_seed1.npz`. No retraining, no reselection.
- RL seeds 2 to 5: included as a robustness reference only because they are already trained and frozen (`ars_seed2..5.npz`). Not retrained, not reselected.
- IL base: the existing `trained_policy_weights.json` (reference).
- IL seeds 101 to 105: `train_policy.py --seed N`, unchanged recipe and hyperparameters (50 initial episodes, 2 DAgger rounds of 30, same epochs and learning rate). Seed N sets the network init and, via `reseed=True`, the minibatch order of each optimisation stage. Episode-collection seeds in the recipe are the recipe's own and were not changed. `train_policy()` with default arguments is unchanged in behaviour (checked below).
- All policies go through the same INT8 requantisation (m6 recipe, calibration from 100 steps of the policy's own float rollout in the unmodified environment A, episode seed 1) and the bit-exact Python INT8 model, with the deterministic safety filter ON.

## Environments (`sim/robot_env_m9b.py`)
- A: the original RobotEnv2D (4 pillars). Checked identical to the parent for 2 seeds x 30 steps.
- B: 1.5x obstacles: 6 pillars. The original 4 plus two extra, radius 0.5 m, at (0, +2.4) and (0, -2.4). Fixed layout. Start and goal use the parent's rejection rule (robot clearance +0.2 m, goal clearance +0.15 m, start to goal at least 3.0 m, 50 tries).
- C: B plus range-sensor noise (Gaussian, sigma 0.05 m, clipped to 0..d_max, no dropout) and per-episode actuator gain, v gain and w gain each U(0.9, 1.1), independent, applied to the realised plant motion. The commanded state and odometry stay nominal. The safety filter sees noisy ranges and does not know the gain.
- Noise and gain use a private RandomState(seed + 1,000,000), so the start and goal draws do not change with the variant.
- Known limit: the 1.5x obstacle count is rounded to 6 and the added pillars are placed by hand, not sampled. The 50-try fallback of the parent can in principle accept an invalid start or goal. This was not measured.

## Episodes and seeds
- max_steps 150. Outcome per episode is exactly one of success, collision, timeout (neither).
- Pilot seeds 90000 to 90199. Used only for timing and a harness check. Not used in any conclusion and not used to choose anything.
- Full-study held-out seeds 60000 to 60399 (400 episodes), identical for every policy and every environment. These are disjoint from every seed range used by training, validation, selection and earlier tests (2000..6999, 10000.., 20000.., 50000..50199). Nothing is tuned on them.

## Metrics and statistics
- Per policy, per environment and per IL seed: success, collision and timeout rates with Wilson 95% intervals. Mean path length (metres, successful episodes only, and all episodes reported separately).
- RL seed 1 vs each IL seed (101..105 and base): paired on common episode seeds. Report the 2x2 discordant counts, the paired difference in success rate with a paired bootstrap 95% interval (10,000 resamples, fixed RNG seed 0) and an exact McNemar p-value. The same for collision. Path length difference is paired on episodes where both succeed.
- No multiple-comparison correction is applied. Results are reported as unadjusted and descriptive. 6 comparisons x 3 environments x 2 outcomes are made, so a few nominal hits are expected by chance.
- IL variance across seeds is reported as min, max and mean of the per-seed rates. RL seeds 2 to 5 are shown in a separate table and are not pooled with RL seed 1.
- A success criterion is not set in advance. The study reports the measured differences. No claim of superiority will be made unless the paired interval excludes zero in the same direction in all three environments. This rule is set now and was not derived from data.

## Pilot (bounded)
1. Train IL seed 101 once; measure wall time.
2. Evaluate RL seed 1 for 200 episodes on A, and on C (the slowest variant), to measure per-episode time; A is also a harness check against the recorded m6 behaviour (m6 used seeds 50000..50199 so that check is run separately on those seeds).
3. Project the total cost. Stop. Do not continue without approval.

## Pilot results (2026-10-16, single process, this sandbox; wall time measured, not estimated)
- IL seed 101 training: 35.8 s wall (29.2 s reported by the trainer). Default `train_policy()` reproduces the committed `raw_float` weights exactly (checked), so the code change does not alter the old IL policy.
- RL seed 1, env A, pilot seeds 90000..90199: 66.8 s (0.334 s/episode). Result 187 success, 0 collisions, 13 timeouts.
- Harness check: RL seed 1, env A, seeds 50000..50199 gave 188 success, 0 collisions, 12 timeouts, which equals the recorded m6 result (0.94, 0.0, 0.06).
- RL seed 1, env C: 97.0 s (0.485 s/episode). 112 success, 0 collisions, 88 timeouts. IL seed 101, env C: 101.3 s (0.507 s/episode). 98 success, 0 collisions, 102 timeouts.
- Env B was not timed. These pilot outcomes are not used for any conclusion.
- Projection for the full study (assumption: B costs about the same as C, 0.49 s/episode; per-episode time is only measured on RL1 and IL101): 11 policies (RL1..5, IL base, IL101..105) x 3 environments x 400 episodes = 13,200 episodes, about (0.334 + 0.49 + 0.49) x 400 x 11 = about 5,800 s, roughly 97 minutes on one process, plus about 3 minutes to train IL seeds 102..105. Parallel runs were not measured.
