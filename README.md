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
├── docs/                             # Comprehensive Architecture Specifications
│   ├── 01_system_architecture.md     # SoC architecture, subsystem roles & block diagram
│   ├── 02_cpu_selection.md           # Evaluation of RV32 cores & lowRISC Ibex justification
│   ├── 03_memory_map.md              # Address space layout and peripheral allocation
│   ├── 04_accelerator_spec.md        # rv_nna register map, datapath & compute FSM
│   ├── 05_dataflow_and_quantization.md# End-to-end sensor-to-actuator flow & INT8 format
│   ├── 06_deterministic_safety.md    # Multi-stage safety filter algorithms & watchdog
│   ├── 07_fpga_and_verification.md   # RTL breakdown, verification, FPGA targets & risks
│   └── 08_decision_log.md            # Architecture trade-offs and decision log
├── rtl/                              # Hardware RTL Source Files
│   ├── soc_pkg.sv                    # Global parameters, memory map addresses, CSR defs
│   ├── cpu/
│   │   └── picorv32.v                # RV32IM CPU core with Wishbone B4 bus adapter
│   ├── bus/
│   │   └── soc_interconnect.v        # Wishbone B4 address decoder & slave crossbar
│   ├── mem/
│   │   ├── soc_rom.v                 # Synchronous Boot ROM with firmware loader
│   │   └── soc_ram.v                 # Byte-wide write-enabled synchronous SRAM
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
│   ├── Makefile                      # Automated build and test runner
│   ├── tb_nna_top.v                  # RTL testbench for rv_nna accelerator
│   ├── tb_safety_filter.v            # RTL testbench for safety watchdog interlock
│   └── tb_soc_top.v                  # Full SoC system testbench executing ROM firmware
├── sw/                               # Software, Firmware & Modeling Tools
│   ├── model/
│   │   ├── reference_model.py        # Bit-exact golden Python model for INT8 inference
│   │   └── robot_policy_e2e.py       # End-to-end multi-layer robot policy pipeline
│   ├── safety/
│   │   └── safety_layer.py           # Python reference implementation of safety filter
│   └── firmware/
│       ├── assemble.py               # Two-pass RV32IM assembler tool
│       ├── soc_firmware.s            # Bare-metal integration firmware in assembly
│       └── firmware.hex              # Assembled Boot ROM machine code image
├── CHECKPOINT_REPORT.md              # Progress report, test verification, and next steps
└── README.md                         # Project documentation
```

---

## 3. Quickstart & Verification

### Prerequisites
- **Icarus Verilog (`iverilog`)** & **`vvp`** (v11 or later)
- **Python 3.8+**

### Running the Complete Test Suite
To execute the Python reference verification, safety simulation, NNA RTL, safety filter RTL, and full SoC integration simulation:

```bash
cd sim
make test
```

### Test Suite Execution Output
```
--- [1/3] Running INT8 Reference Model Test ---
SUCCESS: Python reference model test passed!

--- [2/3] Running Deterministic Safety Layer Test ---
SUCCESS: All deterministic safety filter tests passed!

--- [3/3] Running End-to-End Robot Policy Pipeline ---
SUCCESS: End-to-End Robot Policy Pipeline Test PASSED!

--- Building and Running NNA Accelerator Testbench ---
SUCCESS: All NNA accelerator tests passed!

--- Building and Running Safety Filter Testbench ---
SUCCESS: Safety filter hardware watchdog tests passed!

--- Building and Running Full SoC System Testbench ---
[UART] S
[UART] o
[UART] C
[UART]
[UART] K
SUCCESS: Robot SoC End-to-End System Test PASSED!
Cycles taken: 523
NNA Inference Result in RAM[0x100]: 0x000000ea (-22)
NNA Execution Latency in RAM[0x104]: 3 cycles
PWM Left Command: 42 (0x002a)
PWM Right Command: 0
Safety Interlock Disarmed: 0 (0 = Armed/Operational)
```

---

## 4. Documentation Index

Detailed specifications covering all architectural aspects are provided in the `/workspace/docs/` directory:

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

---

## 5. License & Credits

- Hardware RTL, firmware, simulation testbenches, and documentation are licensed under the Apache License 2.0.
- `picorv32.v` is authored by Claire Wolf and licensed under the ISC License.
