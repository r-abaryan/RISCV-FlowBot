# PR 9 review cleanup and final evidence (2026-10-13)

Scope: partial verification and synthesis-evidence correction. NOT a declaration of project or FPGA readiness.

## Review items
1. Docs 12 and 17 corrected: stale 10/10 and PASS claims marked historical; "tools unavailable" statements replaced.
2. UNVERIFIED and unresolved, no replacement measurements made: 2,000 (docs) vs 3,986 (quantization_analysis.json) samples; 20-step (doc 16) vs 10-step (Makefile) trace. Doc 16 trajectories predate the v=0 mapping fix and are invalid.
3. tools/setup_yosys_alpine.sh: PIN_SHA256 is NOT enforced (documentation only; apk checks package signatures). The script creates a symlink /usr/bin/abc outside the private root (host modification; remove with rm /usr/bin/abc). Not changed to enforce, to avoid untested logic.
4. Co-sim PASS means bit-exact RTL vs Python integration check only, not robot navigation. Still to verify: steering normalization, negative velocity handling.

## Regressions run this session (logs/final_*.log, exit status 0 each)
test_py, test_nna_corners, test_quant, test_nna, test_safety, test_nna_corners_sim, test_safety_adv, test_trained_nna, test_nav, test_soc.
Tools: iverilog 12.0 and numpy 2.3.5 (Alpine apk). "Exit 0" only; I did not independently audit each testbench's assertions here.

## Not run
test_cosim (about 5 s/step, exceeds call limit), synth_check / Yosys (not installed in this session), whole-SoC synthesis, multi-seed full episodes, BRAM optimization (separate follow-ups).

> **Update 2026-10-14:** the 3986 vs 2000 sample question is RESOLVED: 3986 is correct (docs/27). Statements here that call it unresolved are superseded.
