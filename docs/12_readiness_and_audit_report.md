# RISC-V FlowBot: Master Roadmap Readiness & Post-Merge Verification Audit

**Status:** Completed  
**Recommendation:** **CONDITIONAL GO for Phase 1 Execution**  
**Date:** October 2026  
**Auditor:** RISC-V SoC Designer (FlowBot Engine)  
**Branch:** `flowbot/master-project-roadmap`  
**Base Commit:** `7523f3e` (merged `main`)  
**Reference Document:** `docs/PROJECT_ROADMAP.md`

---

## 1. Executive Summary & Readiness Verdict

Following the successful merge of the Engineering Hardening Phase into `main`, this audit evaluated the repository's post-merge baseline, executed the full clean regression suite, profiled local host compute resources, verified accelerator hardware semantics, and compared implemented SoC capabilities against the long-term robotics vision established in `docs/PROJECT_ROADMAP.md`.

### **Readiness Recommendation: CONDITIONAL GO FOR PHASE 1**

The system is architecturally, computationally, and functionally ready to begin **Phase 1 (RL Environment and Policy Training)**, subject to three non-negotiable operational conditions:

1. **Lightweight Pure-NumPy RL Implementation:** Due to strict local environment resource limits (**458 MB total RAM, 0 MB swap, single vCPU, Python 3.14**), standard heavy frameworks such as PyTorch, TorchRL, and Stable-Baselines3 cannot be deployed without kernel Out-Of-Memory (OOM) termination. Phase 1 RL training must be implemented using a self-contained, lightweight vectorized NumPy simulator and training algorithm (e.g., Augmented Random Search [ARS] or Policy Gradient / REINFORCE).
2. **Quantization-Aware Architectural Constraints from Day 1:** The neural policy architecture designed in Phase 1 must strictly respect the physical constraints of the `rv_nna` accelerator to guarantee seamless downstream execution in Phase 2:
   - Input dimension $K \le 16$, output dimension $M \le 16$ (or $M \le 64$ with $K \times M \le 1024$ weights per layer).
   - Hidden activation strictly `ACT_RELU` ($[0, +127]$).
   - Output activation strictly `ACT_CLIP` ($[-128, +127]$) or saturated linear.
   - Symmetric INT8 weights ($Z = 0$).
3. **Simulated Sensor Feed for Closed-Loop Validation:** Because hardware SPI and I2C peripherals are not yet implemented on the Wishbone bus, the initial closed-loop simulation in Phase 4 will feed preprocessed sensor state vectors via memory-mapped testbench injection or stream packets via the SoC UART, prior to physical FPGA sensor attachment in Phase 6.

---

## 2. Environment & Working Tree State

### 2.1 Git Repository Verification
- **Upstream Synchronization:** Pulled latest `main` via `git pull origin main`. Commit `7523f3e` ("Merge pull request #3 from r-abaryan/flowbot/hardening-complete") verified at HEAD.
- **Dedicated Audit Branch:** Branch created as `flowbot/master-project-roadmap`.
- **Working Tree State:** Completely clean. No uncommitted modifications or untracked build artifacts. `.gitignore` updated to ignore transient synthesis artifacts (`abc.history`).

### 2.2 Installed Toolchain & Host Versions

| Tool | Version / Release | Role |
| :--- | :--- | :--- |
| **Icarus Verilog (`iverilog`)** | `12.0 (stable)` | RTL compilation and testbench elaboration |
| **VVP (`vvp`)** | `12.0 (stable)` | Verilog simulation runtime engine |
| **Yosys (`yosys`)** | `0.68+post (git sha1 c12172fbae)` | Open-source RTL synthesis and technology mapping |
| **Python (`python3`)** | `3.14.8` | Reference models, fuzzing suite, build helpers |
| **NumPy (`numpy`)** | `2.5.3` | Matrix math and tensor validation |
| **RISC-V Assembler (`riscv-none-elf-as`)** | `GNU Binutils 2.45.1` | Assembles bare-metal firmware (`robot_nav_firmware.s`) |
| **RISC-V Linker (`riscv-none-elf-ld`)** | `GNU Binutils 2.45.1` | Links bare-metal firmware binaries |
| **GNU Make (`make`)** | `4.4.1` | Top-level build and simulation orchestration |

