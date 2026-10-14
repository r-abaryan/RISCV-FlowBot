# 19. Synthesis handoff and status (2026-10-13, paused)

Read `docs/20_runbook_for_future_sessions.md` first. This file records what is known, what is not, and where to resume.

## 1. Tool provenance
- Yosys: `0.68+post`, git `c12172fbae8af5e20f6fb52e3d4e92d56ed587b6` (an upstream merge commit dated 2026-08-05, 8 commits ahead of tag v0.68). Matches the Alpine edge/testing package `yosys-0.68-r0`.
- **Provenance of the earlier `/opt/y` directory: NOT ESTABLISHED.** It no longer exists in the sandbox and was never documented. I cannot say who or what populated it.
- Replacement: `tools/setup_yosys_alpine.sh` installs `yosys-0.68-r0` from Alpine edge/testing into a private root `/opt/yroot` (`. /opt/yroot/env.sh`). Package versions are in `tools/yosys_installed_packages.txt`. Evidence that it is equivalent: re-running `safety_filter` through it gave a stat block identical to the saved `logs/synth_per_module/safety_filter.stat.txt`. Only that one module was compared; this is a single data point, not proof for all modules.
- Pin weakness: Alpine edge is rolling and removes old packages. The apk sha256 is recorded in the script but I did not verify it against a downloaded file in this session. `ci/Dockerfile.yosys` is **untested** (no container runtime here). No GitHub Actions workflow was added (not authorized).

## 2. `scripts/synth_staged.sh` exit codes
Usage: `RUN_TAG=<tag> scripts/synth_staged.sh <top> "<extra yosys cmds>" <verilog files...>`. Work dir `build/syn/<tag>/` with `status`, `logN.txt`, `stdoutN.txt`, `sN.il` checkpoints and `doneN` markers.
| Exit | Status line | Meaning |
|---|---|---|
| 0 | `COMPLETED` | All 7 stages done. `stat.txt` is valid. |
| 2 | `INCOMPLETE stage=N (timed out ...)` | Stage hit the time limit. Checkpoints kept. Re-run the same command to resume. Not a failure. |
| 1 | `FAILED stage=N rc=R` | Yosys returned an error. Logs and earlier checkpoints are kept. Needs a fix, not a re-run. |
Tested on 2026-10-13: bad top name gave 1, 3 s stage limit gave 2, `soc_rom` gave 0, a bogus yosys command gave 1. Env vars: `RUN_TAG`, `BUDGET`, `STAGE_TIMEOUT`.

## 3. Per-module results (separate runs, `synth_ecp5 -noabc9`, no P&R)
Raw: `logs/synth_per_module/*.stat.txt`. LUT4: nna_top 5393, picorv32_wb 1294, safety_filter 179, soc_interconnect 372, soc_pwm 67, soc_ram 7 (32 DP16KD), soc_rom 2, soc_timer 318, soc_uart 16. **Sum 7,648 LUT4, 8 MULT18X18D, 32 DP16KD.** This is the sum of separate runs, **not** an integrated utilization.
Caveats:
1. `picorv32_wb` in that sum uses the **default** `picorv32.v` parameters. `soc_top.v` sets ENABLE_MUL, ENABLE_FAST_MUL, ENABLE_DIV, IRQ, barrel shifter (see `u_cpu`). With those parameters (`scripts/synth_cpu_soc_params.sh`, `logs/synth_per_module_v2/picorv32_wb_soc_params*`): 2,727 LUT4, 4 MULT18X18D, 2 DP16KD, 1,180 FF. Substituting gives about 9,081 LUT4 and 12 MULT18X18D. The 4 CPU multipliers are therefore missing from the "8" figure. I did not recompute the other fields.
2. `soc_rom` shows 2 LUT4 because no INIT_FILE is given, so contents are not in the netlist. Real ROM mapping is unmeasured.
3. `soc_ram` mapped to 32 DP16KD (this is 64 KB: 16384 words). The picorv32 regfile went to distributed RAM or DP16KD depending on parameters. Not yet analysed.

