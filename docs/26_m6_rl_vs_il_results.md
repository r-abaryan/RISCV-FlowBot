# M6: RL fine-tuning (ARS) vs IL baseline, results

Protocol: docs/24 (M6 thresholds). Code: sw/policy/m6_common.py, m6_rl_ars.py, m6_run_chunk.sh, m6_eval.py. Raw results: sw/policy/m6_results/*.json.
Status: local only, not pushed (owner instruction).

## Method
- RL = Augmented Random Search (pure NumPy), 30 iterations (8 directions, 6 episodes each, sigma 0.03), starting from the IL weights, 5 training seeds (1 to 5). Reward = environment return with the deterministic safety filter in the loop. Training episode seeds are drawn from 2000..6999.
- Evaluation: held-out env seeds 50000..50199 (200 episodes), safety filter on, every policy re-quantized to INT8 with the same calibration recipe, run through the bit-exact Python INT8 model.
- Calibration set is built from 100 steps of each policy's own float rollout (seed 1).

## Results (200 episodes each, 95 percent Wilson)
| Policy | Success | CI | Collision | Timeout | Filter intervention rate | Clearance p5 (m) |
|---|---|---|---|---|---|---|
| IL | 81.5 percent | 75.5 to 86.3 | 0.0 | 18.5 percent | 0.264 | 0.1308 |
| RL seed 1 | 94.0 | 89.8 to 96.5 | 0.0 | 6.0 | 0.137 | 0.1318 |
| RL seed 2 | 94.0 | 89.8 to 96.5 | 0.0 | 6.0 | 0.151 | 0.1338 |
| RL seed 3 | 97.5 | 94.3 to 98.9 | 0.0 | 2.5 | 0.214 | 0.1328 |
| RL seed 4 | 93.5 | 89.2 to 96.2 | 0.0 | 6.5 | 0.125 | 0.1317 |
| RL seed 5 | 93.5 | 89.2 to 96.2 | 0.0 | 6.5 | 0.171 | 0.1330 |

Pooled RL (1000 episodes): 94.5 percent, Wilson 92.9 to 95.8.

## Against docs/24 criteria
- Gain over IL: +13.0 points (needs 5): met. Pooled lower bound 92.9 percent above IL 81.5 percent: met.
- Seeds at or above IL: 5 of 5 (needs 4): met.
- Collision: 0.0 vs 0.0: no regression. Clearance p5: equal or slightly higher. Intervention rate: lower for every seed. Timeouts: lower. No safety regression criterion triggered.

By the stated protocol the RL candidate qualifies as a meaningful improvement.

## Caveats (do not skip)
- Only one IL training run exists, so IL seed variance is not measured; docs/24 said to revisit thresholds after seeing it.
- Evaluation is in the same simulator family, same distribution, as training (held-out seeds only, not held-out environment variations). No sim-to-real evidence.
- The filter is in the loop during training, so RL may be learning to exploit the filter. Collision is 0 for both, so the collision comparison is uninformative; a harder environment would be needed.
- Wilson interval on pooled seeds treats episodes as independent, though they share starting weights.
- 30 ARS iterations is small; no hyperparameter search. 5 seeds ran sequentially, ~1 min each.
- Not yet run through the RTL/cosim; the RL weights are not exported to firmware. This is the next step if the owner accepts RL.
- Eval times of ~1 to 2 minutes per policy in this sandbox.

## Next
Export the best-by-protocol (not best-on-test) policy, e.g. mean-of-seeds is not possible, so pick seed by training reward or retrain with a validation seed set; then run the RTL cosim regression. Awaiting owner direction.
