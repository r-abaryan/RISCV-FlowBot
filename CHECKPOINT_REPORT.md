# RISC-V Mobile Robot SoC - Checkpoint Report

**Date:** October 12, 2026  
**Current Milestone:** Pre-RL Hardware Baseline & Engineering Hardening Complete; Ready for Phase 1 Execution  
**Reference Document:** `docs/PROJECT_ROADMAP.md` (Master Project Roadmap)  
**Status:** All baseline hardware modules, verification testbenches, and hardening objectives completed with zero errors. System is ready to begin Phase 1 (RL Environment and Policy Training).

---

## 1. Current Architecture Summary

The designed SoC architecture is tailored for reinforcement learning (RL) mobile robot control, balancing hardware simplicity, determinism, and open-source FPGA toolchain compatibility.

### 1.1 Key Subsystems
1. **CPU Subsystem:**
   - **Integrated Baseline Core:** PicoRV32 (RV32IM with Wishbone B4 bus master adapter), ensuring 100% portable Verilog-2001 synthesis across any FPGA toolchain (Yosys/NextPNR, Vivado, Quartus).
   - **Recommended Upgrade Path:** lowRISC Ibex (2-stage in-order pipeline, RV32IM, SystemVerilog).
   - **Role:** Sensor acquisition (IMU, distance sensors, wheel encoders), feature pre-processing, policy invocation, communication, and deterministic safety enforcement.
2. **Neural Accelerator (`rv_nna`):**
   - **Interface:** Standard 32-bit Wishbone B4 memory-mapped register interface at base `0x5000_0000` / `0x5000_0080`.
   - **Datapath:** 4-way parallel signed INT8 multiply-accumulate (`nna_mac4`), 32-bit accumulator, bias addition, fixed-point scale factor multiplier, barrel shifter, and activation saturation unit.
   - **Scratchpads:** 128 B input activation buffer, 256 B (64x32-bit) bias buffer, 1024 B weight buffer, 128 B output buffer.
   - **Throughput:** 4 INT8 MACs per cycle (80 MOPS at 20 MHz, 200 MOPS at 50 MHz).
3. **Deterministic Safety Architecture:**
   - **Software Supervisor:** Runs on RISC-V in the real-time control loop. Implements physical boundary clamps, slew-rate dynamic acceleration limiters, and time-to-collision (TTC) obstacle braking.
   - **Hardware Safety Filter (`safety_filter`):** Dedicated MMIO watchdog at `0x5000_0600`. Enforces heartbeat token refreshes within a programmed cycle deadline and directly gates motor PWM drivers via an independent hardware disarm/E-Stop interlock. Hardened against physical E-stop re-arm race conditions.
4. **Peripherals & Memory:**
   - 8 KB Boot ROM (`0x0000_0000`), 16 KB/64 KB Main SRAM (`0x2000_0000`), SoC Timer with 64-bit cycle counter (`0x5000_0200`), Diagnostic UART TX (`0x5000_0100`), Dual-channel Motor PWM Generator (`0x5000_0300`), Safety Filter (`0x5000_0600`).
   - Central address decoding crossbar interconnect (`soc_interconnect.v`).

### 1.2 Baseline Policy vs. Master Roadmap Distinction
- **Current Baseline Status:** The current simulation (`sim/tb_soc_nav.v`) proves the complete RV32IM CPU + MMIO accelerator + safety interlock + PWM dataflow using a **synthetic heuristic policy** (hand-tuned weights). It demonstrates that the hardware execution pipeline functions correctly.
- **Master Roadmap Objective:** Developing, training, quantizing, integrating, and evaluating a **genuine reward-driven reinforcement learning policy** in closed-loop navigation constitutes the work of **Phases 1 through 4**.

---

## 2. Documented Assumptions & Hardening Audits

1. **Policy Architecture:** The mobile robot RL policy is a standard 2-layer Multi-Layer Perceptron (MLP) with observation sizes of 16 features (distance sensors, linear velocity, angular velocity, target heading, target distance) and action output size of 2 (linear velocity $v$, angular velocity $\omega$).
2. **Quantization Precision:** INT8 symmetric quantization ($Z = 0$) for both weights and activations is used. Formal bounds and saturation semantics ($[-128, +127]$ for linear/clip, $[0, +127]$ for ReLU) are strictly verified without arithmetic wrap-around.
3. **Accumulator Headroom:** A signed 32-bit accumulator provides 11 bits of mathematical headroom for 64-input dot products, guaranteeing zero overflow for valid trained weights. Requantization uses a 49-bit intermediate multiplier product before arithmetic right shifting.
4. **Control Frequency & Latency:** The robot real-time control loop runs between 200 Hz and 1,000 Hz. A full 2-layer inference (16->8->2) executes in ~200 accelerator cycles (< 5 microseconds at 50 MHz), utilizing < 0.5% of the control cycle budget.
5. **Deterministic Hardware Interlock:** Physical E-stop actuation asserts within $T_{pd} < 10\text{ ns}$ via asynchronous gating, latching a hardware trip state that cannot be cleared by software while physical E-stop remains asserted.

---

## 3. Verification & Synthesis Matrix

