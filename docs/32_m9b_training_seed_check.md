# M9b follow-up: ARS training-seed check (simulation only, descriptive)

Source: results/m9b/summary.md (n=400 per cell, same eval seeds 60000..60399). No new runs were made.

## Held-out seed disjointness (code inspection)
sw/policy/m6_rl_ars.py draws training episode seeds as 2000 + randint(0,5000), so the range is 2000..6999. Evaluation seeds are 60000..60399. The ranges are disjoint. This closes the limit stated in docs/31 for the ARS training code.

## Spread across the 5 ARS training seeds (success rate)
| env | RL seeds 1..5 (min to max) | IL seeds 101..105 (min to max) |
|---|---|---|
| A | 0.935 to 0.953 | 0.750 to 0.880 |
| B | 0.507 to 0.635 | 0.450 to 0.520 |
| C | 0.500 to 0.593 | 0.475 to 0.537 |

## Reading
- Env A: every RL seed is above every IL seed. The RL advantage does not depend on one training seed.
- Env B and C: the ranges overlap (RL seed 5 is about at IL level; RL seed 4 on B is 0.552, on C 0.535). The advantage there is seed dependent and smaller. RL seed 1 was the one used in the pre-set rule, and it is among the better seeds on B and C. Reporting only it would overstate the effect on B and C.
- No paired tests were run for RL seeds 2..5 (not in the pre-registered rule); this table is descriptive only.
- Not done: more ARS iterations or more training seeds, so the training-seed sample is still only 5.
