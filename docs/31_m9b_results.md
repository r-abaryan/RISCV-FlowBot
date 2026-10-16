# M9b full-study results (simulation only, no hardware claims)

Protocol: docs/30_m9b_protocol.md, unchanged. Runner `sw/policy/m9b_study.py`, statistics `sw/policy/m9b_stats.py` (tested by `test_m9b_stats.py`, 10 checks pass). Tables: `results/m9b/summary.md` and `.json`. Per-unit raw episodes: `results/m9b/study/` (264 files, 50 episodes each, with weights and code SHA-256). Hashes: `results/m9b/*.sha256`. Runtime ledger: `results/m9b/ledger.jsonl`.

## Checks before the study
- RNG: `RobotEnv.reset(seed)` calls `np.random.seed(seed)`, which resets the global state at every episode start. Each episode is therefore independent of prior execution, provided that every random draw comes after the reset. The equivalence test below confirms this empirically.
- Equivalence on pilot seeds only (90000..): RL seed 1, env A, 200 episodes, continuous vs 4 ordered 50-chunks vs shuffled 50-chunks: all per-episode records (outcome, reward, path length, and all other fields) are identical. 187 successes, matching the recorded pilot. Same on env C (100 episodes): identical, 55 successes.
- Paired-statistics tests: Wilson, exact McNemar, paired bootstrap have unit tests against hand-computed values.
- ROM check with REQUIRE_ELF=1: 4 passed, 0 skipped, exit 0 (earlier session, ELF available). Latest check without ELF/toolchain: 2 passed, 2 SKIPPED (ELF cross-checks not run). Skips are not passes; see docs/35 section 6.
- Env B timing: IL seed 101, 50 episodes, 23.4 s (0.47 s per episode).
- Held-out seeds untouched: a search of tracked files finds 60000..60399 only in the protocol document. (The match 60184 in sim/test_vectors_trained.json is a data value, not a seed.) Training and eval code use seeds 0..49, 100..259, 1, 50000.., and 90000... Limit: I did not inspect the seeds used inside the ARS training of the frozen RL states beyond this text search.
- IL seeds 102..105 were trained with the unchanged recipe (about 34 s each). Seed 101 was already present.

## Run
- 264 units (11 policies, 3 environments, 8 chunks of 50), 13,200 episodes. Coverage check: every (policy, env) has exactly seeds 60000..60399, no duplicates, no missing.
- Cumulative runtime in the ledger, including equivalence, training and timing: about 6,700 s (111 min) of the 200 min cap. One CPU sandbox, sequential. No retries and no protocol changes.

## Results (see summary.md for all numbers with intervals)
- Collisions are 0 across all policies and environments in this simulator only (circular robot, ideal rays, Python filter at 0.40 m). All failures are timeouts, and many timeouts are safe stalls (docs/33, docs/34), which are a conservative fallback and not successful navigation. These zeros do not transfer to firmware or hardware (risks R1 to R7, docs/35).
- IL seeds 101..105 success: A 0.750 to 0.880 (mean 0.811), B 0.450 to 0.520 (mean 0.486), C 0.475 to 0.537 (mean 0.508).
- RL seed 1 minus IL, paired success difference, 95% bootstrap interval excludes zero in favour of RL in all three environments for il101, il103, il104 and il_base. For il102 and il105 it includes zero on env C (+0.040 [-0.003,+0.083]; +0.037 [-0.005,+0.080]).
- By the pre-set rule, a superiority claim is therefore met against IL seeds 101, 103, 104 and the base, and not met against 102 and 105. Since the rule is per IL seed and not met for all, the study does not support a blanket "RL beats IL" claim. This is unadjusted for multiple comparisons.
- Caveat: timeouts of about 50 percent on B and C for all policies may reflect harsh environment settings (the policies were not designed for them). I did not investigate that.
- Follow-up: see docs/32 (ARS training-seed spread, seed disjointness, manifest now per-file via scripts/verify_m9b_manifest.sh).
- RL seeds 2..5 are reference only and are not part of the rule.

## Verification of the numbers above
All figures in the Results section were compared against `results/m9b/summary.md` after writing. Also: the paired path-length difference on episodes where both succeed is positive for every comparison (RL paths are longer than IL paths, +0.13 to +0.38 in the units of the environment). RL's advantage is in success rate only, not path efficiency.
