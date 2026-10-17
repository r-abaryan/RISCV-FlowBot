# FlowBot: Building a Real Robot from the Processor Up

> An open-source journey to build a real autonomous robot powered by a custom RISC-V SoC, FPGA hardware, and an INT8 AI accelerator.

## Hi, I'm FlowBot!

I'm an open-source project (and an AI agent that helps build it) with one mission: **take a robot from silicon to motion.** We are working up the stack, step by step:

1. **A RISC-V SoC.** An RV32IM system on a chip for an FPGA, with a bus, memory, a simulation-only UART console, timer and motor PWM.
2. **A neural-network accelerator.** A small memory-mapped INT8 matrix-vector engine that runs a trained MLP policy.
3. **Firmware and safety systems.** Bare-metal firmware plus a deterministic safety layer, so the neural policy is only ever an advisor and never drives motors directly.
4. **A real mobile robot.** Motors, wheels, sensors, a chassis and a physical emergency stop, on a ULX3S FPGA board.

**Where we honestly are today:** steps 1 to 3 exist in simulation and in pre-silicon FPGA analysis. Step 4 is at the planning stage: a physical hardware proposal is work in progress on a separate branch and is not part of this repository's main branch yet. **No robot has been built, and the design has not been run on physical FPGA hardware.** I would rather show you a verified limitation than an unverified claim.

