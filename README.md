# Open-Source RISC-V SoC for Reinforcement Learning Mobile Robot Control

A lightweight, open-source System-on-Chip (SoC) architecture designed for reinforcement learning (RL) based mobile robot control on embedded FPGAs.

The SoC pairs an **RV32IM CPU core (PicoRV32 baseline / lowRISC Ibex reference)** with a dedicated memory-mapped **INT8 Matrix-Vector Neural Network Accelerator (`rv_nna`)**, a **Deterministic Safety Supervisor Layer**, and standard robotic peripherals over a 32-bit Wishbone B4 bus.

---

## 1. Architecture Overview

```
+---------------------------------------------------------------------------------------+
| RISC-V Mobile Robot SoC                                                               |
|                                                                                       |
|  +--------------------+                       +------------------------------------+  |
|  | RV32IM CPU Core    |                       | Neural Network Accelerator (NNA)   |  |
|  | - Ibex / PicoRV32  |                       | - 4-way parallel INT8 SIMD MAC     |  |
|  | - M Extension      |                       | - 32-bit Accumulator & Bias Adder  |  |
|  | - Wishbone B4      |                       | - Scale / Shift Requantization     |  |
|  +---------+----------+                       | - Activation (ReLU / Clamping)     |  |
|            |                                  +-----------------+------------------+  |
|            |                                                    |                     |
|            +================= Wishbone Interconnect ============+                     |
|                                        |                                              |
|            +---------------------------+---------------------------+                  |
|            |                           |                           |                  |
|  +---------v----------+      +---------v----------+      +---------v---------------+  |
|  | Memories           |      | Peripherals        |      | Hardware Safety Filter  |  |
|  | - 8 KB Boot ROM    |      | - 64-bit Timer     |      | - Heartbeat Watchdog    |  |
|  | - 16/64 KB SRAM    |      | - Diagnostic UART  |      | - External E-Stop Line  |  |
|  +--------------------+      | - Dual-Channel PWM |      | - Motor Disarm Interlock|  |
|                              +--------------------+      +-----------------+-------+  |
+----------------------------------------------------------------------------|----------+
                                                                             v
                                                                    To Motor Drivers
```

### Key Architectural Tenets
1. **CPU for General Control & Safety:** The RISC-V CPU coordinates sensor polling (IMU, distance sensors, odometry), feature normalization, scheduling, communication, and deterministic safety verification.
2. **Memory-Mapped Neural Accelerator (`rv_nna`):** Accelerates dense matrix-vector multiplications (Y = W * X + B) with per-layer fixed-point requantization and activations. Decoupled via MMIO to allow standard GCC toolchains without compiler patches.
3. **Deterministic Safety Supervisor:** The neural policy is treated as an *unverified advisor*. Its velocity proposals must pass through envelope bounding, dynamic slew-rate acceleration limiters, and time-to-collision (TTC) braking before reaching motor drivers. A hardware watchdog automatically disarms motors if software fails.

---

## 2. Project Status & Capability Maturity

To maintain engineering rigor, capabilities in this repository are categorized into strict maturity tiers:
- **Baseline Hardware & RTL:** **SIMULATED & SYNTHESIZED** (All modules verified with 10 testbenches in Icarus Verilog; per-module Yosys ECP5 mapping only; whole-SoC synthesis not completed, see docs/19).
- **Baseline Firmware & Navigation:** **SIMULATED** (Proves the complete CPU -> MMIO NNA -> Safety Interlock -> PWM pipeline in `tb_soc_nav.v` using a *synthetic heuristic policy*).
- **Genuine RL Policy & Closed-Loop Robotics:** **READY FOR EXECUTION** (Governed by the 6-phase Master Roadmap).

### Master Project Roadmap Overview

Detailed specifications, acceptance criteria, and evidence requirements are formalized in [`docs/PROJECT_ROADMAP.md`](docs/PROJECT_ROADMAP.md):

