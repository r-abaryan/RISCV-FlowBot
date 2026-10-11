# 07. RTL Breakdown, Verification Strategy, FPGA Targets, and Technical Risks

## 1. RTL Module Breakdown

The RTL codebase is designed with clean modular boundaries to allow independent unit testing:

```
rtl/
├── soc_pkg.sv              # Parameter declarations, register offsets, constants
├── bus/
│   └── bus_mux.v           # Synchronous bus crossbar / address decoder
├── nna/
│   ├── nna_top.v           # Accelerator top: Bus slave interface + core integration
│   ├── nna_regs.v          # Memory-mapped CSRs and internal dual-port scratchpads
│   ├── nna_mac4.v          # 4-way parallel INT8 multiplier and 4-input adder tree
│   └── nna_core.v          # Execution FSM, 32-bit accumulator, requantize & activation
└── safety/
    └── safety_filter.v     # Watchdog heartbeat supervisor & emergency clamp
```

### Module Responsibilities:
1. **`nna_top.v`:**
   Implements the bus slave handshaking (`req`, `we`, `addr`, `wdata`, `wstrb`, `rdata`, `ready`). Routes configuration writes to `nna_regs` and scratchpad memory writes to the corresponding buffer (Input, Bias, Weight).
2. **`nna_regs.v`:**
   Hosts the Control, Status, Dimension, Scale, and Shift registers. Stores the Input Buffer (128 B), Bias Buffer (256 B), and Output Buffer (128 B). Provides dual-port read access to the compute datapath.
3. **`nna_mac4.v`:**
   Performs simultaneous 4-element dot product: $P = \sum_{i=0}^3 W_i \cdot X_i$. Pure combinational or single-cycle registered datapath.
4. **`nna_core.v`:**
   Houses the sequencing FSM, the 32-bit accumulator, fixed-point scale multiplier ($Acc \times M_0$), arithmetic right shifter ($\gg N$), and saturation/activation logic.
5. **`safety_filter.v`:**
   Monitors the CPU software heartbeat. Automatically forces PWM disarm if heartbeat fails or if external emergency stop is triggered.

---

## 2. Verification and Simulation Strategy

We apply a strict **dual-model verification strategy**:
1. **Golden Reference Python Model (`sw/model/reference_model.py`):**
   - Implements bit-exact symmetric INT8 quantized matrix-vector arithmetic identical to the hardware math.
   - Generates randomized test cases (input activations, weight matrices, biases, scale/shift combinations) and computes expected output tensors.
   - Exports test vector files (hex memory images or testbench headers).
2. **Hardware Testbench (`sim/tb_nna_top.v`):**
   - Simulates complete bus cycles (Wishbone / MMIO) to write input activations, weights, biases, and configuration registers.
   - Triggers computation and monitors the `DONE` flag / interrupt line.
   - Reads back the computed output buffer over the bus and performs bit-for-bit assertions against the expected reference vectors.
3. **Simulation Toolchains:**
   - **Icarus Verilog (`iverilog`):** Fast, lightweight functional verification and waveform (`vcd`) generation.
   - **Verilator:** Cycle-accurate C++ simulation model for high-throughput testing and software-in-the-loop co-simulation.

---

## 3. FPGA Prototyping Strategy

### 3.1 Primary Target Platforms
1. **Lattice ECP5 (e.g., Colorlight i5 / LFE5U-25F or OrangeCrab):**
   - Excellent fit for open-source EDA tools (Yosys + nextpnr-ecp5).
   - Generous block RAM (sysMEM) and DSP slices.
   - Target Frequency: **25 MHz – 50 MHz**.
2. **Xilinx Artix-7 (e.g., Digilent Arty A7-35T / A7-100T):**
   - Industry-standard prototyping board.
   - Toolchains: Vivado or open-source Yosys + prjxray.
   - Target Frequency: **50 MHz – 100 MHz**.
3. **Lattice iCE40UP5K (Ultra-Low Power / Size):**
   - Fallback target using PicoRV32 core instead of Ibex.
   - Uses on-chip SPRAM (Single Port RAM) for memory buffers.
   - Target Frequency: **12 MHz – 24 MHz**.

---

## 4. Estimated Resource & Performance Targets

*Note: Estimates are derived from component synthesis baselines in open-source literature (lowRISC Ibex benchmarks, standard Yosys DSP mappings); actual numbers vary with synthesis tools, target architecture, and configuration flags.*

| Subsystem / Module | Logic Elements (LUTs approx.) | Flip-Flops (FFs approx.) | Block RAMs (BRAM / EBR) | DSP Slices (18x18 Multipliers) |
|---|---|---|---|---|
| **lowRISC Ibex CPU (RV32IM 2-stage)** | 1,800 – 2,400 | 1,000 – 1,400 | 0 (uses external bus) | 1 – 2 (if hardware multiplier mapped to DSP) |
| **System Interconnect & Peripherals** | 600 – 900 | 400 – 600 | 0 | 0 |
| **Boot ROM + Main SRAM (64 KB)** | 100 – 200 (wrapper) | 50 – 100 | 16 – 32 (depending on FPGA BRAM size) | 0 |
| **`rv_nna` Accelerator Core** | 500 – 800 | 300 – 500 | 2 – 4 (Weight & Scratchpad RAMs) | 2 – 4 (or 0 if synthesized to LUTs) |
| **Safety Interlock & Watchdog** | 150 – 250 | 100 – 150 | 0 | 0 |
| **Total Full SoC Estimate** | **~3,200 – 4,500 LUTs** | **~1,850 – 2,750 FFs** | **~18 – 36 BRAMs** | **3 – 6 DSPs** |

### Performance Projection:
- 3-Layer MLP inference latency: **~370 to 450 clock cycles**.
- At 50 MHz: Inference latency is **~7.5 to 9.0 microseconds**.
- Sensor loop frequency: Easily supports **1,000 Hz (1 ms)** control loops with over **95% CPU idle / safety supervisor time**.

---

## 5. Major Technical Risks and Open Questions

1. **Quantization Precision Risk:**
   - *Risk:* Post-training INT8 quantization may reduce policy rewards or cause small oscillations around steady-state goals in sensitive RL control tasks.
   - *Mitigation:* Employ Quantization-Aware Training (QAT) during policy training in PyTorch / Isaac Gym / Stable-Baselines3. Symmetric INT8 quantization with per-layer scale parameters provides robust fidelity for robotics.
2. **Weight Memory Capacity vs. Model Size:**
   - *Risk:* The initial on-chip weight buffer is 1 KB (256 words). If a policy expands beyond 1024 parameters per layer, weights must be swapped from main memory or streamed over the bus.
   - *Mitigation:* 1 KB per layer easily accommodates up to a $32 \times 32$ or $64 \times 16$ layer. For larger models, a simple DMA or burst-read interface can be added to the accelerator in Phase 2.
3. **Interrupt Latency & Sensor Jitter:**
   - *Risk:* Slow I2C / SPI sensor reading blocking the CPU and causing jitter in the real-time control period.
   - *Mitigation:* Autonomous peripheral hardware FIFOs or timer-triggered sampling ensure deterministic control periodicity.
4. **Safety Filter Conservatism:**
   - *Risk:* Overly conservative safety limits can prevent the robot from executing agile RL maneuvers.
   - *Mitigation:* Multi-tiered safety envelope where intervention is proportional to danger (gradual braking rather than abrupt hard-stopping when far from obstacles).
