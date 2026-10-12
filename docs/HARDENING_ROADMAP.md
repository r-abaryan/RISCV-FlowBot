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
- [x] Scan and eliminate all absolute paths across Makefiles, scripts, simulation testbenches, and firmware build scripts. Use relative paths rooted at repo root (`$(ROOT_DIR)`).
- [x] Ensure all dependencies (including PicoRV32 CPU core source `rtl/cpu/picorv32.v`, pre-assembled hex ROM files, Python test suites) are committed or reproducibly tracked.
- [x] Verify clean clone reproduction in an isolated directory.
- [x] Document exact prerequisites, tool versions, and build/test commands in README and documentation.

### 2. Strengthened Full-System Verification
- [x] Audit `tb_soc_top.v`, `tb_soc_nav.v`, and peripheral testbenches.
- [x] Remove naive termination checks: implement explicit value assertions against golden vectors.
- [x] Implement explicit assertions for:
  - Accelerator outputs vs. expected golden vectors.
  - Motor PWM period, duty cycle, and deadtime behavior.
  - Hardware safety filter disarm/clamp states.
  - Watchdog heartbeat transitions and timeout interlock trip.
  - Memory read/write transaction validity and Wishbone protocol adherence.
- [x] Ensure any assertion failure, timeout, or unexpected MMIO response returns a non-zero exit code (`$fatal(1, ...)`) with watchdog timers.
- [x] Format test output to clearly distinguish `PASS`, `FAIL`, and `TIMEOUT`.

### 3. Independent Neural Accelerator Verification
- [x] Develop comprehensive cross-verification test suite comparing RTL against Python reference model (`sw/test/test_nna_corners.py`).
- [x] Test deterministic corner cases in `sim/tb_nna_corner_cases.v`:
  - INT8 min (-128) and max (+127) accumulation clamps.
  - Accumulator overflow boundaries (32-bit signed saturation).
  - Negative biases, extreme bias dominance, zero inputs/weights.
  - Requantization shift (0 to 15), multiplier scale factors, rounding modes.
  - ReLU clamping ($x < 0 \rightarrow 0$) vs. linear passthrough vs. INT8 clamping.
  - Auto-copy chaining and invalid parameter ($K \pmod 4 \ne 0$) error abort.
- [x] 1,000 randomized Monte Carlo vectors verified with bit-exact parity.

### 4. Adversarial Safety Testing
- [x] Develop dedicated adversarial test suite in `sim/tb_safety_adversarial.v`:
  - **Missing Heartbeat:** Countdown expires, immediate motor PWM cutoff.
  - **Timing Boundary Heartbeats:** Single-cycle boundary countdown expiration.
  - **Emergency Stop (E-Stop):** Hardware E-stop triggered; verifies instantaneous combinational clamp (<1 cycle).
  - **Corrupted Heartbeats:** Invalid keys rejected, watchdog countdown unaffected.
  - **E-Stop Lockout Fix:** Resolved vulnerability where software could clear a trip while physical E-stop button remained pressed.
  - **Firmware Disable Attempt:** `reg_enable = 0` forces immediate fail-safe actuator cutoff.
  - **Asynchronous Reset Glitches:** Actuator cutoff asserted asynchronously on `!rst_n`.

### 5. Real FPGA Synthesis & Resource Reporting
- [x] Synthesize SoC and constituent modules with Yosys for Lattice ECP5 target.
- [x] Extract and document exact utilization metrics (no fabricated estimates):
  - `picorv32`: 1,314 LUT4, 573 TRELLIS_FF, 0 DSP, 32 Distributed RAM slices.
  - `nna_mac4`: 88 LUT4, 0 FF, 4 DSP MULT18X18D slices.
  - `nna_core`: 1,002 LUT4, 139 FF, 8 DSP MULT18X18D slices.
  - `safety_filter`: 244 LUT4, 67 FF.
  - `soc_uart`: 25 LUT4, 17 FF.
  - `soc_timer`: 247 LUT4, 163 FF.
  - `soc_pwm`: 73 LUT4, 66 FF.
  - `soc_ram`: 7 LUT4, 1 FF, 32 Block RAM (DP16KD) tiles.
  - `soc_interconnect`: 355 LUT4, 1 FF.
- [x] Identify key scratchpad BRAM inference optimization for future revisions (transitioning from combinational read ports to registered reads to save 12K flip-flops).
- [x] Formally document in `docs/11_fpga_synthesis_report.md`.

### 6. Architectural Claim Audit & Precise Refactoring
- [x] Replaced vague claims ("zero-wait-state", "instantaneous") with exact cycle-accurate specifications.
- [x] Confirmed Wishbone bus latency (single master, round-robin crossbar arbiter, 1-cycle latency per transaction).
- [x] Documented NNA throughput: 4 INT8 MACs/cycle, requiring $(K/4)$ cycles per neuron plus 1 cycle for bias addition/requantization.

### 7. Documentation & Deliverables
- [x] Consolidated reports delivered:
  - `docs/10_hardening_report.md`
  - `docs/11_fpga_synthesis_report.md`
- [x] Decision Log updated (`docs/08_decision_log.md`).
- [x] All test suites committed, regression passing, and merged to `main`.

---
*Status: Engineering Hardening Phase 100% Complete.*