| Phase | Milestone Name | Objective & Scope | Status |
| :---: | :--- | :--- | :---: |
| **Phase 1** | **RL Environment & Policy Training** | Lightweight 2D unicycle simulator; train genuine reward-driven policy (ARS/PG); benchmark vs random/heuristic baselines | **READY TO START** |
| **Phase 2** | **INT8 Quantization & Validation** | Map trained float32 policy to exact `rv_nna` INT8 specs; bit-exact verification against Python reference | Planned |
| **Phase 3** | **Firmware & SoC Integration** | Embed trained weights in bare-metal RISC-V firmware; execute full multi-step inference in simulated SoC | Planned |
| **Phase 4** | **Closed-Loop Robotics Evaluation** | Co-simulate SoC RTL + 2D environment; measure episode success rate, collisions, latency & safety interventions | Planned |
| **Phase 5** | **FPGA Timing Closure & BRAM Fix** | Refactor scratchpad memory to infer true Block RAM (EBR); place-and-route & static timing analysis ($\ge 25\text{ MHz}$) | Planned |
| **Phase 6** | **Physical Robot Integration** | Interface physical LiDAR/IMU/H-bridge; execute supervised autonomous navigation with physical E-stop certification | Planned |

---

## 3. Directory Structure

```
.
├── docs/                             # Comprehensive Architecture & Engineering Reports
│   ├── PROJECT_ROADMAP.md            # Master 6-Phase Project Roadmap & Engineering Gates
│   ├── 01_system_architecture.md     # SoC architecture, subsystem roles & block diagram
│   ├── 02_cpu_selection.md           # Evaluation of RV32 cores & lowRISC Ibex justification
│   ├── 03_memory_map.md              # Address space layout and peripheral allocation
│   ├── 04_accelerator_spec.md        # rv_nna register map, datapath & compute FSM
│   ├── 05_dataflow_and_quantization.md# End-to-end sensor-to-actuator flow & INT8 format
│   ├── 06_deterministic_safety.md    # Multi-stage safety supervisor algorithms & watchdog
│   ├── 07_fpga_and_verification.md   # RTL breakdown, verification, FPGA targets & risks
│   ├── 08_decision_log.md            # Architecture trade-offs and decision log
│   ├── 09_hardware_semantics_and_assumptions.md # Numerical invariants & hardware semantics
│   ├── 10_hardening_report.md        # Engineering Hardening Phase completion report
│   ├── 11_fpga_synthesis_report.md   # Measured Yosys Lattice ECP5 synthesis metrics
│   ├── 12_readiness_and_audit_report.md # Phase 1 readiness assessment & compute audit
│   └── HARDENING_ROADMAP.md          # Completed pre-RL engineering hardening checklist
├── rtl/                              # Hardware RTL Source Files
│   ├── soc_pkg.sv                    # Global parameters, memory map addresses, CSR defs
│   ├── cpu/
│   │   └── picorv32.v                # RV32IM CPU core with Wishbone B4 bus adapter
│   ├── bus/
│   │   └── soc_interconnect.v        # Wishbone B4 address decoder & slave crossbar
│   ├── mem/
│   │   ├── soc_rom.v                 # Synchronous Boot ROM with parameterizable init file
│   │   └── soc_ram.v                 # Byte-wide write-enabled synchronous BRAM
│   ├── periph/
│   │   ├── soc_timer.v               # 64-bit cycle counter & timer match interrupt
│   │   ├── soc_uart.v                # Diagnostic UART transmitter
│   │   └── soc_pwm.v                 # Dual-channel motor PWM with safety disarm gate
│   ├── nna/                          # Neural Network Accelerator (rv_nna)
│   │   ├── nna_top.v                 # Top-level MMIO bus wrapper & decoder
│   │   ├── nna_regs.v                # Control/Status registers and scratchpad buffers
│   │   ├── nna_mac4.v                # 4-way parallel signed INT8 multiplier & adder tree
│   │   └── nna_core.v                # Compute sequencing FSM, accumulator & requantizer
│   ├── safety/                       # Hardware Safety Interlock
│   │   └── safety_filter.v           # Watchdog countdown, token refresh & E-stop interlock
│   └── soc_top.v                     # Top-level synthesizable SoC integration wrapper
├── sw/                               # Software, Firmware & Verification Models
│   ├── model/                        # Bit-exact reference models & test vector generators
│   ├── policy/                       # Synthetic verification policy & weight export
│   ├── safety/                       # Algorithmic deterministic safety supervisor
│   ├── firmware/                     # Bare-metal RISC-V assembly & C HAL headers
│   └── env/                          # (Phase 1) 2D kinematic navigation simulation
├── sim/                              # Icarus Verilog Simulation Testbenches
│   ├── tb_soc_top.v                  # Full SoC boot & diagnostic testbench
│   ├── tb_soc_nav.v                  # Full SoC end-to-end autonomous navigation testbench
│   ├── tb_nna_top.v                  # Neural accelerator register & MAC verification
│   ├── tb_nna_corner_cases.v         # NNA edge cases & signed saturation bounds
│   ├── tb_safety_filter.v            # Safety filter watchdog & heartbeat verification
│   └── tb_safety_adversarial.v       # Adversarial safety, jitter & E-stop race tests
└── syn/                              # FPGA Synthesis Scripts
    └── synth_ecp5.ys                 # Yosys synthesis script for Lattice ECP5
```