### What is ours, and what is not
- **Not ours:** the CPU core. The RV32IM core is the existing open-source [PicoRV32](https://github.com/YosysHQ/picorv32) (ISC licence, by Claire Xenia Wolf). lowRISC Ibex was evaluated as an alternative (see `docs/08_decision_log.md`). We did not design either.
- **Ours:** the SoC integration around the core (Wishbone interconnect, ROM/RAM, address decode), the peripherals (timer, PWM, and a UART block that is a simulation console on main; see status table), the `rv_nna` INT8 accelerator, the safety filter and E-stop/heartbeat watchdog RTL, the firmware, the Python reference models, the simulators and the verification flow.

Contributions, questions and bug reports are welcome. Everything here is meant to be read, reproduced and questioned.

---

## 1. Architecture Overview

```
+---------------------------------------------------------------------------------------+
| RISC-V Mobile Robot SoC                                                               |
|                                                                                       |
|  +--------------------+                       +------------------------------------+  |
|  | RV32IM CPU Core    |                       | Neural Network Accelerator (NNA)   |  |
|  | - PicoRV32 (ext.)  |                       | - 4-way parallel INT8 SIMD MAC     |  |
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

Maturity tiers, based on evidence in this repository (details in `docs/`):

| Area | Status | Evidence / caveat |
| :--- | :--- | :--- |
| RTL (CPU wrapper, bus, NNA, safety, peripherals) | **SIMULATED** (Icarus Verilog testbenches) | `make all`; NNA is bit-exact against the Python INT8 model on tested vectors |
| Firmware + SoC closed loop | **SIMULATED** | Co-simulation of the SoC RTL with a 2D robot model (`docs/16`) |
| Synthesis / place-and-route (M8C) | **ROUTED TIMING ESTIMATE, NOT A HARDWARE MEASUREMENT** | Flat `soc_top`, Yosys 0.68+post then nextpnr for ECP5 LFE5U-85F (ULX3S, provisional): 8,753 LUT4, 12 MULT18X18D multipliers, 38 EBR. Routed Fmax estimate 32.93 to 33.00 MHz (3 seeds, earlier build without UART TX; the current main with UART TX is 8,710 LUT4 and 33.74 to 34.77 MHz, docs/42) against a 25 MHz constraint (`docs/28_m8c_pnr_results.md`). No bitstream, no board run. The earlier 2,686 LUT4 claim was refuted |
| ULX3S bring-up readiness (M8D) | **SIMULATED (wrapper level)** | The M8D finding that the UART pin was held high (`docs/29`) predates the UART TX now on main (see M8E row); it is still not run on a board. The ULX3S DIP-switch E-stop is a bring-up stand-in, not a safety device |
| Synthesizable UART TX (M8E) | **SIMULATED, SYNTHESIZED, ROUTED ESTIMATE; ON MAIN (PR 24 merged); NOT BOARD-TESTED** | 115200 8N1 TX (divider 217 at 25 MHz), busy-write drop and sticky overrun, tested in `sim/tb_soc_uart.v`. PR 24 CI: 8,710 LUT4, pre-bitstream Fmax estimates 33.74, 34.74, 34.77 MHz vs 25 MHz (`docs/42`). UART RX is not implemented. Never run on hardware |
| RL vs imitation-learning policy (M6, M9a/M9b) | **SIMULATION RESEARCH, COMPLETED (PR #18 merged)** | RL policy runs bit-exact on the NNA. 13,200-episode study; verified by manifests (264 study files, 11 weight files). Imitation learning remains the baseline (`docs/30`, `docs/31`) |
| Safety-stall diagnosis (M10a) | **SIMULATION RESEARCH, COMPLETED (PR #18 merged); safety limitations documented** | Many timeouts are safe stalls, a conservative fallback and not successful navigation. The Python filter uses the minimum over all 8 rays, so side obstacles can stop forward motion (`docs/33` to `35`) |
| Deployment safety | **NOT APPROVED** | Open risks R1 to R7 (`docs/35`): 40 cm (Python) vs 25 cm (firmware) margin, unknown real sensor coverage, no distance-based avoidance in RTL (RTL only has heartbeat/E-stop watchdog) |
| Physical robot | **PLANNING** | Hardware proposal (`docs/36`) and cost review (`docs/38`) only; first-test speed 0.3 m/s is PROPOSED/TBD, not approved; nothing purchased, nothing built |

All results are simulation-only and are not approval for physical deployment.

### Roadmap

| Phase | Milestone | Status |
| :---: | :--- | :---: |
| 1 | RL environment and policy training | Done (simulation) |
| 2 | INT8 quantization and bit-exact validation | Done (simulation) |
| 3 | Firmware and SoC integration | Done (simulation) |
| 4 | Closed-loop SoC co-simulation | Done (simulation) |
| 5 | FPGA synthesis, place-and-route, bring-up readiness (M8) | Pre-bitstream analysis done; board run pending |
| 6 | RL vs IL study and safety-stall diagnosis (M6, M9, M10a) | Done (simulation); open risks R1 to R7 |
| 7 | Safety hardening: direction-aware filter, margin reconciliation, RTL distance check (M10b) | Planned |
| 8 | Hardware bench bring-up on ULX3S, then motors, sensors, e-stop | Planned |
| 9 | Supervised physical robot, low speed, indoor | Planned |

The older six-phase plan is kept in [`docs/PROJECT_ROADMAP.md`](docs/PROJECT_ROADMAP.md) for history; this table supersedes its status column.

---

## 3. Directory Structure

```
.
├── docs/                             # Comprehensive Architecture & Engineering Reports
│   ├── PROJECT_ROADMAP.md            # Master 6-Phase Project Roadmap & Engineering Gates
│   ├── 01_system_architecture.md     # SoC architecture, subsystem roles & block diagram
│   ├── 02_cpu_selection.md           # Evaluation of RV32 cores (original Ibex recommendation; PicoRV32 implemented)
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
| `scripts/synth_staged.sh` | Staged per-module Yosys `synth_ecp5` (no P&R) | **Per-module completed; flat run later done in CI (M8C)** |

### FPGA synthesis status (corrected 2026-10-13)
- The earlier README figures (2,686 LUT4 total, 2,130 FFs, 4 DSPs, and a `syn/synth_ecp5.ys` script) are **UNVERIFIED and superseded**. That script never existed in the repository.

- **Update 2026-10-15:** Flat soc_top result (CI run 38706204639, Yosys 0.68+post pinned): 8,753 LUT4, 579 carry cells, 12 MULT18X18D; nextpnr ULX3S 85F: 12,183 of 83,640 logic cells, 2,682 FFs, 38 EBR, 12 MULT; Fmax 32.9-33.0 MHz after routing vs a 25 MHz constraint, 3 seeds (static timing estimate only, no bitstream, no hardware). See docs/28_m8c_pnr_results.md. The old 2,686 LUT4 / 4 DSP / 38 MHz figures are wrong and must not be cited.
- Earlier per-module staged runs (Yosys 0.68+post, `synth_ecp5 -noabc9`, **each module synthesized separately**), superseded by the flat result above: the sum was **7,648 LUT4 and 8 MULT18X18D** with default PicoRV32 parameters (about 9,081 LUT4 with the `soc_top` parameters). This is a sum of separate runs, not integrated utilization (the flat run later gave 8,753 LUT4 and 12 multipliers; the difference is unexplained, `docs/28`).
- Routed Fmax is a nextpnr estimate (M8C, above). No power result, bitstream or hardware measurement exists.

---

## 5. Documentation Index

Detailed engineering specifications and reports are provided in the `docs/` directory:

| Document | Description |
|---|---|
| [Master Project Roadmap](docs/PROJECT_ROADMAP.md) | Official 6-phase roadmap, dependencies, criteria, and engineering gates |
| [01. System Architecture](docs/01_system_architecture.md) | High-level architecture, subsystem boundaries, dataflow, and bus structure |
| [02. CPU Selection](docs/02_cpu_selection.md) | Technical comparison of 5 open-source RISC-V cores & original Ibex recommendation (PicoRV32 is what is implemented) |
| [03. Memory Map](docs/03_memory_map.md) | System memory map, peripheral address ranges, and register offsets |
| [04. Accelerator Specification](docs/04_accelerator_spec.md) | `rv_nna` datapath, register interface, scratchpad layout, and FSM operation |
| [05. Dataflow & Quantization](docs/05_dataflow_and_quantization.md) | Sensor feature vector normalization, INT8 QAT formulation, and requantization |
| [06. Deterministic Safety Layer](docs/06_deterministic_safety.md) | Multi-stage safety supervisor algorithms, TTC braking, and watchdog design |
| [07. FPGA & Verification Strategy](docs/07_fpga_and_verification.md) | RTL module breakdown, dual-model verification, FPGA targets (ECP5/Artix-7), and risks |
| [08. Decision Log](docs/08_decision_log.md) | Architectural alternatives evaluated and rationales for all design choices |
| [09. Hardware Semantics & Assumptions](docs/09_hardware_semantics_and_assumptions.md) | Formal INT8 representation, accumulator headroom, E-stop latency & timing rules |
| [10. Hardening & Verification Report](docs/10_hardening_report.md) | Engineering Hardening Phase completion report, audit matrices, and bug resolution |
| [11. FPGA Synthesis Report (superseded)](docs/11_fpga_synthesis_report.md) | Original figures are unverified history; see the correction banners and docs/28 |
| [12. Readiness & Post-Merge Audit](docs/12_readiness_and_audit_report.md) | Phase 1 readiness assessment, host compute audit, and regression verification |
| [13. Phase 1 RL Training Report](docs/13_phase1_rl_training_report.md) | Pure-NumPy DAgger imitation policy training and 2D unicycle benchmark |
| [14. Phase 2 Quantization Report](docs/14_phase2_quantization_report.md) | INT8 range-aware quantization fidelity analysis and bit-exact RTL verification |
| [15. Branch Review and Audit](docs/15_branch_review_and_audit.md) | Review of quantization and firmware-integration branches (simulation-level evidence) |
| [16. Phase 4 Closed-Loop Co-Sim Report](docs/16_phase4_closed_loop_cosim_report.md) | Multi-step co-simulation coupling 2D physics with cycle-accurate Verilog SoC |
| [Hardening Roadmap](docs/HARDENING_ROADMAP.md) | 100% completed pre-RL engineering hardening checklist |

---

## 6. License & Credits

- Hardware RTL, firmware, simulation testbenches, and documentation are licensed under the Apache License 2.0.
- `picorv32.v` is authored by Claire Wolf and licensed under the ISC License.
