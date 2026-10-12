# RISC-V FlowBot: Pre-RL Engineering Hardening Roadmap & Action Plan

> **STATUS: 100% COMPLETED MILESTONE.**  
> This roadmap documents the completed engineering hardening phase that brought the base RTL, simulation testbenches, and synthesis pipeline to an auditable, verified baseline.  
> **Master Project Roadmap:** For ongoing and future phases (Phase 1 through Phase 6), please consult [`docs/PROJECT_ROADMAP.md`](PROJECT_ROADMAP.md).

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
- [x] Ensure every testbench fails with a non-zero exit code (`$fatal`) on mismatch, protocol error, or timeout.
- [x] Add watchdog timers to all testbenches to prevent infinite simulation loops on bus deadlock or unhandled CPU traps.

### 3. Rigorous Python-to-RTL Quantization Verification
- [x] Implement comprehensive edge/corner case tests comparing `sw/model/reference_model.py` and `nna_core.v` / `nna_mac4.v`:
  - Full-range saturation limits ($-128$, $+127$)
  - Negative zero handling
  - Scale factor dynamic ranges (shifts $0$ to $31$, multiplier boundaries)
  - Variable vector sizes ($K$ non-multiples of 4, padded behavior)
  - Accumulator headroom verification
- [x] Implement randomized fuzzing suite (`sw/model/fuzz_nna_reference.py`) executing 1000+ random vector dot-products.
- [x] Add dedicated RTL corner-case testbench `sim/tb_nna_corner_cases.v`.

### 4. Adversarial Safety Supervisor Testing
- [x] Design stress tests for `safety_filter.v`:
  - Rapid heartbeat strobing near timer expiry boundary (jitter tolerance)
  - Software lockup / infinite loop injection in firmware
  - Sudden external E-stop assertion during high-throttle motor actuation
  - Software attempting to re-arm while physical E-stop remains asserted (resolved hardware bug!)
  - Out-of-range sensor injections (simulated NaN / saturation / sensor failure)
  - Race condition checks between software heartbeat writes and hardware timer trips
- [x] Add dedicated adversarial testbench `sim/tb_safety_adversarial.v`.

### 5. Real FPGA Synthesis & Resource Reporting
- [x] Run real logic synthesis using Yosys targeting an open FPGA architecture (Lattice ECP5 `LFE5U-25F`).
- [x] Report real, measured resource utilization:
  - Total LUT4s and logic cell count
  - Registers (DFFs)
  - Dedicated DSP multipliers (`MULT18X18D`)
  - Block RAM / distributed RAM utilization
- [x] Report maximum achievable operating frequency ($F_{\max}$) and critical path analysis.
- [x] Document synthesis findings in `docs/11_fpga_synthesis_report.md`.

### 6. Architectural Claims Audit & Integrity Review
- [x] Reconcile "zero-wait-state" claim: document actual Wishbone bus protocol wait-states (PicoRV32 takes multiple cycles per memory transaction; NNA registers assert `ack` combinatorially or with single-cycle latency).
- [x] Formally specify INT8 numerical representation (signed two's complement, zero-point $Z=0$) in `docs/09_hardware_semantics_and_assumptions.md`.
- [x] Clarify verification coverage: clearly distinguish between module unit tests, firmware integration tests, and future closed-loop environment evaluations.
- [x] Document all remaining hardware assumptions, known synthesis trade-offs, and physical robot interfaces in `docs/09_hardware_semantics_and_assumptions.md`.