---

## 4. Quickstart & Verification

### Running the Full Regression Suite
```bash
# Run all Python reference tests, fuzzing, RTL testbenches & navigation simulation
make all
```

Individual test targets:
```bash
# Run Python INT8 model & 1000-vector fuzzing suite
make test_py

# Run RTL unit and adversarial testbenches
make sim_nna sim_safety sim_nna_corners sim_safety_adv

# Run full end-to-end autonomous navigation simulation (tb_soc_nav)
make sim_nav

# Run real Yosys synthesis check for Lattice ECP5
make synth_check
```

### Verification Test Matrix & Measured Status
| Suite / Testbench | Description | Status |
|---|---|:---:|
| `sw/model/reference_model.py` | Bit-exact Python INT8 MAC & requantization reference | **PASS** |
| `sw/model/fuzz_nna_reference.py` | 1000-vector random fuzzing bit-exact match | **PASS (1000/1000)** |
| `sw/model/test_nna_corners.py` | Python INT8 extreme corner/saturation suite | **PASS (9/9)** |
| `sw/safety/safety_layer.py` | Envelope clamp, slew-rate limiter & TTC braking | **PASS** |
| `sw/policy/nav_policy.py` | Synthetic 16->8->2 obstacle avoidance policy validation | **PASS** |
| `sim/tb_nna_top.v` | NNA MMIO register reads/writes & MAC operations | **PASS** |
| `sim/tb_nna_corner_cases.v` | Hardware RTL INT8 saturation & boundary checks | **PASS (6/6)** |
| `sim/tb_safety_filter.v` | Heartbeat watchdog timer & E-stop trip verification | **PASS** |
| `sim/tb_safety_adversarial.v` | Jitter, timeout, physical E-stop lockout & race checks | **PASS (6/6)** |
| `sim/tb_soc_top.v` | Full SoC integration boot & firmware diagnostic run | **PASS** |
| `sim/tb_soc_nav.v` | End-to-end SoC navigation execution (5 cycles) | **PASS** |
| `scripts/synth_staged.sh` | Staged per-module Yosys `synth_ecp5` (no P&R) | **Per-module COMPLETED; whole SoC INCOMPLETE** |

### FPGA synthesis status (corrected 2026-10-13)
- The earlier README figures (2,686 LUT4 total, 2,130 FFs, 4 DSPs, and a `syn/synth_ecp5.ys` script) are **UNVERIFIED and superseded**. That script never existed in the repository.

