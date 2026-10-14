# 27. M8A: evidence reconciliation (2026-10-14)

## 1. Sample count: 3986 vs 2000 (RESOLVED, decisive)

| Source | Claimed count | Verdict |
|---|---|---|
| `sw/policy/quantization_analysis.json` | 3986 | Matches the code |
| `logs/final_test_quant.log` | 3986 | Matches |
| docs/13, docs/14 (before this fix) | 544 | Not reproduced |
| docs/15 sec 1.1, docs/17, docs/21 | 2,000 / 2,229 / 544 mentioned | Not reproduced |

Method: `verify_quantization.py` runs 50 episodes (seeds 1000..1049) and appends one observation per env step until `done` or `max_steps=150`. It has no subsampling. I re-ran that loop independently on 2026-10-14 with the committed weights: 3986 steps (mean 79.72, min 6, max 150, 2 episodes hit the limit). The 25 RTL test vectors (`sim/test_vectors_trained.json`) are every 166th sample index (0..3985), which is consistent with a 3986-sample pool.
No code path produces 544, 2,000 or 2,229. The earlier docs 13/14/15 text was wrong.

Related metric corrections (docs/14 sec 3.1, docs/16): SNR is 33.54 dB (v) and 29.04 dB (w) per the JSON. The old values 28.4 dB, 15.65/14.15 dB and MAE 0.0210 are not reproduced. Cosine similarity is not stored in the JSON; recomputed: 0.9995 pooled, 0.9984 mean per-sample. The old 0.9997 is unsupported.
Unchanged: the 78.0% success / 18.0% INT8 collision figures were re-run (`sw/test/test_policy_eval.py`) and reproduce.
Docs 15 sec 1.1/1.2 carry a superseded banner; their text is kept as history.

## 2. Synthesis claims: classification

| Claim | Class | Status |
|---|---|---|
| 2,686 LUT4, 2,130 FF, 4 DSP, 38 MHz Fmax (docs 11/12, README, CHECKPOINT, commit dffa1c2) | Historical, no log, no script | UNSUPPORTED. Already bannered; this session confirms nothing in the repo reproduces it. |
| Per-module tables in doc 11 | Historical | UNSUPPORTED (one row is for a module that does not exist in the RTL). |
| 7,648 LUT4 / 8 MULT18X18D sum (docs/18), about 9,081 LUT4 with SoC CPU parameters | Per-module estimate (separate Yosys 0.68+post runs, `-noabc9`) | Measured per module; NOT an integrated result. |
| Flat `soc_top` utilization | Integrated | NOT YET MEASURED (M8B). |
| Fmax, timing, power, board validation | none | NO EVIDENCE exists. |

Caveat on `/opt/y` / Yosys provenance: docs/23 pins Yosys 0.68+post c12172fb. M8B records the exact build used.
