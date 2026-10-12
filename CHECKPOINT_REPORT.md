# RISC-V Mobile Robot SoC - Checkpoint Report

**Date:** October 12, 2026  
**Project Phase:** Phase 3 & Engineering Hardening Phase Complete (Full Architecture Specification, Hardware Implementation, Bit-Exact End-to-End Navigation, and Hardened Synthesis/Verification)  
**Status:** All milestone objectives completed, hardened, and verified with zero errors across all software and RTL testbenches.

---

## 1. Current Architecture Summary

The designed SoC architecture is tailored for reinforcement learning (RL) mobile robot control, balancing hardware simplicity, determinism, and open-source FPGA toolchain compatibility.

### 1.1 Key Subsystems
1. **CPU Subsystem:**
   - **Integrated Baseline Core:** PicoRV32 (RV32IM with Wishbone B4 bus master adapter), ensuring 100% portable Verilog-2001 synthesis across any FPGA toolchain (Yosys/NextPNR, Vivado, Quartus).
   - **Recommended Upgrade Path:** lowRISC Ibex (2-stage in-order pipeline, RV32IM, SystemVerilog).
   - **Role:** Sensor acquisition (IMU, distance sensors, wheel encoders), feature pre-processing, policy invocation, communication, and deterministic safety enforcement.
2. **Neural Accelerator (`rv_nna`):**
   - **Interface:** Standard 32-bit Wishbone B4 memory-mapped register interface at base `0x5000_0400` / `0x4000_0000`.
   - **Datapath:** 4-way parallel signed INT8 multiply-accumulate (`nna_mac4`), 32-bit accumulator, bias addition, fixed-point scale factor multiplier, barrel shifter, and activation saturation unit.
   - **Scratchpads:** 128 B input activation buffer, 256 B (64x32-bit) bias buffer, 1024 B weight buffer, 128 B output buffer.
   - **Throughput:** 4 INT8 MACs per cycle (80 MOPS at 20 MHz, 200 MOPS at 50 MHz).
3. **Deterministic Safety Architecture:**
   - **Software Supervisor:** Runs on RISC-V in the real-time control loop. Implements physical boundary clamps, slew-rate dynamic acceleration limiters, and time-to-collision (TTC) obstacle braking.
   - **Hardware Safety Filter (`safety_filter`):** Dedicated MMIO watchdog at `0x5000_0600`. Enforces heartbeat token refreshes within a programmed cycle deadline and directly gates motor PWM drivers via an independent hardware disarm/E-Stop interlock. Hardened against physical E-stop re-arm race conditions.
4. **Peripherals & Memory:**
   - 8 KB Boot ROM (`0x0000_0000`), 16 KB/64 KB Main SRAM (`0x2000_0000`), SoC Timer with 64-bit cycle counter (`0x5000_0000`), Diagnostic UART TX (`0x5000_0100`), Dual-channel Motor PWM Generator (`0x5000_0200`).
   - Central address decoding crossbar interconnect (`soc_interconnect.v`).

---

## 2. Documented Assumptions & Hardening Audits

1. **Policy Architecture:** The mobile robot RL policy is a standard 2-layer Multi-Layer Perceptron (MLP) with observation sizes of 16 features (distance sensors, linear velocity, angular velocity, target heading, target distance) and action output size of 2 (linear velocity $v$, angular velocity $\omega$).
2. **Quantization Precision:** INT8 symmetric quantization ($Z = 0$) for both weights and activations is used. Formal bounds and saturation semantics ($[-128, +127]$ for linear/clip, $[0, +127]$ for ReLU) are strictly verified without arithmetic wrap-around.
3. **Accumulator Headroom:** A signed 32-bit accumulator provides 11 bits of mathematical headroom for 64-input dot products, guaranteeing zero overflow for valid trained weights. Requantization uses a 49-bit intermediate multiplier product before arithmetic right shifting.
4. **Control Frequency & Latency:** The robot real-time control loop runs between 200 Hz and 1,000 Hz. A full 2-layer inference (16->8->2) executes in ~200 accelerator cycles (< 5 microseconds at 50 MHz), utilizing < 0.5% of the control cycle budget.
5. **Deterministic Hardware Interlock:** Physical E-stop actuation asserts within $T_{pd} < 10\text{ ns}$ via asynchronous gating, latching a hardware trip state that cannot be cleared by software while physical E-stop remains asserted.

---

## 3. Measured FPGA Synthesis & Resource Metrics

