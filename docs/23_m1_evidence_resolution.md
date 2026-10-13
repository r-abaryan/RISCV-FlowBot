# M1 evidence resolution (2026-10-13)

## 1. Sample count: 3,986 vs 2,000
Checked: re-ran `make test_quant` (sw/test/verify_quantization.py, n_episodes=50, base_seed=1000). It prints "3986 authentic samples" and rewrites quantization_analysis.json with num_samples 3986, reproducibly. The script appends one observation per env step across 50 episodes, with no 2,000 cap.
Conclusion: 3,986 is the reproduced value. No script in the repo produces 2,000. Docs citing 2,000 samples are stale. The "544 steps" in doc 13 comes from a different evaluation (test_policy_eval) and is not the same dataset.
Not checked: why the earlier docs said 2,000 (history not recoverable). The 28.43 dB SNR in the JSON was not re-compared in this session beyond the rerun.

## 2. Multiplier intent: 4+4 MULT18X18D in nna
Checked in source: `nna_mac4.v` has four 8x8 products (a*b) = 4 multipliers (the SIMD MAC). `nna_core.v` line ~110 has a separate 32-bit x 17-bit requantization multiply (acc * scale_mult), which Yosys maps to additional MULT18X18D blocks (4 reported in docs 19). So 8 = 4 (MAC) + 4 (requant), not a duplicated MAC. Whether the requant multiply should be a 4-DSP wide multiply or be narrowed/serialized is a design choice, not decided. The requant multiply is by design, not a bug.
Not checked: the exact DSP mapping split per cell (relied on docs 19 numbers).

## Next
Fix stale 2,000 mentions in later edits; M2 onward per doc 22.
