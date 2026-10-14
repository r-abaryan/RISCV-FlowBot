# M6 follow-up: firmware export and harder environment

## Export (step 2)
- Seed chosen: RL seed 1, picked on the validation seed set (sw/policy/m6_val/, m6_select.py), not on test score.
- Exported by sw/policy/m6_export.py into nav_weights*.inc/.h; firmware hex rebuilt. The cosim reference now loads rl_seed1_policy.json.
- tb_soc_nav.v golden values were hardcoded for the IL weights. I recomputed them with the Python integer reference model (sw/model/reference_model.py) and confirmed the RTL matches: raw outputs (0x17,0x07), (0xE8,0x7F), (0x17,0x41). Cycle 3 PWM reflects the safety clamp.
- Regression (HISTORICAL, previous session, partial): test_nna, test_safety, test_nna_corners_sim, test_safety_adv, test_soc, test_nav were run; a 10-step test_cosim ran to completion. The earlier text here claiming test_py, test_quant, test_rtl passed was NOT backed by a run in that session. See the evidence table below for what was run in the reconciliation session.
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


## Reconciliation pass (this session): what was actually run
Environment: Alpine, iverilog 12.0, python3, gcc. Logs and exit codes are in logs/evidence/ (m6_*.log, m6_*.exit). The Python-side tests and RTL tests were run after the changes below; they are session results, not historical.

| Command | Exit | Evidence |
|---|---|---|
| make -C sim test_nav | 0 | logs/evidence/m6_test_nav.log |
| make -C sim test_cosim (10 steps, seed 42) | 0 | logs/evidence/m6_test_cosim.log |
| make -C sim test_py | 0 | logs/evidence/m6_test_py.log |
| make -C sim test_quant | 0 | logs/evidence/m6_test_quant.log |
| make -C sim test_rtl | 0 | logs/evidence/m6_test_rtl.log |

Not rerun this session: test_trained_nna, test_nna_corners (it does not use the RL export), the hard-environment evaluation, RL training.

### Changes
- **Export verification:** sw/test/test_rl_export.py parses the weights actually in sw/firmware/nav_weights.inc (its own parser, not export_weights.py), compares them to rl_seed1_policy.json and to 500 random outputs of the independent integer reference model. It also runs negative controls: a flipped weight bit, a +1 bias and a +1 scale each must be detected. All 3 were detected. It is wired into test_py. Limit: it checks the .inc, and I only checked that the 46 .word values of the .inc all appear in robot_nav.hex. It does not prove the hex layout.
- **tb_soc_nav.v:** stale IL messages updated to the RL seed 1 goldens. The cycle-3 assertion is stronger: the PWM must differ from the unclamped value and L+R must be within 998..1000 (v_safe=0). The earlier check allowed any value. test_nav passes.
- **Co-sim report:** the harness now prints "INTEGRATION PASS" (bit-exact vs reference, 0 LSB) separately from a per-episode navigation outcome. The 10-step run ended at the harness step limit (Success=False, Collision=False). That is NOT a navigation success and not evidence of one. 10 steps with one episode says nothing about navigation.
- **Hard-environment results and limits are unchanged.** No retraining was done and no held-out seeds were used for selection. RL is not shown to generalize.
