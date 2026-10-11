# Checkpoint Report: RISC-V Robot Navigation SoC (Phase 3 Integration)

**Date**: October 11, 2026
**Commit**: `66797d7` (master)

---

## 1. Current Architecture Summary
- **CPU**: RV32IM PicoRV32 (Wishbone B4 master).
- **Bus Interconnect**: Wishbone crossbar interconnect with slave address decoding for:
  - Boot ROM (`0x0000_0000`, 8 KB)
  - System SRAM (`0x2000_0000`, 16 KB)
  - `rv_nna` INT8 SIMD Accelerator (`0x5000_0000`, 4 KB)
  - Deterministic Safety Interlock (`0x5000_0600`, 256 B)
  - Timer (`0x5000_0200`, 256 B)
  - UART (`0x5000_0100`, 256 B)
  - Dual PWM (`0x5000_0300`, 256 B)
- **Neural Policy**: 2-layer INT8 feedforward network:
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
   - Generates trained weights and exports both `sw/firmware/nav_weights.h` (C header) and `sw/firmware/nav_weights.inc` (assembly include).
2. `sw/firmware/robot_nav_firmware.s`:
   - Complete bare-metal RISC-V firmware loading weights into `rv_nna`, executing Layer 1 & Layer 2 inference, reading motor outputs, running deterministic safety clamping, updating PWM registers, and sending telemetry over UART.
3. `sw/firmware/robot_nav.elf`, `robot_nav.bin`, `robot_nav.hex`, `robot_nav.dump`:
   - Compiled and disassembled firmware images.
4. `sim/tb_soc_nav.v`:
   - Full SoC testbench simulating 3 navigation scenarios (open corridor, head-on obstacle, right-corner turn).

---

## 3. Simulation Status & Root-Cause Diagnosis
- **Tests Passed**:
  - Module-level testbenches (`tb_nna`, `tb_safety_filter`, `tb_soc_top`) pass 100%.
  - Firmware boots successfully from ROM; UART prints:
    ```
    === RISC-V Mobile Robot Navigation SoC Online ===
    [CORE] RV32IM CPU @ 50MHz
    [ACCEL] rv_nna INT8 4-way SIMD
    [SAFETY] Deterministic Interlock Armed

    [CYCLE 1] Open Corridor Navigation Test
      [TELEMETRY] v_cmd: 0x...
    ```
- **Halt Point Identified**:
  - In `tb_soc_nav.v`, the CPU reaches instruction address `0x414` (`lbu t3, 0(t2)` inside `uart_puthex_byte`).
  - `t2` evaluates to `0x420 + a0`. The input `a0` contains `X` (undefined logic) because reading the NNA output scratchpad (`0x5000_0000 + 0x080`) returned uninitialized/X data.
  - The uninitialized address lines causes the Wishbone interconnect slave decoder to miss, hanging Wishbone acknowledgement.
- **Root Cause**:
  - The NNA scratchpad dual-port RAM in simulation needs explicit initialization or zero-fill on reset, and the NNA `STATUS` register polling wait loop needs to ensure the accelerator has finished before the CPU reads `OUT_OFFSET`.

---

## 4. Next Planned Steps (Next Session)
1. Initialize the NNA scratchpad memory array in RTL (`nna_top.v` / scratchpad RAM) or add an explicit reset loop so unwritten bytes return `0x00` instead of `X`.
2. Verify the NNA busy/done polling loop in `robot_nav_firmware.s` to ensure output buffers are fully valid before UART telemetry and PWM updates.
3. Run `tb_soc_nav.v` to completion across all 3 test cases.
4. Update synthesis / resource reports and README documentation.
