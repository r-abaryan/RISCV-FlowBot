# 02. CPU Core Recommendation and Justification

> **Correction 2026-10-16:** this document records the original evaluation, which recommended Ibex. The implemented CPU in `rtl/soc_top.v` is the existing open-source PicoRV32 (via `picorv32_wb`), not Ibex. We did not design either core. See `docs/08_decision_log.md`, Decision 1.

## 1. Candidate Core Evaluation

We evaluated five open-source RISC-V cores against strict requirements for our robotic control SoC:
1. **RV32IM Support:** Hardware integer multiplication/division (`M` extension) is mandatory for robot kinematics, sensor filtering, and safety coordinate calculations.
2. **Permissive Open-Source License:** Apache 2.0, MIT, or BSD license allowing unrestricted academic and commercial adoption.
3. **Simplicity and Maintainability:** Human-readable HDL (standard Verilog or SystemVerilog), clean modularity, and zero reliance on proprietary generator toolchains.
4. **FPGA Suitability:** Low LUT and flip-flop footprint, predictable timing closure at 25–50 MHz on low-cost FPGAs (Lattice ECP5/iCE40, Xilinx Spartan-7/Artix-7).
5. **Tooling and Community Support:** Native support in GCC/Clang RISC-V toolchains, simple simulation with Verilator and Icarus Verilog.

---

## 2. Comparison Matrix

| Core Candidate | Primary Language | License | Pipeline Stages | RV32IM Area (FPGA LUTs approx.) | Bus Interface | Advantages | Disadvantages |
|---|---|---|---|---|---|---|---|
| **lowRISC Ibex** | SystemVerilog | Apache 2.0 | 2-stage (`small`) / 3-stage (`balanced`) | ~1,800 – 2,500 LUTs | OBI (Open Bus Interface) | Formally verified in OpenTitan; configurable multiplier; clean code; standard GCC support | Moderate LUT count; requires SystemVerilog 2012 capable synthesis (supported by Yosys and Vivado) |
| **PicoRV32** | Verilog-2001 | ISC (Permissive) | Multi-cycle (microcode) | ~900 – 1,400 LUTs | Simple native / Wishbone | Ultra-compact; extremely mature; pure Verilog-2001 (runs anywhere) | Low IPC (~0.25–0.30); multi-cycle multiplier takes 32+ cycles |
| **VexRiscv** | SpinalHDL (Scala) | MIT | 4–5 stages | ~1,200 – 2,000 LUTs | Wishbone / AXI4 / Avalon | Outstanding IPC (~1.0); highly customizable via SpinalHDL plugins | HDL is machine-generated Verilog from Scala; harder to debug or modify directly |
| **CV32E40P** (PULP) | SystemVerilog | Apache 2.0 | 4 stages | ~3,500 – 5,000 LUTs | OBI | High performance; PULP hardware loops; comprehensive verification | Heavyweight; unnecessarily complex for first-generation micro-robot controller |
| **SERV** | Verilog-2001 | ISC | Bit-serial (1-bit datapath) | ~200 – 300 LUTs | Wishbone | World's smallest RISC-V core | Extreme cycle penalty (32+ cycles per ALU op, 1000+ for mult); unacceptable for real-time control |

---

## 3. Recommendation: lowRISC Ibex (Primary) & PicoRV32 (Baseline Fallback)

### 3.1 Primary Recommendation: lowRISC Ibex
We select **lowRISC Ibex** (specifically configured with `Rv32m = Rv32MSingleCycle` or `Rv32MFast` and 2-stage `small` pipeline) as the reference CPU core for the following reasons:
1. **Determinism and Real-Time Latency:** The 2-stage in-order pipeline gives deterministic instruction timing without branch prediction penalties, critical for high-frequency hard-real-time sensor sampling (500 Hz – 1 kHz).
2. **Fast Hardware Multiplier:** Ibex includes a dedicated 3-cycle or 1-cycle DSP-based multiplier module. In a robotics loop, calculating Euclidean distance, cross products, coordinate rotation matrices, and sensor calibration polynomials requires constant multiplication.
3. **Open Bus Interface (OBI):** Ibex uses OBI, a clean, synchronous master interface that translates directly to standard Wishbone or simple memory bus signals with trivial logic.
4. **Vast Tooling & Verification Heritage:** Ibex has undergone extensive UVM verification, formal verification, and ASIC silicon tapeouts as part of the OpenTitan project.

### 3.2 Baseline Fallback: PicoRV32
For ultra-constrained FPGA targets (such as the Lattice iCE40UP5K with only 5,280 LUTs where Ibex might consume >35% of the device), **PicoRV32** serves as a plug-and-play fallback.
Because our SoC interconnect uses a clean, decoupled bus protocol (Address, Write Data, Read Data, Strobe, Ready/Ack), switching between Ibex and PicoRV32 requires only a 20-line bus adapter shim.
