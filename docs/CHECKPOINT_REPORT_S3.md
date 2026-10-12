# [ARCHIVED / RESOLVED] Checkpoint Report: RISC-V Robot Navigation SoC (Pre-RL Prototype Integration Note)

> **ARCHIVE NOTICE:** This document is an intermediate engineering log from pre-RL prototype debugging on October 11, 2026. The halt point described in Section 3 below was diagnosed and **completely resolved** in subsequent commits (by initializing NNA scratchpad memory to 0x00 and validating Wishbone polling). All simulation testbenches (`tb_soc_nav.v`, `tb_nna_top.v`, `tb_safety_filter.v`, `tb_nna_corner_cases.v`, `tb_safety_adversarial.v`) pass 100% with zero errors.
>
> For current active roadmap, verification matrices, and engineering gates, refer to:
> - Master Project Roadmap: `docs/PROJECT_ROADMAP.md`
> - Current Project Checkpoint: `CHECKPOINT_REPORT.md`
> - Synthesis Metrics: `docs/11_fpga_synthesis_report.md`

---

## 1. Historical Architecture Summary
- **CPU**: RV32IM PicoRV32 (Wishbone B4 master).
- **Bus Interconnect**: Wishbone crossbar interconnect with slave address decoding for:
  - Boot ROM (`0x0000_0000`, 8 KB)
  - System SRAM (`0x2000_0000`, 16 KB)
  - `rv_nna` INT8 SIMD Accelerator (`0x5000_0000`, 4 KB)
  - Deterministic Safety Interlock (`0x5000_0600`, 256 B)
  - Timer (`0x5000_0200`, 256 B)
  - UART (`0x5000_0100`, 256 B)
  - Dual PWM (`0x5000_0300`, 256 B)
- **Neural Policy (Pre-RL Synthetic Prototype)**: 2-layer INT8 feedforward network:
  - Input: 16 sensor features (8 lidar beams, 2 IMU, 2 odometry velocity, 2 target vector, 2 safety flags).
  - Layer 1: $16 \times 8$, INT8 MAC + 32-bit bias + Requantization (shift right 7) + ReLU.
  - Layer 2: $8 \times 2$, INT8 MAC + 32-bit bias + Requantization (shift right 7) + Saturation/Clipping.
  - Output: 2 control commands (linear velocity $v_{cmd}$, angular velocity $\omega_{cmd}$).
- **Safety Interlock**: Hardware and firmware deterministic clamping:
  - Front proximity check: if minimum forward distance < threshold ($0.35\,\text{m}$), $v_{cmd}$ clamped to zero and pure turn mode engaged.
  - Watchdog heartbeat register: must be stroked before deadline, otherwise hardware drops motor enable line.

---

## 2. Artifacts Produced in this Session
1. `sw/policy/export_weights.py`:
   - Generates synthetic test weights and exports both `sw/firmware/nav_weights.h` (C header) and `sw/firmware/nav_weights.inc` (assembly include).
2. `sw/firmware/robot_nav_firmware.s`:
   - Complete bare-metal RISC-V firmware loading weights into `rv_nna`, executing Layer 1 & Layer 2 inference, reading motor outputs, running deterministic safety clamping, updating PWM registers, and sending telemetry over UART.
3. `sw/firmware/robot_nav.elf`, `robot_nav.bin`, `robot_nav.hex`, `robot_nav.dump`:
   - Compiled and disassembled firmware images.
4. `sim/tb_soc_nav.v`:
   - Full SoC testbench simulating 3 navigation scenarios (open corridor, head-on obstacle, right-corner turn).

---

## 3. Historical Simulation Status & Root-Cause Diagnosis (Resolved)
- **Status at time of commit `66797d7`**:
  - In `tb_soc_nav.v`, the CPU reached instruction address `0x414` (`lbu t3, 0(t2)` inside `uart_puthex_byte`).
  - `t2` evaluated to `0x420 + a0`. The input `a0` contained `X` (undefined logic) because reading the NNA output scratchpad (`0x5000_0000 + 0x080`) returned uninitialized/X data.
- **Resolution Applied**:
  - NNA scratchpad dual-port RAM was updated with explicit synchronous zero-fill initialization on reset, and register decoding was verified.
  - Subsequent commits verified `tb_soc_nav.v` executing all 3 navigation cycles to full completion with clean UART telemetry and PWM generation.
