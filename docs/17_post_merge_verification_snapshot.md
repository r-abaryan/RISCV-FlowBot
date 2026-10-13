# Post-merge verification: SNAPSHOT (incomplete)

Branch: flowbot/post-merge-verification-fixes. Status per owner finding:

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | verify_independent_vectors.py imported quantize_layer | DONE | Standalone integer oracle, no reference_model import; both layers checked; run prints "All 25 vectors ... 0 LSB error" |
| 2 | ASSERT 4 without check | DONE | tb_soc_nav.v now calls $fatal(1,...) when v!=0x1A or w!=0x27; make -C sim test_nav passes |
| 3 | quantization_analysis.json sample count mismatch | NOT DONE | Needs canonical benchmark run and regenerated reports |
| 4 | 20 vs 10 step mismatch | NOT DONE | Makefile runs --steps 10; seeds and commands not yet documented |
| 5 | Motion with v_cmd = 0 | ROOT CAUSE FOUND, fix applied in harness, not yet re-run | robot_env.step maps action[0] by target_v = 0.5*(a+1)*v_max, so a=0 gives 0.4 m/s. The harness passed v_cmd/127, so zero meant half speed. Now mapped to 2*v/127 - 1. Previous Phase 4 trajectories and the claim that the filter stopped the robot are invalid. Steering normalization (w/127 to w_max 1.5) looks consistent but is unverified. |
| 6 | Multi-seed full episodes | NOT DONE | Co-sim costs about 5 s per step in iverilog (1 vCPU), so full 150-step episodes across seeds take a long time. Plan: bit-exact check on a few seeds in RTL, plus a fast Python model of the firmware safety rule for many seeds. |
| 7 | Absolute /workspace defaults | DONE in soc_closed_loop_cosim.py | Defaults are now relative to the script file |
| 8 | FPGA readiness wording | NOT DONE | Only RTL simulation and Yosys synthesis elaboration exist. No timing closure, no hardware run, no physical safety validation. |

Tool versions, logs and machine-readable results are not yet produced.
Yosys is not installed in this environment now, so synthesis numbers could not be re-run.
