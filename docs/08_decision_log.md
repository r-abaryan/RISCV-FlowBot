# 08. Architectural Decision Log

This log documents major architectural alternatives evaluated, trade-offs analyzed, and the rationale behind each architectural choice.

---

### Decision 1: CPU Core Selection
- **Status:** Approved
- **Chosen Option:** lowRISC Ibex (with PicoRV32 as ultra-compact fallback)
- **Alternatives Considered:**
  1. *PicoRV32:* Very small and simple Verilog-2001, but low IPC and slow multi-cycle multiplier.
  2. *VexRiscv:* Excellent IPC and FPGA utilization, but source code is SpinalHDL (Scala), making it less accessible for standard Verilog educational/inspection workflows.
  3. *CV32E40P (OpenHW):* Very capable, but excessive complexity (4 stages, PULP hardware loops) for a minimal first-generation robot SoC.
  4. *SERV:* Bit-serial architecture; ultra-compact but orders of magnitude too slow for hard-real-time robot sensor and safety loops.
- **Rationale:** Ibex provides the optimal balance of industrial-grade verification (OpenTitan), clean SystemVerilog source code, 2-stage predictable deterministic execution, standard OBI bus interface, and efficient RV32IM hardware multiplier.

---

### Decision 2: CPU ISA Configuration (RV32IM without FPU)
- **Status:** Approved
- **Chosen Option:** RV32IM (Integer + Hardware Multiply/Divide)
- **Alternatives Considered:**
  1. *RV32I only:* Omission of hardware multiplier requires software emulation (`__mulsi3`), which consumes hundreds of clock cycles per geometric transform in odometry.
  2. *RV32IMF (with single-precision FPU):* Floating-point hardware adds substantial FPGA logic area (1,500+ additional LUTs).
- **Rationale:** Robot kinematics and safety filters run efficiently using 32-bit fixed-point arithmetic using the hardware integer multiplier. Skipping the FPU preserves FPGA resources for the neural accelerator and memories.

---

### Decision 3: Memory-Mapped Coprocessor vs. Custom RISC-V Instructions
- **Status:** Approved
- **Chosen Option:** Memory-Mapped Accelerator (`rv_nna`) over system bus
- **Alternatives Considered:**
  1. *Custom RISC-V Instructions (e.g. via custom-0 / opcode extensions):* Requires patching GCC/LLVM assembler, compiler backends, and modifying the core execution pipeline / register writeback stage.
  2. *Standard RISC-V Vector Extension (RVV):* Complex, massive area footprint unsuitable for low-cost FPGAs.
- **Rationale:** A memory-mapped accelerator decouples the accelerator lifecycle from the CPU core pipeline. It uses standard unmodified RISC-V toolchains (standard GCC `riscv32-unknown-elf-gcc`), allows easy bus testing, and provides clear integration boundaries.

---

### Decision 4: Quantization Scheme (Symmetric INT8 vs. Asymmetric UINT8)
- **Status:** Approved
- **Chosen Option:** Symmetric Signed INT8 for weights and activations ($Z = 0$)
- **Alternatives Considered:**
  1. *Asymmetric UINT8 (TFLite standard with non-zero zero points):* Requires hardware logic to compute and subtract zero-point cross-terms ($\sum W_i \cdot Z_x$, $\sum X_i \cdot Z_w$), inflating FPGA area.
  2. *FP16 / BFloat16:* Requires floating-point multipliers, exponent aligners, and normalizers.
- **Rationale:** Symmetric INT8 completely cancels all zero-point cross-terms, yielding pure signed multiply-accumulate operations ($W \times X$). It fits cleanly into DSP blocks or simple LUT multipliers and matches standard PyTorch INT8 quantization.

---

### Decision 5: Bus Interconnect Architecture
- **Status:** Approved
- **Chosen Option:** Simple Synchronous Decoupled Bus (Direct Wishbone B4 / OBI compatible)
- **Alternatives Considered:**
  1. *Full AXI4:* Complex 5-channel handshaking, excessive logic overhead for single-master SoC.
  2. *AXI4-Lite:* Viable, but slightly more complex than Wishbone B4 or simple valid/ready OBI.
- **Rationale:** The chosen protocol (`req`, `we`, `addr`, `wdata`, `wstrb`, `rdata`, `ready`) provides single-cycle or multi-cycle transactions with minimal logic, and maps cleanly to Wishbone, OBI, or simple SRAM interfaces.

---

### Decision 6: Deterministic Safety Layer Placement
- **Status:** Approved
- **Chosen Option:** Hybrid Architecture: CPU Deterministic Software Supervisor with Hardware Safety Interlock & Watchdog
- **Alternatives Considered:**
  1. *Direct Neural Control of Actuators:* Actuators driven directly by accelerator output. **Rejected:** Unacceptable collision and runaway risk.
  2. *Pure Software Safety Layer without Hardware Watchdog:* Software checks outputs, but if the CPU crashes or hangs, motors stay at last commanded speed. **Rejected:** Dangerous.
  3. *Pure Hardware State Machine with No Software:* Limits flexibility in tuning safety distances or obstacle geometries.
- **Rationale:** The CPU executes the dynamic kinematic and proximity equations, but a dedicated hardware watchdog/interlock enforces that if the CPU or software loop fails to refresh the safety heartbeat, the hardware physically disarms motor PWM outputs.
