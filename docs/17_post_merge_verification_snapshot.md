# Post-merge verification: SNAPSHOT (historical; see docs/21 for final state)

Branch: flowbot/post-merge-verification-fixes. Status per owner finding:

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | verify_independent_vectors.py imported quantize_layer | DONE | Standalone integer oracle, no reference_model import; both layers checked; run prints "All 25 vectors ... 0 LSB error" |
| 2 | ASSERT 4 without check | DONE | tb_soc_nav.v now calls $fatal(1,...) when v!=0x1A or w!=0x27; make -C sim test_nav passes |
| 3 | quantization_analysis.json sample count mismatch | UNVERIFIED / UNRESOLVED (JSON says 3986 samples, docs say 2000; no replacement measurement made) | Needs canonical benchmark run and regenerated reports |
| 4 | 20 vs 10 step mismatch | UNVERIFIED / UNRESOLVED (doc 16 shows 20-step trace, Makefile runs 10; the doc 16 trajectory is invalid anyway per row 5) | Makefile runs --steps 10; seeds and commands not yet documented |
| 5 | Motion with v_cmd = 0 | DONE (re-run 2026-10-13) | robot_env.step maps action[0] by target_v = 0.5*(a+1)*v_max, so a=0 gives 0.4 m/s. The harness passed v_cmd/127, so zero meant half speed. Now mapped to 2*v/127 - 1. Previous Phase 4 trajectories and the claim that the filter stopped the robot are invalid. Re-run: `make -C sim test_cosim` (10 steps, 1 episode) gives status PASS, max discrepancy 0 LSB, 8 safety trips, mean 3304.8 cycles (66.1 us @ 50 MHz); results in sim/cosim_results.json, log in logs/test_cosim.log. Steering normalization (w/127 to w_max 1.5) still unverified. |
| 6 | Multi-seed full episodes | NOT DONE | Co-sim costs about 5 s per step in iverilog (1 vCPU), so full 150-step episodes across seeds take a long time. Plan: bit-exact check on a few seeds in RTL, plus a fast Python model of the firmware safety rule for many seeds. |
| 7 | Absolute /workspace defaults | DONE in soc_closed_loop_cosim.py | Defaults are now relative to the script file |
| 8 | FPGA readiness wording | NOT DONE | Only RTL simulation and Yosys synthesis elaboration exist. No timing closure, no hardware run, no physical safety validation. |

Superseded: tool versions and logs now exist (logs/, docs/18, docs/19, docs/21). Yosys was installed later via tools/setup_yosys_alpine.sh; per-module synthesis only, whole-SoC synthesis not completed.

> **Update 2026-10-14:** the 3986 vs 2000 sample question is RESOLVED: 3986 is correct (docs/27). Statements here that call it unresolved are superseded.
