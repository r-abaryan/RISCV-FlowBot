# RISC-V FlowBot: Engineering Hardening Roadmap & Action Plan

This document outlines the objectives, audit checklist, test matrices, and deliverables for the Engineering Hardening Phase of the RISC-V FlowBot SoC.

---

## 1. Objectives & Guidelines
- **Goal:** Harden the existing prototype into a fully reproducible, strictly verifiable, and synthesis-ready design.
- **Scope Restriction:** No major new architectural features until hardening is complete.
- **Strict Integrity Principle:** Do not hide failures or work around bugs to fabricate a "PASS". A failed test, synthesis timing limitation, or architectural constraint is valuable engineering data and must be documented honestly.
- **Accurate Claims:** Audit and refine claims such as "zero-wait-state", "full-system verification", or "portable Verilog" to reflect exact measured reality.

---

## 2. Hardening Checklist & Action Plan

### 1. Repository Reproducibility
- [ ] Scan and eliminate all absolute paths (e.g., `/workspace/...`) across Makefiles, scripts, simulation testbenches, and firmware build scripts. Use relative paths rooted at repo root (`$(repo_root)` or script relative dir).
- [ ] Ensure all dependencies (including PicoRV32 / CPU core source, binutils/toolchains, scripts) are committed or reproducibly vendored/fetched.
- [ ] Verify clean clone reproduction in an isolated directory.
- [ ] Document exact prerequisites, tool versions, and build/test commands in README and documentation.

### 2. Strengthened Full-System Verification
- [ ] Audit `tb_soc_top.v`, `tb_soc_nav.v`, and peripheral testbenches.
- [ ] Remove naive termination checks (e.g., reaching `0xCAFEBABE` alone is not proof of correctness).
- [ ] Implement explicit assertions for:
  - Accelerator outputs vs. expected golden vectors.
  - Motor PWM period, duty cycle, and deadtime behavior.
  - Hardware safety filter disarm/clamp states.
  - Watchdog heartbeat transitions and timeout interlock trip.
  - Memory read/write transaction validity and Wishbone protocol adherence.
- [ ] Ensure any assertion failure, timeout, or unexpected MMIO response returns a non-zero exit code (`$fatal` / `$finish(1)`).
- [ ] Format test output to clearly distinguish `PASS`, `FAIL`, and `TIMEOUT`.

### 3. Independent Neural Accelerator Verification
- [ ] Develop comprehensive cross-verification test suite comparing RTL (`nna_pe`, `nna_requant`, `rv_nna`) against Python reference model.
- [ ] Test deterministic corner cases:
  - INT8 min (-128) and max (+127).
  - Accumulator overflow boundaries (32-bit signed saturation).
  - Negative biases, zero inputs/weights.
  - Requantization shift (0 to 15), multiplier scale factors, rounding modes.
  - ReLU clamping ($x < 0 \rightarrow 0$) vs. linear passthrough vs. INT8 clamping.
- [ ] Report any arithmetic differences directly rather than altering the golden model.

### 4. Adversarial Safety Testing
Develop dedicated adversarial test scenarios in `sim/tb_safety_adversarial.v`:
1. **Missing Heartbeat:** CPU fails to refresh within watchdog timeout period; verify immediate motor cutoff.
2. **Timing Boundary Heartbeats:** Heartbeat sent exactly 1 cycle before expiration, or right at timeout.
3. **Emergency Stop (E-Stop):** Hardware E-stop triggered mid-trajectory during high PWM duty cycle; verify instantaneous disarm (<1 cycle).
4. **CPU Stall/Hang:** Bus hang or instruction stall; verify watchdog trips independently of CPU state.
5. **Accelerator Stuck Busy:** Accelerator fails to return `done` or asserts busy indefinitely; verify system safety is preserved.
6. **Malformed MMIO Accesses:** Out-of-bounds addresses, unaligned accesses, illegal writes to read-only status registers.
7. **Extreme Policy Outputs:** Saturation/overflow values from neural inference (e.g., +127, -128, NaN/inf equivalents); verify safety layer strictly clamps velocities to safe limits.
8. **Invalid Scaling/Shift Configurations:** Setting shift > 15 or invalid multiplier; verify well-defined behavior or error flag.
9. **Simultaneous PWM Update and Watchdog Trip:** Race conditions between firmware writing duty cycle and watchdog expiring in the exact same clock cycle.

### 5. Real FPGA Synthesis & Resource Reporting
- [ ] Set up Yosys synthesis target (preferably Lattice ECP5 or iCE40 open toolchain).
- [ ] Perform real synthesis without fabrications or hand-waving estimates.
- [ ] Extract and document exact utilization metrics:
  - Logic cells / LUTs.
  - Flip-Flops / registers.
  - BRAM / EBR blocks.
  - DSP slices / multipliers.
- [ ] Extract timing estimates (estimated $f_{max}$, critical paths) where available from nextpnr/yosys.
- [ ] Clearly delineate measured synthesis metrics from unverified estimates.

### 6. Architectural Claim Audit & Precise Refactoring
- [ ] Replace overstatements ("zero-wait-state", "fully verified") with precise statements (e.g., "single-cycle pipelined MAC execution with 1-cycle scratchpad access latency").
- [ ] Clarify actual bus latencies, bus contention, and arbitration behavior.

### 7. Documentation & Deliverables
- [ ] Deliver `docs/09_hardening_report.md` detailing:
  - Architectural audit findings.
  - Changes made across RTL, firmware, and testbenches.
  - Full test matrices and test execution commands.
  - PASS/FAIL/TIMEOUT status table.
  - Measured Yosys synthesis results.
  - Unresolved problems & technical debt.
  - Assumptions and prerequisites.
  - Recommended next steps for Phase 2.
- [ ] Update Decision Log (`docs/08_decision_log.md`) with any architectural refinements.
- [ ] Commit all changes atomically and prepare GitHub push.

---
*Created for RISC-V FlowBot engineering hardening phase.*