---

## 3. Host Compute Constraints Audit

To prevent host container termination, a comprehensive system resource inspection was performed:

```
Total Physical Memory:  458 MB
Available Memory:       405 MB
Swap Space:             0 MB
CPU Cores:              1 vCPU
Container OS:           Alpine Linux v3.23 (x86_64)
Python Runtime:         Python 3.14.8
```

### Resource Implication for Reinforcement Learning (Phase 1):
- Attempting to install PyTorch / PyTorch-geometric / Stable-Baselines3 will immediately exceed the 458 MB memory ceiling during wheel extraction or compilation, killing the container.
- **Enforced Architecture:** The 2D robot kinematics and RL policy training must be completely self-contained in Python using **NumPy only**.
- Peak memory during training must be held strictly under **50 MB**, allowing comfortable parallel headroom for system tasks and simulation testbenches.
- Training must execute deterministically in **under 2 minutes** on a single core.

---

## 4. Full Regression Verification

A complete regression test was executed across all software models, fuzzing suites, RTL testbenches, and synthesis checks:

```bash
make test_py test_nna_corners sim_all
```

### Verification Results Summary

| Target | Test Description | Result | Details |
| :--- | :--- | :--- | :--- |
| `test_py` | INT8 Reference Model Test | **PASS** | $K=16, M=8$ MAC and requantization validated |
| `test_py` | Fuzzing Suite (1000 vectors) | **PASS** | 1000/1000 random vectors passed bit-exact match |
| `test_nna_corners` | Python INT8 Corner Cases | **PASS** | Extreme saturation boundaries verified |
| `sim_nna` | RTL NNA Top Simulation | **PASS** | Scratchpad R/W, CSR handshakes, inference |
| `sim_safety` | RTL Safety Filter Baseline | **PASS** | Watchdog countdown and trip logic |
| `sim_nna_corners` | RTL NNA Corner Testbench | **PASS** | Signed saturation limits ($+127, -128$) verified |
| `sim_safety_adv` | RTL Adversarial Safety | **PASS** | 6 adversarial scenarios verified (lockout, race condition) |
| `sim_soc` | Full SoC System Simulation | **PASS** | Boot ROM, UART output, PWM drive in 523 cycles |
| `sim_nav` | Full SoC Navigation Sim | **PASS** | 5 navigation cycles with synthetic policy verified |
| `synth_check` | Yosys ECP5 Technology Mapping | **PASS** | Synthesized clean in 82.3 seconds (2,686 LUTs, 4 DSPs) |

**Total Regression Status: 10 out of 10 Targets PASSED (0 Errors, 0 Warnings).**

---

## 5. Accelerator Hardware Semantics Invariants

The `rv_nna` accelerator implements a specialized INT8 SIMD compute pipeline optimized for small robot control MLPs. The Phase 1/Phase 2 RL training pipeline must adhere to these mathematical invariants:

1. **Signed Two's Complement INT8:** All weights and inputs are signed 8-bit integers $[-128, +127]$. Zero-point is strictly symmetric ($Z = 0$).
2. **32-Bit Signed Accumulation:** The MAC unit accumulates four 8-bit products per cycle into a 32-bit register with zero intermediate rounding error:
   $$acc = \text{bias} + \sum_{k=0}^{K-1} w_{m,k} \cdot x_k$$
3. **Requantization Fixed-Point Formulation:**
   $$scaled = \left\lfloor \frac{acc \cdot \text{scale\_mult}}{2^{16}} \right\rfloor \gg \text{scale\_shift}$$
