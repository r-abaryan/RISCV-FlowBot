# 20. Runbook for future sessions: tools, and how not to mis-report them

Purpose: stop repeating "X cannot be installed / run" claims that were never properly tested, and stop claiming results that were not measured. Every sandbox may be fresh. State is only what is in /workspace and the repo.

## Rules
1. **Probe before concluding.** Run `command -v yosys iverilog make python3 riscv32-unknown-elf-gcc docker`. A tool missing in one session means "not installed now", not "impossible". Write "not available in this session (tried: ...)" only with the commands and errors that you ran.
2. **Never reuse a number without a log.** A figure is "measured" only if the raw tool output is in the repo (`logs/`) and the command is documented. Otherwise write "unverified".
3. **Say what the number is.** Sum of separate module runs is not integrated SoC utilization. Elaboration is not synthesis. Synthesis counts are not timing (no place and route has been run).
4. **Check exit codes**, not text. `synth_staged.sh`: 0 COMPLETED, 2 INCOMPLETE (resume), 1 FAILED.
5. Do not open or merge a PR without the owner's authorization. Phase 5 is paused.
6. Do not use dollar signs around numbers in docs (owner preference).

## Install recipes that worked (2026-10-13, Alpine 3.23 microVM, root)
| Need | Command | Notes |
|---|---|---|
| iverilog, make, numpy | `apk add iverilog make py3-numpy` | pip is absent. `make -C sim <target>`; `test_cosim` takes about 40 s. |
| Yosys 0.68+post | `sh tools/setup_yosys_alpine.sh` then `. /opt/yroot/env.sh` | Private root, about 1-2 min, needs network. Prints versions. |
Things that did NOT work, so do not retry them: `apk add g++/build-base` (stalls at musl-dev trigger), PyPI `yowasp-yosys` wheel (needs glibc wasmtime), plain `apk add yosys` from main/community (it is only in edge/testing). Docker/podman: not present; `ci/Dockerfile.yosys` is untested.

## Running synthesis in a 120 s call limit
```
. /opt/yroot/env.sh
RUN_TAG=<tag> scripts/synth_staged.sh <top> "<extra cmds>" <files>   # repeat while exit status is 2
```
- Per-module examples: `logs/synth_per_module*/`. CPU with SoC parameters: `scripts/synth_cpu_soc_params.sh`.
- A single stage cannot be resumed mid-way. If a stage alone exceeds the call limit, use a machine without the limit (`BUDGET=3600`).
- Tests: `make -C sim <target>`; whole list in the root `Makefile` (`make all` needs everything installed).
- `make synth_check` is an elaboration check only.

## Where things are
- Status and open questions: `docs/19_synthesis_handoff_and_status.md` (resume point: its section 8).
- Tool and per-module results: `docs/18_yosys_environment_and_per_module_synthesis.md`; raw: `logs/`.
- Post-merge verification findings: `docs/17_post_merge_verification_snapshot.md`.
- Superseded: the synthesis claims in docs 11 and 12, README, CHECKPOINT_REPORT (marked in place).
