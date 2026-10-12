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
2. **Memory-Mapped Neural Accelerator (`rv_nna`):** Accelerates dense matrix-vector multiplications ($Y = W \cdot X + B$) with per-layer fixed-point requantization and activations. Decoupled via MMIO to allow standard GCC toolchains without compiler patches.
3. **Deterministic Safety Supervisor:** The neural policy is treated as an *unverified advisor*. Its velocity proposals must pass through envelope bounding, dynamic slew-rate acceleration limiters, and time-to-collision (TTC) braking before reaching motor drivers. A hardware watchdog automatically disarms motors if software fails.

---

## 2. Directory Structure

```
.
├── docs/                             # Comprehensive Architecture & Engineering Reports
│   ├── 01_system_architecture.md     # SoC architecture, subsystem roles & block diagram
│   ├── 02_cpu_selection.md           # Evaluation of RV32 cores & lowRISC Ibex justification
│   ├── 03_memory_map.md              # Address space layout and peripheral allocation
│   ├── 04_accelerator_spec.md        # rv_nna register map, datapath & compute FSM
│   ├── 05_dataflow_and_quantization.md# End-to-end sensor-to-actuator flow & INT8 format
│   ├── 06_deterministic_safety.md    # Multi-stage safety supervisor algorithms & watchdog
│   ├── 07_fpga_and_verification.md   # RTL breakdown, verification, FPGA targets & risks
│   ├── 08_decision_log.md            # Architecture trade-offs and decision log
│   ├── 09_hardware_semantics_and_assumptions.md # Numerical invariants & hardware semantics
│   ├── 10_hardening_report.md        # Comprehensive hardening, corner tests & audit report
│   ├── 11_fpga_synthesis_report.md   # Measured Yosys Lattice ECP5 synthesis metrics
│   └── HARDENING_ROADMAP.md          # 100% complete engineering hardening checklist
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
│   │   └── safety_filter.v           # Heartbeat timer watchdog & E-stop actuator disarm
│   └── soc_top.v                     # Complete SoC integration top-level
├── sim/                              # Simulation and Verification Testbenches
│   ├── Makefile                      # Automated test runner with non-zero exit codes
│   ├── tb_nna_top.v                  # RTL testbench for rv_nna accelerator registers
│   ├── tb_nna_corner_cases.v         # Hardened INT8 saturation & corner-case testbench
│   ├── tb_safety.v                   # Baseline watchdog & E-stop interlock testbench
│   ├── tb_safety_adversarial.v       # Hardened adversarial safety stress & race testbench
│   ├── tb_soc_top.v                  # Full SoC system testbench (PicoRV32 + firmware)
│   └── tb_soc_nav.v                  # End-to-end 16->8->2 navigation simulation
├── sw/                               # Software, Drivers, Models, and Firmware
│   ├── hal/
│   │   ├── soc_regs.h                # C hardware peripheral register headers
│   │   └── robot_drivers.h           # Device drivers for NNA, PWM, UART, and Safety
│   ├── model/
│   │   ├── reference_model.py        # Bit-exact golden Python model for INT8 inference
│   │   └── robot_policy_e2e.py       # End-to-end multi-layer robot policy pipeline
│   ├── policy/
│   │   └── nav_policy.py             # 16->8->2 RL obstacle avoidance policy
│   ├── safety/
│   │   └── safety_layer.py           # Python reference implementation of safety filter
│   ├── test/
│   │   └── test_nna_corners.py       # 1000-vector INT8 corner fuzzing test suite
│   └── firmware/
│       ├── assemble.py               # Two-pass RV32IM assembler tool
│       ├── soc_firmware.s            # Baseline boot & hardware diagnostic firmware
│       ├── firmware.hex              # Assembled Boot ROM machine code image
│       ├── robot_nav_firmware.s      # Complete autonomous robot navigation firmware
│       └── robot_nav.hex             # Assembled navigation policy ROM image
├── CHECKPOINT_REPORT.md              # Engineering checkpoint report
├── Makefile                          # Top-level project build & test orchestration
└── README.md                         # Project documentation
```

---

## 3. Quickstart & Verification

### Prerequisites
- **Icarus Verilog (`iverilog`)** & **`vvp`** (v11 or later)
- **Python 3.8+**
- **Yosys** (optional, for FPGA synthesis verification)

### Running Tests
Execute the comprehensive verification test suite:

```bash
# Run baseline test suite (Python golden models + RTL units + SoC top)
make test

# Run 1000-vector INT8 corner-case fuzzing and RTL saturation tests
make corner_test

# Run full end-to-end autonomous navigation simulation (tb_soc_nav)
make sim_nav

# Run real Yosys synthesis check for Lattice ECP5
make synth_check
```

### Verification Test Matrix & Measured Status
| Suite / Testbench | Description | Status |
|---|---|:---:|
| `sw/model/reference_model.py` | Bit-exact Python INT8 MAC & requantization reference | **PASS** |
| `sw/test/test_nna_corners.py` | 1000-vector random fuzzing + boundary corner cases | **PASS (58/58)** |
| `sw/safety/safety_layer.py` | Envelope clamp, slew-rate limiter & TTC braking | **PASS** |
| `sw/policy/nav_policy.py` | 16->8->2 obstacle avoidance policy validation | **PASS** |
| `sim/tb_nna_top.v` | NNA MMIO register reads/writes & MAC operations | **PASS** |
| `sim/tb_nna_corner_cases.v` | Hardware RTL INT8 saturation & negative zero check | **PASS (6/6)** |
| `sim/tb_safety.v` | Heartbeat watchdog timer & E-stop trip verification | **PASS** |
| `sim/tb_safety_adversarial.v` | Jitter, timeout, physical E-stop lockout & race checks | **PASS (6/6)** |
| `sim/tb_soc_top.v` | Full SoC integration boot & firmware diagnostic run | **PASS** |
| `sim/tb_soc_nav.v` | End-to-end SoC navigation execution (5 cycles) | **PASS** |
| `synth/synth_ecp5.ys` | Yosys synthesis targeting Lattice LFE5U-25F-6BG381C | **PASS** |

### Measured FPGA Synthesis Metrics (Lattice ECP5)
Synthesized with **Yosys Open Synthesis Suite (v0.68)**:
- **Total Logic Cells (LUT4):** 2,686 LUTs
  - `picorv32` RV32IM CPU: 1,588 LUTs (59.1%)
  - `rv_nna` INT8 Accelerator: 494 LUTs (18.4%)
  - `safety_filter` Hardware Interlock: 112 LUTs (4.2%)
  - Interconnect & Peripherals (ROM, RAM, UART, Timer, PWM): 492 LUTs (18.3%)
- **Registers (DFF):** 1,180 D-flip-flops
- **DSP Multipliers:** 4x `MULT18X18D` blocks (dedicated 4-way parallel SIMD MACs in `nna_mac4.v`)
- **Memory:** Synthesizable synchronous distributed/block RAM architecture

---

## 4. Documentation Index

Detailed engineering specifications and reports are provided in the `docs/` directory:

| Document | Description |
|---|---|
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
| [Hardening Roadmap](docs/HARDENING_ROADMAP.md) | 100% completed engineering hardening checklist and audit verification |

---

## 5. License & Credits

- Hardware RTL, firmware, simulation testbenches, and documentation are licensed under the Apache License 2.0.
- `picorv32.v` is authored by Claire Wolf and licensed under the ISC License.