| Test Suite / Target | Description | Status | Evidence / Notes |
| :--- | :--- | :---: | :--- |
| `sw/model/reference_model.py` | Python bit-exact INT8 reference model | **PASS** | Validated against expected dot-product vectors. |
| `sw/model/fuzz_nna_reference.py`| Python 1000-vector randomized fuzzing suite | **PASS** | 1000/1000 vectors bit-exact match across all dimensions. |
| `sw/model/test_nna_corners.py` | Python INT8 extreme corner/saturation suite | **PASS** | 9 edge scenarios (min, max, overflow clamp, zero shift). |
| `sw/safety/safety_layer.py` | Python deterministic safety supervisor reference | **PASS** | Validated envelope clamp, slew limits, and TTC braking. |
| `sw/policy/nav_policy.py` | Python 16->8->2 obstacle avoidance policy | **PASS** | Validated open-field, left-steer, right-steer, and emergency stop. |
| `sim/tb_nna_top.v` | NNA MMIO registers & basic inference testbench | **PASS** | Scratchpad R/W, CSR handshakes, inference completion. |
| `sim/tb_safety_filter.v` | Safety filter hardware unit testbench | **PASS** | Watchdog countdown, token refresh, E-stop gating. |
| `sim/tb_nna_corner_cases.v` | NNA RTL edge/corner case verification | **PASS** | Verifies saturation clamp (+127, -128) in hardware. |
| `sim/tb_safety_adversarial.v`| Adversarial safety filter verification | **PASS** | 6 multi-hazard scenarios (race condition, lockout). |
| `sim/tb_soc_top.v` | Full SoC system boot & diagnostic testbench | **PASS** | CPU boots, executes ROM, writes UART & PWM in 523 cycles. |
| `sim/tb_soc_nav.v` | End-to-end SoC navigation testbench | **PASS** | CPU runs 5 control cycles with obstacle clamping & PWM. |
| `make synth_check` | Yosys synthesis mapping to Lattice ECP5 | **PASS** | Synthesized clean in 82.3 seconds (2,686 LUTs, 4 DSPs). |

---

## 4. Current Hardware Resource Utilization

### Real Measured Yosys Synthesis Metrics (Lattice ECP5 `LFE5U-25F`)
- **Total Logic Cells (LUT4 equivalents):** 2,686 / 24,288 (11.06% of target device)
- **Registers (D-Type Flip-Flops):** 2,130
- **Hardware DSP Slices (MULT18X18D):** 4 / 28 (14.29% of target device)
- **Estimated Maximum Clock Frequency ($F_{\max}$):** ~38 MHz (PicoRV32 datapath)

*Detailed breakdown available in `docs/11_fpga_synthesis_report.md`.*

---

## 5. Artifacts Produced & Tracked

### Master Documentation (`docs/`)
- `PROJECT_ROADMAP.md`: Master 6-phase project roadmap with engineering gates and criteria.
- `01_system_architecture.md`: SoC architecture and interconnect topology.
- `02_cpu_selection.md`: RV32 core trade-off analysis and Ibex / PicoRV32 selection.
- `03_memory_map.md`: System memory map and register offsets.
- `04_accelerator_spec.md`: `rv_nna` datapath, CSR map, and FSM specification.
- `05_dataflow_and_quantization.md`: Sensor normalization and INT8 QAT formulation.
- `06_deterministic_safety.md`: Multi-stage safety supervisor and hardware watchdog.
- `07_fpga_and_verification.md`: Verification plan, FPGA targets, and resource analysis.
- `08_decision_log.md`: Architectural decision log.
- `09_hardware_semantics_and_assumptions.md`: Mathematical invariants, INT8 bounds, and timing guarantees.
- `10_hardening_report.md`: Engineering Hardening Phase audit and resolution report.
- `11_fpga_synthesis_report.md`: Measured Yosys synthesis results for Lattice ECP5.
- `12_readiness_and_audit_report.md`: Phase 1 readiness assessment and host compute audit.

### Hardware RTL (`rtl/`)
- Full synthesizable Verilog modules: `soc_pkg.sv`, `picorv32.v`, `soc_interconnect.v`, `soc_rom.v`, `soc_ram.v`, `soc_timer.v`, `soc_uart.v`, `soc_pwm.v`, `nna_top.v`, `nna_regs.v`, `nna_mac4.v`, `nna_core.v`, `safety_filter.v`, `soc_top.v`.

### Software & Firmware (`sw/`)
- Golden models, policy implementations, 1000-vector fuzzers, C HAL headers, two-pass assembler, and navigation firmware.

---

## 6. Master Project Roadmap & Next Steps

Work is now governed by the 6-phase Master Project Roadmap (`docs/PROJECT_ROADMAP.md`):

1. **Phase 1 — RL Environment and Policy Training (NEXT):**
   - Implement lightweight 2D unicycle kinematic simulator (`sw/env/nav_env_2d.py`).
   - Implement pure-NumPy policy trainer (`sw/training/train_rl.py`) using ARS / Policy Gradient.
   - Train reward-driven 2-layer MLP (16->16->2) and evaluate against random and heuristic baselines.
2. **Phase 2 — INT8 Quantization and Accelerator Validation:**
   - Quantize trained policy to `rv_nna` INT8 specification.
   - Verify bit-exact equivalence between Python reference and Verilog RTL accelerator.
3. **Phase 3 — RISC-V Firmware and SoC Integration:**
   - Embed trained policy into bare-metal firmware.
   - Execute multi-step inference, deterministic safety filtering, and PWM drive on full SoC simulation.
4. **Phase 4 — Closed-Loop Robotics Evaluation:**
   - Connect SoC simulation directly to 2D environment simulator in a closed-loop co-simulation harness.
   - Benchmark episode success rates, collisions, and safety intervention frequencies.
5. **Phase 5 — FPGA Implementation and Timing Closure:**
   - Refactor scratchpad RAM to infer dedicated Block RAM (EBR/BRAM), resolving LUT overhead.
   - Complete Nextpnr/Vivado place-and-route and static timing analysis ($\ge 25\text{ MHz}$).
6. **Phase 6 — Physical Robot Integration:**
   - Deploy bitstream to physical FPGA board on differential drive rover chassis.
   - Connect real sensors/motors and validate safety under human supervisor oversight.
