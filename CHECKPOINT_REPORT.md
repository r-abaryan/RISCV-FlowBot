# RISC-V Mobile Robot SoC - Checkpoint Report

**Date:** October 10, 2026  
**Project Phase:** Phase 1 (Full Architecture Specification, Hardware Prototype, End-to-End Simulation & Verification)  
**Status:** All milestone objectives completed and fully verified with bit-exact simulations.

---

## 1. Current Architecture Summary

The designed SoC architecture is tailored for reinforcement learning (RL) mobile robot control, balancing hardware simplicity, determinism, and open-source FPGA toolchain compatibility.

### 1.1 Key Subsystems
1. **CPU Subsystem:**
   - **Recommended Reference Core:** lowRISC Ibex (2-stage in-order pipeline, RV32IM).
   - **Integrated Prototype Core:** PicoRV32 (RV32IM with Wishbone B4 bus master adapter), ensuring 100% portable Verilog-2001 synthesis across any FPGA toolchain (Yosys/NextPNR, Vivado, Quartus).
   - **Role:** Sensor acquisition (SPI/I2C for IMU, distance sensors, wheel encoders), feature pre-processing, policy invocation, communication, and deterministic safety enforcement.
2. **Neural Accelerator (`rv_nna`):**
   - **Interface:** Standard 32-bit Wishbone B4 memory-mapped register interface at base `0x4000_0000`.
   - **Datapath:** 4-way parallel signed INT8 multiply-accumulate (`nna_mac4`), 32-bit accumulator, bias addition, fixed-point scale factor multiplier, barrel shifter, and activation saturation unit.
   - **Scratchpads:** 128 B input activation buffer, 256 B (64x32-bit) bias buffer, 1024 B weight buffer, 128 B output buffer.
   - **Throughput:** 4 INT8 MACs per cycle (80 MOPS at 20 MHz, 200 MOPS at 50 MHz).
3. **Deterministic Safety Architecture:**
   - **Software Supervisor:** Runs on RISC-V in the real-time control loop. Implements physical boundary clamps, slew-rate dynamic acceleration limiters, and time-to-collision (TTC) obstacle braking.
   - **Hardware Safety Filter (`safety_filter`):** Dedicated MMIO watchdog at `0x5000_0600`. Enforces heartbeat token refreshes within a programmed cycle deadline and directly gates motor PWM drivers via an independent hardware disarm/E-Stop interlock.
4. **Peripherals & Memory:**
   - 8 KB Boot ROM (`0x0000_0000`), 16 KB/64 KB Main SRAM (`0x2000_0000`), SoC Timer with 64-bit cycle counter (`0x5000_0000`), Diagnostic UART TX (`0x5000_0100`), Dual-channel Motor PWM Generator (`0x5000_0200`).
   - Central address decoding crossbar interconnect (`soc_interconnect.v`).

---

## 2. Documented Assumptions

1. **Policy Architecture:** The mobile robot RL policy is a standard 2-to-3 layer Multi-Layer Perceptron (MLP) with observation sizes between 8 and 32 elements (distance sensors, IMU linear acceleration and angular velocity, odometry, target coordinates) and action output sizes between 2 and 4 elements (e.g., differential drive $v, \omega$).
2. **Quantization Precision:** INT8 symmetric quantization ($Z = 0$) for both weights and activations is assumed sufficient for low-dimensional robotic control policies when trained with Quantization-Aware Training (QAT).
3. **Control Frequency:** The robot real-time control loop runs between 200 Hz and 1,000 Hz (1 ms to 5 ms period). A single inference layer takes 3–15 microseconds, leaving > 95% of the CPU cycle budget available for sensor polling, odometry filtering, and deterministic safety checks.
4. **Interconnect Simplicity:** Single-master Wishbone B4 interconnect avoids complex arbitration overhead while preserving standard handshake semantics.

---

## 3. Unresolved Questions & Hardware Uncertainties

1. **FPGA Resource Synthesis Variation:**
   - *Uncertainty:* While area estimations (~3,200–4,500 LUTs, 3–6 DSPs) are grounded in established open-source benchmarks for Ibex/PicoRV32 and standard multiplier trees, final resource count depends on target FPGA family (Lattice ECP5 vs. Xilinx Artix-7), DSP block inference rules in Yosys/Vivado, and whether dual-port scratchpads infer distributed LUT RAM or dedicated block RAM (EBR/BRAM).
   - *Status:* Validated functionally in gate-level and behavioral simulation; concrete bitstream generation on physical boards planned for Phase 2.
2. **Weight Memory Scaling for Deeper Policies:**
   - *Uncertainty:* The initial scratchpad weight buffer is 1 KB (1,024 weights). While sufficient for layers up to $32 \times 32$ or $64 \times 16$, policies requiring larger hidden layers (e.g., 64x64 = 4,096 weights) will require either multi-pass layer execution with CPU weight streaming or a light autonomous DMA controller.
   - *Status:* Identified as a planned Phase 2 optimization.
3. **Sensor Peripheral Bus Latency:**
   - *Uncertainty:* Polling external I2C/SPI sensors synchronously on the main bus could introduce jitter into the real-time control period unless hardware FIFOs or timer-triggered interrupts are employed.
   - *Status:* Peripheral interrupt architecture will be specified in the firmware driver layer.

---

## 4. Artifacts Produced

The following comprehensive design and implementation artifacts have been created in `/workspace`:

### Documentation (`/workspace/docs/`)
- `01_system_architecture.md`: Full SoC architecture, subsystem breakdown, bus interconnect, and block diagram.
- `02_cpu_selection.md`: Technical evaluation of 5 candidate RISC-V cores and justification for lowRISC Ibex / PicoRV32.
- `03_memory_map.md`: Complete 32-bit system memory map, peripheral allocation, and reservation spaces.
- `04_accelerator_spec.md`: Detailed `rv_nna` specification, datapath, CSR map, scratchpad organization, and FSM.
- `05_dataflow_and_quantization.md`: End-to-end data flow pipeline, INT8 symmetric quantization equations, and conversion formulas.
- `06_deterministic_safety.md`: Multi-layer safety architecture, kinematic & slew-rate limiter algorithms, TTC braking, and hardware watchdog design.
- `07_fpga_and_verification.md`: RTL breakdown, dual-model verification plan, FPGA targets (ECP5, Artix-7, iCE40), resource estimates, and risk analysis.
- `08_decision_log.md`: Architectural decision log with alternatives considered and rationales.

### Hardware RTL Source (`/workspace/rtl/`)
- `soc_pkg.sv`: Global parameters, memory map addresses, and register bitfield constants.
- `cpu/picorv32.v`: Fully integrated RV32IM CPU core with Wishbone B4 adapter.
- `bus/soc_interconnect.v`: Full memory map crossbar interconnect and slave address decoder.
- `mem/soc_rom.v`: Synchronous boot ROM module with hex loader.
- `mem/soc_ram.v`: Byte-wide write-enabled synchronous SRAM memory controller.
- `periph/soc_timer.v`: 64-bit real-time cycle counter and timer comparator with interrupt.
- `periph/soc_uart.v`: Simple UART transmitter peripheral.
- `periph/soc_pwm.v`: Dual-channel hardware motor PWM generator with safety disarm clamp.
- `nna/nna_mac4.v`: 4-way parallel signed INT8 multiplier with 4-input adder tree.
- `nna/nna_regs.v`: Memory-mapped control/status registers, configuration registers, and dual-port scratchpad memories.
- `nna/nna_core.v`: Compute sequencing FSM, 32-bit accumulator, bias adder, requantization pipeline, and saturation.
- `nna/nna_top.v`: Top-level Wishbone wrapper for the neural accelerator.
- `safety/safety_filter.v`: Hardware heartbeat watchdog timer, status registers, and motor disarm interlock.
- `soc_top.v`: Complete SoC top-level integrating CPU, bus, memory, NNA, safety filter, timer, UART, and PWM.

### Reference Software & Tooling (`/workspace/sw/`)
- `model/reference_model.py`: Bit-exact golden Python model for INT8 matrix-vector inference.
- `safety/safety_layer.py`: Python reference implementation of deterministic safety filter.
- `model/robot_policy_e2e.py`: End-to-end multi-layer RL policy pipeline connecting sensors, MLP inference, safety bounds, and motor output.
- `firmware/assemble.py`: Two-pass RISC-V RV32IM assembler tool generating memory initialization hex files.
- `firmware/soc_firmware.s`: Bare-metal assembly firmware testing CPU, NNA, Safety watchdog, UART banner, and motor PWM.
- `firmware/firmware.hex`: Assembled boot ROM binary image.

### Verification Testbenches (`/workspace/sim/`)
- `tb_nna_top.v`: RTL testbench verifying register accesses, scratchpad R/W, multi-neuron inference, and latency.
- `tb_safety_filter.v`: RTL testbench verifying heartbeat feeding, watchdog timeout disarm, external E-Stop trigger, and re-arming.
- `tb_soc_top.v`: Full-system RTL testbench running firmware from Boot ROM through the CPU, NNA accelerator, safety filter, and PWM motor outputs.
- `Makefile`: Automated verification target executing all software and RTL testbenches (`make test`).

---

## 5. Verification Results

| Test Suite | Target | Pass/Fail | Notes |
|---|---|---|---|
| Python Reference Model | `reference_model.py` | **PASS** | Validates bit-exact INT8 GEMV, bias, scale/shift requantization, and ReLU/saturation against synthetic and randomized tensors. |
| Python Safety Filter | `safety_layer.py` | **PASS** | Validates kinematic envelope limits, acceleration slew limits, TTC obstacle braking, and watchdog expiration disarm. |
| End-to-End Pipeline | `robot_policy_e2e.py` | **PASS** | Validates 16->8->2 multi-layer policy with obstacle proximity scenarios and safety clamp interventions. |
| RTL NNA Accelerator | `tb_nna_top.v` | **PASS** | Validates Wishbone register access, dual-port scratchpad writes, 4-way SIMD MAC execution, and bit-exact output matching reference model. |
| RTL Safety Interlock | `tb_safety_filter.v` | **PASS** | Validates watchdog cycle countdown, motor disarm trip on missed heartbeat, external E-Stop override, and controlled software re-arming. |
| Full SoC System Integration | `tb_soc_top.v` | **PASS** | PicoRV32 boots from ROM, sends UART banner (`SoC\nK`), loads NNA scratchpad, executes inference, reads result (`0xea` = -22), computes safe clamped PWM output (`42`), and marks completion (`0xCAFEBABE` in RAM) in 523 cycles. |

---

## 6. Next Planned Steps

1. **Ibex SystemVerilog Integration:** Add an alternative SystemVerilog Ibex CPU build configuration alongside the Verilog PicoRV32 baseline.
2. **QAT Robotics Policy Training:** Train a 2-layer mobile robot obstacle avoidance policy in PyTorch with quantization-aware training and export weights to C header format.
3. **FPGA Board Synthesis:** Create Yosys + NextPNR build scripts targeting Lattice ECP5 (e.g., Colorlight i5/OrangeCrab) and Xilinx Vivado scripts for Digilent Arty A7.