- **Update 2026-10-15:** Flat soc_top result (CI run 38706204639, Yosys 0.68+post pinned): 8,753 LUT4, 579 carry cells, 12 MULT18X18D; nextpnr ULX3S 85F: 12,183 of 83,640 logic cells, 2,682 FFs, 38 EBR, 12 MULT; Fmax 32.9-33.0 MHz after routing vs a 25 MHz constraint, 3 seeds (static timing estimate only, no bitstream, no hardware). See docs/28_m8c_pnr_results.md. The old 2,686 LUT4 / 4 DSP / 38 MHz figures are wrong and must not be cited.
- Measured with Yosys 0.68+post (`synth_ecp5 -noabc9`), **each module synthesized separately**: the sum is **7,648 LUT4 and 8 MULT18X18D** with default PicoRV32 parameters (about 9,081 LUT4 with the `soc_top` parameters). This is a sum of separate runs, **not** verified integrated SoC utilization. A whole-SoC synthesis run has not completed.
- No Fmax, timing or power result exists. See `docs/19_synthesis_handoff_and_status.md`.

---

## 5. Documentation Index

Detailed engineering specifications and reports are provided in the `docs/` directory:

| Document | Description |
|---|---|
| [Master Project Roadmap](docs/PROJECT_ROADMAP.md) | Official 6-phase roadmap, dependencies, criteria, and engineering gates |
| [01. System Architecture](docs/01_system_architecture.md) | High-level architecture, subsystem boundaries, dataflow, and bus structure |
| [02. CPU Selection](docs/02_cpu_selection.md) | Technical comparison of 5 open-source RISC-V cores & justification for Ibex / PicoRV32 |
| [03. Memory Map](docs/03_memory_map.md) | System memory map, peripheral address ranges, and register offsets |
| [04. Accelerator Specification](docs/04_accelerator_spec.md) | `rv_nna` datapath, register interface, scratchpad layout, and FSM operation |
| [05. Dataflow & Quantization](docs/05_dataflow_and_quantization.md) | Sensor feature vector normalization, INT8 QAT formulation, and requantization |
| [06. Deterministic Safety Layer](docs/06_deterministic_safety.md) | Multi-stage safety supervisor algorithms, TTC braking, and watchdog design |
| [07. FPGA & Verification Strategy](docs/07_fpga_and_verification.md) | RTL module breakdown, dual-model verification, FPGA targets (ECP5/Artix-7), and risks |
| [08. Decision Log](docs/08_decision_log.md) | Architectural alternatives evaluated and rationales for all design choices |
| [09. Hardware Semantics & Assumptions](docs/09_hardware_semantics_and_assumptions.md) | Formal INT8 representation, accumulator headroom, E-stop latency & timing rules |
| [10. Hardening & Verification Report](docs/10_hardening_report.md) | Engineering Hardening Phase completion report, audit matrices, and bug resolution |
| [11. Measured FPGA Synthesis Report](docs/11_fpga_synthesis_report.md) | Real Yosys synthesis breakdown, cell counts, DSP utilization, and Fmax analysis |
| [12. Readiness & Post-Merge Audit](docs/12_readiness_and_audit_report.md) | Phase 1 readiness assessment, host compute audit, and regression verification |
| [13. Phase 1 RL Training Report](docs/13_phase1_rl_training_report.md) | Pure-NumPy DAgger imitation policy training and 2D unicycle benchmark |
| [14. Phase 2 Quantization Report](docs/14_phase2_quantization_report.md) | INT8 range-aware quantization fidelity analysis and bit-exact RTL verification |
| [15. Phase 3 SoC Firmware Integration](docs/15_phase3_soc_integration_report.md) | Genuine weights in bare-metal RISC-V firmware and end-to-end SoC verification |
| [16. Phase 4 Closed-Loop Co-Sim Report](docs/16_phase4_closed_loop_cosim_report.md) | Multi-step co-simulation coupling 2D physics with cycle-accurate Verilog SoC |
| [Hardening Roadmap](docs/HARDENING_ROADMAP.md) | 100% completed pre-RL engineering hardening checklist |

---

## 6. License & Credits

- Hardware RTL, firmware, simulation testbenches, and documentation are licensed under the Apache License 2.0.
- `picorv32.v` is authored by Claire Wolf and licensed under the ISC License.