## 4. `nna_top` statistics include children (item 4)
Hierarchy: `nna_top` -> `nna_regs` (registers and scratchpads) and `nna_core` -> `nna_mac4`. Top-level parameters: `nna_top` and its children have **no Verilog parameters** (grep of `rtl/` found parameters only in `soc_ram` MEM_SIZE_WORDS=16384 and `soc_rom` MEM_SIZE_WORDS=2048, INIT_FILE="").
- `logs/synth_per_module_v2/nna_top.stat.txt` (flattened): 5,393 LUT4, 8 MULT18X18D. The yosys log (build/syn/nna_top/log2.txt, excerpt in `logs/synth_per_module_v2/nna_top_flatten_evidence.txt`) shows the FLATTEN pass executing and cells named `$flatten\u_core.*`, so children are included.
- `logs/synth_per_module_v2/nna_top_noflatten.stat_hier.txt`: hierarchy total 5,843 LUT4, 8 MULT18X18D (nna_regs 4,793, nna_core 796 + nna_mac4 244, nna_top 10). Children are included in the "design hierarchy" totals.
- The flat and unflattened totals differ by 450 LUT4 (cross-boundary optimization). The cause was not investigated further. Which is closer to a final SoC result is unknown.
- 8 MULT18X18D: 4 in `nna_core` itself and 4 in `nna_mac4`. Whether 8 is intended (design intent was 4 SIMD MACs) is an **open question**.

## 5. Separate optimization task (do NOT do as part of documentation): BRAM inference
`nna_regs` is about 82% of `nna_top`'s LUTs (4,793 of 5,843) and maps 352 TRELLIS_DPR16X4 (distributed RAM) with zero DP16KD, i.e. the scratchpads are not inferred as block RAM, and read logic is large. Task: restructure buffers for BRAM inference. Preconditions before touching RTL: (a) full regression green (`make -C sim ...`, `test_quant`, cosim 0 LSB), (b) memory read-latency analysis (BRAM reads are synchronous, which shifts the nna_core FSM timing and the 58-cycle latency), (c) re-run synthesis and compare. Not started.

## 6. Integrated `soc_top` synthesis
Not completed. Flat run (`RUN_TAG=soc_top`) and `-noflatten` run (`RUN_TAG=soc_top_noflatten`) both ended `INCOMPLETE stage=5` (stage 5 = `map_luts`/ABC) after about 108-112 s (`logs/synth_soc_top_flat_incomplete/`). Stages 1-4 are checkpointed in `build/syn/soc_top*/` (not committed; `build/` is git-ignored and the sandbox may not keep it).
**Important:** checkpoints exist only BETWEEN stages. Re-running restarts stage 5 from zero with the same ~110 s allowance, so repeating the command in a 120 s-call sandbox will probably never finish. It is not known how long stage 5 needs. Practical options: (a) a machine without a call limit: `BUDGET=3600 RUN_TAG=soc_top scripts/synth_staged.sh ...`; (b) split stage 5 further (e.g. synthesize with `-noflatten`, or `abc` per module); (c) run the 2-3 largest modules unflattened and add results. Background jobs are killed at call end, so detached runs do not work here. A completed run would give counts only, not timing.

## 7. Unverified / open
- Provenance of `/opt/y`. 
- Any whole-SoC LUT, FF, DSP, BRAM count; Fmax; timing; power; nextpnr results. No P&R has ever been run.
- Equivalence of the Alpine package with the original `/opt/y` binary beyond one module.
- Whether the apk sha256 pin still matches; the Dockerfile builds at all.
- Why `nna_core` uses 4 multipliers in addition to `nna_mac4`'s 4.
- Old docs 11 values (e.g. per-module 1,314 / 88 / 1,002) are unreproduced and unexplained; now flagged superseded.
- Carried over (not changed this session): post-merge findings in `docs/17`; quantization JSON says 3,986 samples versus 2,000 in docs; Phase 5 paused; no PR opened.

## 8. Next step when resumed
1. `sh tools/setup_yosys_alpine.sh` (if `/opt/yroot` missing), `. /opt/yroot/env.sh`.
2. Resume the flat `soc_top` run until exit 0 (section 6), save `stat.txt` to `logs/`.
3. Await the owner's decision on: BRAM optimization task, opening a PR for this branch.

Note: the full stage logs (log1-log5, about 6,800 lines) were left out of the git history to keep the push reviewable. Only `log5_tail.txt` (last 30 lines of the partial stage-5 log) is kept in `logs/synth_soc_top_flat_incomplete/`. Re-running `scripts/synth_staged.sh` regenerates them.

> **Update 2026-10-14:** the 3986 vs 2000 sample question is RESOLVED: 3986 is correct (docs/27). Statements here that call it unresolved are superseded.
