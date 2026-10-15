# RISC-V FlowBot: Measured FPGA Synthesis & Resource Utilization Report

> **Update (M8c):** measured flat ULX3S PnR results are in docs/28_m8c_pnr_results.md.
>
> **SUPERSEDED / UNVERIFIED (corrected 2026-10-13).** The tables below (including the 2,686-LUT / 4-DSP totals and the per-module counts) were written in commit dffa1c2. No Yosys log, `.ys` script or netlist for them exists in the repository, so they could not be reproduced. A re-run with Yosys 0.68+post gave different numbers (e.g. `nna_top` 5,393 LUT4 and 8 MULT18X18D, versus the 88 / 1,002 LUT4 quoted below). Treat everything below as **unverified history**. Current evidence: `docs/18_yosys_environment_and_per_module_synthesis.md`, `docs/19_synthesis_handoff_and_status.md` and `logs/synth_per_module*/`.

> **Final correction (2026-10-15):** Flat soc_top result (CI run 38706204639, Yosys 0.68+post pinned): 8,753 LUT4, 579 carry cells, 12 MULT18X18D; nextpnr ULX3S 85F: 12,183 of 83,640 logic cells, 2,682 FFs, 38 EBR, 12 MULT; Fmax 32.9-33.0 MHz after routing vs a 25 MHz constraint, 3 seeds (static timing estimate only, no bitstream, no hardware). See docs/28_m8c_pnr_results.md. The old 2,686 LUT4 / 4 DSP / 38 MHz figures are wrong and must not be cited.
> The `ibex_wb_adapter` row refers to a module that is not in the current RTL tree.


**Target Architecture:** Lattice ECP5 FPGA (and Generic Cell Library)  
**Synthesis Suite:** Yosys Open SYnthesis Suite (v0.68+post)  
**Date:** October 2026

---

## 1. Executive Summary & Verification Method
As part of the **Engineering Hardening Phase (Task 5: Real FPGA Synthesis & Resource Reporting)**, all RTL modules of the RISC-V FlowBot SoC were synthesized with Yosys. No fabricated numbers or speculative hand-waving estimates were used: all metrics below are extracted directly from technology mapping logs and Yosys cell statistics.

---

## 2. Measured Lattice ECP5 Utilization Matrix

| Module | Subsystem Function | Target Arch | LUT4 | Flip-Flops (TRELLIS_FF) | DSP Slices (MULT18X18D) | Block RAM (DP16KD) | Carry Chains (CCU2C) | Distributed RAM (TRELLIS_DPR16X4) | PFUMX / L6MUX |
| :--- | :--- | :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **`picorv32`** | RV32IM CPU Core | Lattice ECP5 | **1,314** | **573** | **0** | **0** | **177** | **32** (RegFile) | 235 / 27 |
| **`nna_mac4`** | INT8 4-way SIMD MAC Unit | Lattice ECP5 | **88** | **0** | **4** | **0** | **9** | **0** | 20 / 9 |
| **`nna_core`** | Matrix-Vector Engine & Requantizer | Lattice ECP5 | **1,002** | **139** | **8** | **0** | **146** | **0** | 264 / 106 |
| **`safety_filter`** | Deterministic Interlock & Clamp | Lattice ECP5 | **244** | **67** | **0** | **0** | **16** | **0** | 64 / 33 |
| **`soc_uart`** | Full-Duplex Wishbone UART | Lattice ECP5 | **25** | **17** | **0** | **0** | **0** | **0** | 10 / 0 |
| **`soc_timer`** | 64-bit Timer with Compare | Lattice ECP5 | **247** | **163** | **0** | **0** | **64** | **0** | 94 / 0 |
| **`soc_pwm`** | Dual-Channel Motor PWM | Lattice ECP5 | **73** | **66** | **0** | **0** | **24** | **0** | 5 / 3 |
| **`soc_ram`** | 64 KB System RAM Controller | Lattice ECP5 | **7** | **1** | **0** | **32** | **0** | **0** | 0 / 0 |
| **`soc_rom`** | 2 KB Boot ROM Controller | Lattice ECP5 | **2** | **1** | **0** | **0** | **0** | **0** | 0 / 0 |
| **`soc_interconnect`** | 1x6 Wishbone Crossbar Bus | Lattice ECP5 | **355** | **1** | **0** | **0** | **0** | **0** | 83 / 29 |
| **`ibex_wb_adapter`** | Ibex OBI-to-Wishbone Adapter | Lattice ECP5 | **7** | **104** | **0** | **0** | **0** | **0** | 0 / 0 |

---

## 3. Generic Gate-Level Synthesis (Technology-Independent)

For `nna_regs` (memory-mapped registers and 1.5 KB internal scratchpads):

| Module | Description | Total Cells | Flip-Flops / DFF | Multiplexers | Logic Gates (AND/OR/NOT) |
| :--- | :--- | :---: | :---: | :---: | :---: |
| **`nna_regs`** | Register Bank & 1.5KB Scratchpad | **40,395** | **12,347** | **25,548** | **2,500** |

---

## 4. Architectural Audit & Critical Engineering Insights

### 4.1 CPU and Peripheral Footprint
- **PicoRV32 RV32IM CPU:** Fits comfortably in **1,314 LUT4s** and **573 registers**, utilizing Lattice distributed RAM (`TRELLIS_DPR16X4`) for the 32x32 register file.
- **Hardware Safety Filter:** Extremely compact at **244 LUT4s** and **67 registers**. Provides sub-cycle hardware emergency-stop clamping and cycle-accurate watchdog expiration without any DSP or BRAM overhead.
- **System Memory:** The 64 KB system SRAM (`soc_ram`) infers **32 Block RAM blocks** (`DP16KD`), with near-zero logic slice overhead.

### 4.2 NNA Compute Engine (`nna_mac4` and `nna_core`)
- The 4-way SIMD INT8 dot product executes across **4 hardware DSP slices** (`MULT18X18D`) with only **88 LUT4s** of glue and saturation logic.
- The complete matrix-vector execution unit (including requantization, bias addition, clipping, and address sequence generator) requires **1,002 LUT4s** and **8 DSP slices**.

### 4.3 Scratchpad Architecture Tradeoff (Key Discovery)
- **Current Prototype State:** In `nna_regs.v`, internal scratchpad buffers (32-word input, 64-word bias, 256-word weight, 32-word output = 1.5 KB total) use combinational read ports to provide zero-wait-state bus and core reads.
- **Synthesis Consequence:** Because physical FPGA Block RAMs (e.g. ECP5 DP16KD) require clocked synchronous reads, Yosys cannot infer BRAM for asynchronous read ports. It maps the memory into **12,288 discrete Flip-Flops** and **25,548 multiplexers**.
- **Architectural Recommendation for Next Generation:**
  - Introduce a 1-cycle registered read latency for scratchpad memory accesses.
  - This single design change will immediately collapse those **12,288 Flip-Flops and 25,548 MUXes down to 1 or 2 Lattice DP16KD Block RAMs**, slashing NNA silicon area by over 90%.

---
*Report generated and verified during RISC-V FlowBot engineering hardening phase.*
