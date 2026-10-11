# 01. System Architecture Specification

## 1. Executive Summary & SoC Purpose

This SoC is a lightweight, open-source embedded System-on-Chip designed specifically for **reinforcement learning (RL) based mobile robot control**. The target robots are low-cost, compact ground mobile platforms (differential drive or Ackermann steering) equipped with low-dimensional sensors:
- Multi-channel distance sensors (ultrasonic, time-of-flight, or low-cost planar 2D LiDAR)
- 6-DOF IMU (accelerometer and gyroscope)
- Wheel odometry (quadrature encoders)
- Target-relative pose vectors (distance and bearing to goal)

The architecture splits responsibilities cleanly between a general-purpose processor and a dedicated neural coprocessor:
1. **RISC-V RV32IM CPU:** Executes the real-time operating control loop, sensor acquisition and pre-processing, policy input tensor assembly, communications/telemetry, and critically, the **deterministic safety filter**.
2. **INT8 Neural Network Accelerator (`rv_nna`):** A memory-mapped vector/matrix coprocessor dedicated to executing the dense layers of small Multi-Layer Perceptrons (MLPs). It accelerates fixed-point matrix-vector multiplications ($W \cdot X + B$), scaling, and non-linear activations (ReLU/Clipping).
3. **Deterministic Safety Module:** A hardware-enforced fail-safe and supervisor layer ensuring that unverified, out-of-distribution neural outputs cannot cause collisions, motor saturation, or loss of control.

---

## 2. High-Level SoC Block Diagram

```
+-----------------------------------------------------------------------------------------+
|                                    RISC-V ROBOT SoC                                     |
|                                                                                         |
|  +------------------------+                           +-------------------------------+ |
|  |     RISC-V RV32IM      |                           |          Boot ROM             | |
|  |       CPU Core         |<----+                     |           (8 KB)              | |
|  |    (lowRISC Ibex)      |     |                     +---------------+---------------+ |
|  +-----------+------------+     |                                     |                 |
|              | OBI / MMIO       | IRQ Line                            |                 |
|              v                  |                                     |                 |
|  +------------------------------+-------------------------------------+---------------+ |
|  |                      System Bus Interconnect (32-bit Address & Data)               | |
|  |                      Wishbone B4 / Simple Synchronous Bus Interconnect             | |
|  +---+---------------+----------------+----------------+----------------+---------+---+ |
|      |               |                |                |                |         |     |
|      v               v                v                v                v         v     |
|  +-------+     +-----------+    +----------+     +-----------+     +---------+ +------+ |
|  | SRAM  |     |   UART    |    |  Timer / |     | Motor PWM |     | Sensor  | | Safety | |
|  | (Data |     |  Console  |    | Watchdog |     | Generator |     | SPI/I2C | | Filter | |
|  | & Ins)|     |           |    |  (WDT)   |     | (2-4 ch)  |     | & GPIO  | | Inter- | |
|  | 64 KB |     +-----------+    +----------+     +-----------+     +---------+ | lock | |
|  +-------+                                                                     +--+---+ |
|                                                                                   ^     |
|  +----------------------------------------------------------------------------+   |     |
|  |            Memory-Mapped INT8 Neural Accelerator (`rv_nna`)                 |   |     |
|  |                                                                            |   |     |
|  |  +-------------------+  +-------------------+  +------------------------+  |   |     |
|  |  | Input Vector RAM  |  | Weight Buffer RAM |  | Bias / Output Buffer   |  |   |     |
|  |  | (128 bytes INT8)  |  | (1024 bytes INT8) |  | (32x INT32 / INT8)     |  |   |     |
|  |  +---------+---------+  +---------+---------+  +-----------+------------+  |   |     |
|  |            |                      |                        |               |   |     |
|  |            +-----------> +--------v-------+ <--------------+               |   |     |
|  |                          | 4-way INT8 MAC |                                |   |     |
|  |                          | & Requant Unit |                                |   |     |
|  |                          +--------+-------+                                |   |     |
|  |                                   |                                        |   |     |
|  |  +--------------------------------v-------------------------------------+  |   |     |
|  |  | CSRs: Dimension Config (M, K), Scale, Shift, ActType, Control/Status |  |   |     |
|  |  +----------------------------------------------------------------------+  |   |     |
|  +----------------------------------------------------------------------------+   |     |
|                                                                                   |     |
|  +--------------------------------------------------------------------------------v--+  |
|  | Actuator Output Pins (PWM / Direction) [Guarded by Hardware Safety Interlock]     |  |
+--+-----------------------------------------------------------------------------------+--+
```

---

## 3. Subsystem Breakdown

### 3.1 Processor Core Subsystem
- **ISA:** RV32IM (Base 32-bit Integer ISA + Hardware Multiplier/Divider).
- **Core Selected:** lowRISC Ibex (in 2-stage `small` configuration for FPGA, or PicoRV32 as minimal alternate).
- **Justification:** Hardware multiplication (`M` extension) is essential for fast sensor coordinate transforms (trigonometry, fixed-point odometry) and safety math without software emulation overhead.
- **Privilege Modes:** Machine Mode (M-mode) only. No MMU is required, minimizing gate count.

### 3.2 Interconnect Architecture
- **Bus Standard:** Wishbone B4 pipelined / Simple Synchronous Master-Slave MMIO interface.
- **Topology:** Single master (the CPU), multi-slave shared bus with decoded chip selects.
- **Data Width:** 32-bit data bus, 32-bit address bus, byte-write strobes (`wstrb[3:0]`).
- **Timing:** Single-cycle ready for SRAM and register accesses; multi-cycle wait-states supported via `ready`/`ack` handshaking.

### 3.3 Memory Hierarchy
- **Boot ROM (8 KB):** Pre-programmed bootloader, peripheral initializers, and power-on self-test (POST).
- **Main SRAM (64 KB unified):** Single-cycle access for CPU code and data. Stores real-time control loop code, sensor buffers, robot state estimates, and the safety parameter tables.
- **Accelerator Scratchpads:** Internal dual-port memories dedicated to the accelerator datapath, mapped into the CPU memory space to avoid bus contention during inference.

### 3.4 Peripheral Suite
- **UART:** 115200 baud console for telemetry, interactive debug, and telemetry streaming.
- **System Timer & Watchdog (WDT):** 64-bit microsecond counter and countdown watchdog. If the neural inference or CPU control loop hangs, the WDT expires, resets the SoC, or commands immediate safety stop.
- **Motor PWM Unit:** Multi-channel timer producing center-aligned PWM waveforms (10–20 kHz) with dead-time control for H-bridges.
- **Sensor Interfaces:** SPI master for IMU (e.g. MPU6050/ICM-20948), I2C for distance sensors (e.g. VL53L1X ToF), GPIO with edge interrupts for wheel encoders.
- **Hardware Safety Interlock:** Monitored bridge between software motor commands and hardware PWM registers.

---

## 4. Clock and Reset Domains

- **Clock Domain Strategy:** To ensure maximum FPGA portability and avoid clock domain crossing (CDC) bugs, the entire first-generation SoC runs on a **single synchronous clock domain**:
  - Target frequency: **25 MHz – 50 MHz** (standard for low-cost FPGAs such as Lattice ECP5, iCE40UP5K, or Xilinx Spartan-7).
- **Reset Strategy:** Synchronous active-low reset assertion and deassertion (`rst_n`), driven by an internal power-on-reset (POR) circuit or external reset push-button and watchdog reset source.