Synthesized using **Yosys Open Synthesis Suite (v0.68)** targeting **Lattice ECP5** (`LFE5U-25F-6BG381C`):

| Module / Subsystem | LUT4 Count | Registers (DFF) | DSPs (`MULT18X18D`) | BRAMs | Notes |
|---|---|---|---|---|---|
| `picorv32` (RV32IM CPU) | 1,588 | 586 | 0 | 0 | Multiplier synthesized using logic slices |
| `rv_nna` (Neural Accelerator) | 494 | 224 | 4 | 0 | Dedicated 4-way parallel SIMD MACs |
| `safety_filter` (Interlock) | 112 | 84 | 0 | 0 | Heartbeat timer & latch logic |
| `soc_interconnect` (Bus Crossbar) | 210 | 0 | 0 | 0 | Combinational multiplexing |
| Peripherals (Timer, UART, PWM) | 268 | 272 | 0 | 0 | Real-time cycle counter, UART TX, PWM |
| **Total SoC System** | **2,686** | **1,180** | **4** | **0** | **~11.2% LUT utilization on ECP5-25F** |

**Estimated Fmax:** 45 – 55 MHz (Lattice ECP5 speed grade -6).

---

## 4. Verification Results & Test Matrix

| Test Suite / Target | Description | Result | Details |
|---|---|:---:|---|
| `sw/model/reference_model.py` | Python bit-exact golden INT8 GEMV model | **PASS** | Validated against edge-case and random test vectors. |
| `sw/test/test_nna_corners.py` | 1000-vector random fuzzing & boundary test suite | **PASS** | 58/58 test groups passed with zero divergence. |
| `sw/safety/safety_layer.py` | Python deterministic safety supervisor reference | **PASS** | Validated envelope clamp, slew limits, and TTC braking. |
| `sw/policy/nav_policy.py` | Python 16->8->2 obstacle avoidance policy | **PASS** | Validated open-field, left-steer, right-steer, and emergency stop. |
| `sim/tb_nna_top.v` | NNA MMIO registers & basic inference testbench | **PASS** | Scratchpad R/W, CSR handshakes, and SIMD MAC execution. |
| `sim/tb_nna_corner_cases.v` | RTL INT8 saturation & negative-zero corner testbench | **PASS** | Max positive, max negative, and boundary saturation verified. |
| `sim/tb_safety.v` | Hardware safety filter baseline testbench | **PASS** | Heartbeat watchdog countdown and disarm latch verified. |
| `sim/tb_safety_adversarial.v` | Adversarial safety testbench | **PASS** | 6 adversarial scenarios passed (watchdog timeout, jitter, E-stop lockout, race condition). |
| `sim/tb_soc_top.v` | Full SoC system boot and diagnostic testbench | **PASS** | ROM boot, UART output, NNA execution, and PWM drive in 523 cycles. |
| `sim/tb_soc_nav.v` | End-to-end SoC autonomous robot navigation testbench | **PASS** | 5 autonomous navigation cycles, 16->8->2 MLP inference, obstacle braking, and PWM output verified. |

---

## 5. Artifacts Produced & Maintained

### Documentation (`docs/`)
- `01_system_architecture.md`: High-level architecture and bus structure.
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
- `HARDENING_ROADMAP.md`: Completed hardening audit checklist.

### Hardware RTL (`rtl/`)
- Full synthesizable Verilog modules: `soc_pkg.sv`, `picorv32.v`, `soc_interconnect.v`, `soc_rom.v`, `soc_ram.v`, `soc_timer.v`, `soc_uart.v`, `soc_pwm.v`, `nna_top.v`, `nna_regs.v`, `nna_mac4.v`, `nna_core.v`, `safety_filter.v`, `soc_top.v`.

### Software & Firmware (`sw/`)
- Golden models, policy implementations, 1000-vector fuzzers, C HAL headers, two-pass assembler, and navigation firmware.

---

## 6. Next Steps

1. **Hardware In-the-Loop (HIL) Deployment:** Connect physical ECP5 evaluation board (e.g., Colorlight i5 or OrangeCrab) via JTAG/OpenFPGALoader to evaluate real PWM signals on an oscilloscope.
2. **PyTorch QAT Export Pipeline:** Build an automated export script that converts trained PyTorch/ONNX reinforcement learning policies directly into `nav_weights.h` and assembly data tables.
3. **Ibex SystemVerilog Alternative Build:** Provide a dual-core configuration option allowing users to toggle between PicoRV32 (Verilog-2001) and lowRISC Ibex (SystemVerilog) via build flags.
