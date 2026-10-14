# M6 follow-up: firmware export and harder environment

## Export (step 2)
- Seed chosen: RL seed 1, picked on the validation seed set (sw/policy/m6_val/, m6_select.py), not on test score.
- Exported by sw/policy/m6_export.py into nav_weights*.inc/.h; firmware hex rebuilt. The cosim reference now loads rl_seed1_policy.json.
- tb_soc_nav.v golden values were hardcoded for the IL weights. I recomputed them with the Python integer reference model (sw/model/reference_model.py) and confirmed the RTL matches: raw outputs (0x17,0x07), (0xE8,0x7F), (0x17,0x41). Cycle 3 PWM reflects the safety clamp.
- Regression run: test_py, test_nna_corners, test_quant, test_rtl, test_trained_nna, test_nna, test_safety, test_nna_corners_sim, test_safety_adv, test_soc, test_nav all exit 0. test_cosim ran 10 steps with the safety filter tripping once; I did not check it for an explicit pass/fail line, only that it ran to completion.
- Caveat: test_trained_nna uses its own vectors and weights, not the RL export.

## Harder env (step 3): sim/robot_env_hard.py
8 pillars (originals enlarged to 0.6 m, 4 extra), range noise 0.05 m, 3 percent ray dropout, goal at least 4 m away. Same 16-D observation and 2-D action.
Results (seeds 20000-20024 only, N=25, INT8 model; small sample, high variance):

| policy | safety filter | success | collision | timeout |
|---|---|---|---|---|
| IL | off | 7 | 16 | 2 |
| IL | on | 2 | 0 | 23 |
| RL seed 1 | off | 5 | 20 | 0 |
| RL seed 1 | on | 2 | 0 | 23 |

(Counts out of 25.) IL nofilter on seeds 20025-20049 gave 10/14/1. Collisions now appear without the filter; with it the filter prevents collisions but most episodes time out. The hard env is not solvable by either policy, and neither was trained on it. Not run: larger N, retraining on the hard env, confidence intervals. Run: N=25 S0=20000 python3 sw/policy/m6_hard_eval.py {il|1} {filter|nofilter}.