4. **Activations:**
   - Hidden Layer: `ACT_RELU` $\implies \text{clamp}(scaled, 0, 127)$.
   - Output Layer: `ACT_CLIP` $\implies \text{clamp}(scaled, -128, 127)$.
5. **Memory Capacity Limits:**
   - Scratchpad capacity: 4 KB total ($1024 \times 32$-bit words).
   - Maximum weights per layer: $1024$ bytes ($K \times M \le 1024$).
   - Supported matrix shapes: $16 \times 8$, $16 \times 16$, $32 \times 16$, $32 \times 32$.

---

## 6. Audit of Current vs. Long-Term Roadmap Status

| Subsystem | Implemented Status | Maturity Tier | Long-Term Target |
| :--- | :--- | :--- | :--- |
| **CPU Core** | PicoRV32 (RV32IM) | **SIMULATED / SYNTHESIZED** | PicoRV32 baseline + optional Ibex SystemVerilog dual-core |
| **Accelerator** | `rv_nna` 4-way SIMD INT8 | **SIMULATED / SYNTHESIZED** | Dual-port synchronous BRAM inference (Phase 5) |
| **Safety Interlock** | Multi-hazard hardware supervisor | **SIMULATED / SYNTHESIZED** | Physical E-stop button + bumper switch integration (Phase 6) |
| **Robot Policy** | Hand-crafted synthetic weights | **SIMULATED** | **Genuinely trained RL policy (Phases 1–4)** |
| **Closed-Loop Testing**| Open-loop / synthetic testbench | **SIMULATED** | **Closed-loop co-simulation harness (Phase 4)** |
| **FPGA Target** | Yosys mapped to Lattice ECP5 | **SYNTHESIZED** | **PnR & static timing closure on physical board (Phase 5)** |
| **Physical Sensors** | Wishbone memory input buffer | **SIMULATED** | Physical I2C/SPI LiDAR & IMU bridge (Phase 6) |

---

## 7. Concrete Phase 1 Action Plan

1. **Step 1.1 — Implement Pure-NumPy 2D Kinematic Simulator (`sw/env/nav_env_2d.py`):**
   - Unicycle kinematics: differential drive robot with position $(x, y)$, heading $\theta$, forward velocity $v \in [0, v_{\max}]$, angular velocity $\omega \in [-\omega_{\max}, \omega_{\max}]$.
   - 12-ray rangefinder sensor model intersecting static circular and polygonal obstacles.
   - Target-relative polar coordinates $(d, \phi)$ and velocity odometry $(v, \omega)$.
   - Total state vector: exactly 16 features, pre-normalized.
2. **Step 1.2 — Implement Baseline Agents (`sw/training/baselines.py`):**
   - Pure random walk agent.
   - Heuristic Braitenberg / potential-field obstacle avoidance agent.
   - Automated benchmark runner across 50 fixed evaluation seeds.
3. **Step 1.3 — Implement Lightweight Pure-NumPy RL Trainer (`sw/training/train_rl.py`):**
   - Augmented Random Search (ARS) or Policy Gradient optimizer running within $< 40$ MB RAM and $< 90$ seconds CPU time.
   - 2-layer MLP policy: 16 inputs $\rightarrow$ 16 hidden (ReLU) $\rightarrow$ 2 outputs (clamped linear).
   - Training loss/reward history tracking and convergence logging.
4. **Step 1.4 — Evaluation Benchmark & Gate 1 Report:**
   - Evaluate trained policy vs random and heuristic baselines across 50 benchmark episodes.
   - Save float32 policy model weights (`sw/model/trained_float32_policy.npz`).
   - Document results in `docs/13_phase1_rl_training_report.md`.

---

## 8. Conclusion & Readiness Sign-off

The RISC-V FlowBot repository is in a completely verified state with all hardening requirements satisfied, zero test failures, and measured FPGA synthesis metrics.

With the master project roadmap formalized in `docs/PROJECT_ROADMAP.md` and host constraints clearly accounted for, **Phase 1 (RL Environment and Policy Training) is ready to begin**.
