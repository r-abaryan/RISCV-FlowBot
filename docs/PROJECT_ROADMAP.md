# RISC-V FlowBot Master Project Roadmap

**Document Version:** 2.0  
**Status:** Active Master Specification  
**Current Milestone:** Phase 1 Complete (Genuine RL/DAgger Trained Navigation Policy Verified; INT8 Retention 100%); Ready for Phase 2 Execution  
**Project Objective:** A reproducible robotic computing platform that executes a genuinely learned reinforcement-learning policy through a custom RV32IM SoC with memory-mapped INT8 neural acceleration while maintaining deterministic hardware safety boundaries.

---

## 1. Capability Maturity Framework

To maintain engineering rigor and avoid speculative claims, all capabilities in this project are strictly categorized into six maturity tiers:

| Maturity Tier | Formal Definition | Current Baseline Verification Status |
| :--- | :--- | :--- |
| **PROPOSED** | Architecturally specified and documented in design specifications; RTL or code not yet written. | High-level roadmap goals, physical chassis integration. |
| **IMPLEMENTED** | Verilog RTL, bare-metal C/assembly firmware, or Python scripts fully written and syntax-checked. | SoC interconnect, PicoRV32 core, `rv_nna` accelerator, safety filter, UART, PWM, timer. |
| **SIMULATED** | Functionally verified in cycle-accurate simulation with automated testbenches and zero assertions/errors. | Verified in Icarus Verilog (`tb_soc_nav`, `tb_nna_top`, `tb_nna_corner_cases`, `tb_safety_filter`, `tb_safety_adversarial`). |
| **SYNTHESIZED** | Formally mapped to a target FPGA technology library using logic synthesis tools; gate count and timing reported. | Synthesized in Yosys to Lattice ECP5 (`LFE5U-25F`); measured 2,686 LUTs, 4 DSP slices. |
| **FPGA-TESTED** | Placed, routed, bitstream generated, and physically executed on physical FPGA development board. | *Pending Phase 5* (PnR & timing closure on physical board). |
| **PHYSICALLY VALIDATED**| Executed on physical mobile robot with real motors, real lidar/ToF sensors, and supervised safety tests. | *Pending Phase 6* (Physical robot platform). |

> **Critical Baseline Distinction:** The existing simulation (`tb_soc_nav.v`) proves the complete RV32IM CPU + MMIO accelerator + safety interlock + PWM dataflow using a **synthetic heuristic policy** (hand-tuned weights). It demonstrates that the hardware execution pipeline functions correctly. The genuine reward-driven reinforcement learning policy will be designed, trained, quantized, integrated, and evaluated in **Phases 1 through 4**.

---

## 2. Master Project Phases

```
+----------------------------------------------------------------------------------------------------+
|                                    MASTER PROJECT ROADMAP                                          |
+----------------------------------------------------------------------------------------------------+
|                                                                                                    |
|  [PHASE 1: RL Training]       --> Lightweight 2D sim, reward-driven policy training (NumPy)       |
|            |                                                                                       |
|  [PHASE 2: INT8 Quantization] --> Map float policy to rv_nna INT8 specs, bit-exact verification    |
|            |                                                                                       |
|  [PHASE 3: SoC Integration]   --> Embed weights in ROM/RAM, bare-metal RV32IM firmware inference   |
|            |                                                                                       |
|  [PHASE 4: Closed-Loop Sim]   --> Co-simulate SoC RTL + 2D environment, measure nav & safety stats |
|            |                                                                                       |
|  [PHASE 5: FPGA PnR & Timing] --> Optimize scratchpad BRAM inference, Lattice/Artix-7 timing closure|
|            |                                                                                       |
|  [PHASE 6: Physical Robot]    --> Sensor/motor I/O, physical chassis testing with human safety gate|
+----------------------------------------------------------------------------------------------------+
```

---

### Phase 1 — RL Environment and Policy Training (STATUS: COMPLETE)

> **Phase 1 Complete:** Pure-NumPy DAgger training verified in 34.9s with 78% navigation success rate and 100.0% retention under INT8 `rv_nna` quantization. See `docs/13_phase1_rl_training_report.md`.

#### 1. Objective
Implement a lightweight, self-contained 2D mobile robot navigation simulation environment and train a genuine reward-driven neural policy that demonstrates measurable learning progress against baseline controls.

#### 2. Technical Scope
- **Host Execution Constraints:** Strict operation within local resource envelope (**458 MB available RAM, 1 vCPU, Alpine Linux, Python 3.14 with NumPy**). Heavy external frameworks (PyTorch, TorchRL, Stable-Baselines3) are prohibited due to deterministic kernel OOM risks.
- **Simulation Environment (`sw/env/nav_env_2d.py`):**
  - Continuous 2D kinematics for a differential-drive robot: position $(x, y)$, heading $\theta$, forward velocity $v \in [0, v_{\max}]$, angular velocity $\omega \in [-\omega_{\max}, +\omega_{\max}]$.
  - Sensor model: 12-ray simulated rangefinder (lidar/sonar) with configurable range and obstacle collision boundaries, target-relative polar coordinates (distance $d$, relative angle $\phi$), and current velocities. Total observation dimension: **16 features**.
  - Configurable arenas: Point-to-point goal reaching with circular and rectangular static obstacles.
  - Reward function: Positive progress toward goal, penalty for angular deviation, heavy penalty for collisions, small step penalty for time efficiency.
- **Learning Algorithm (`sw/training/train_rl.py`):**
  - Implement a vectorized, pure-NumPy policy optimization algorithm: **Augmented Random Search (ARS)** or **Policy Gradient (REINFORCE with baseline)**.
  - Policy network: 2-layer Multilayer Perceptron (MLP):
    - Input: 16 features.
    - Hidden Layer: 16 neurons with ReLU activation (total weights: $16 \times 16 = 256 \le 1024$ accelerator scratchpad limit).
    - Output Layer: 2 neurons (linear velocity $v$, angular velocity $\omega$) with bounded output clipping.
  - Reproducible training loop with fixed random seeds and reward history tracking.
- **Baseline Implementations (`sw/training/baselines.py`):**
  - *Random Policy Baseline:* Uniform random actions across control space.
  - *Heuristic Baseline:* Classical potential field / Braitenberg obstacle avoidance + proportional goal steering.

#### 3. Dependencies
- Baseline hardware architectural invariants (16-feature input vector, 16-hidden node limit, ReLU activation, 2 output controls).

#### 4. Acceptance Criteria
1. Reward progression curve demonstrates statistically significant learning over training iterations.
2. Across an evaluation benchmark of at least 50 randomized test episodes (fixed test seeds), the trained policy achieves:
   - Success rate strictly greater than the random baseline ($> 70\%$ target).
   - Collision rate lower than the heuristic baseline.
   - Average episode steps to goal significantly lower than random walk.
3. Training script runs to completion in $< 3$ minutes on the single-vCPU host using $< 40$ MB peak memory.

#### 5. Evidence Requirements
- Reproducible training script and self-contained execution test.
- Generated training log and ASCII/CSV reward curve showing convergence.
- Benchmark summary table comparing Trained Policy vs. Random Baseline vs. Heuristic Baseline across identical test seeds.
- Saved float32 policy model weights and biases (`sw/model/trained_float32_policy.npz`).

#### 6. Engineering Gate 1
- **Deliverable:** `docs/13_phase1_rl_training_report.md` documenting environment kinematics, reward formulation, convergence metrics, and evaluation benchmark.
- **Review Requirement:** Verified reproducibility before starting quantization.

---

### Phase 2 — INT8 Quantization and Accelerator Validation

#### 2. Objective
Quantize the genuinely trained Phase 1 neural policy to the exact physical specification of the `rv_nna` accelerator, verify numerical behavior under INT8 arithmetic, and prove bit-exact alignment between the Python reference model and the Verilog RTL accelerator simulation.

#### 2. Technical Scope
- **Hardware Semantics Alignment:**
  - Weights & inputs: Symmetric two's complement INT8 ($[-128, +127]$, zero-point $Z = 0$).
  - Biases: 32-bit signed integers ($[-2^{31}, +2^{31}-1]$).
  - Layer Requantization: 16-bit unsigned multiplier `scale_mult` and shift `scale_shift` $[0, 31]$ with arithmetic right-shift and rounding.
  - Activations: Layer 1 uses `ACT_RELU` ($[0, +127]$); Layer 2 uses `ACT_CLIP` ($[-128, +127]$).
- **Quantization Pipeline (`sw/model/quantize_policy.py`):**
  - Implement calibration-based symmetric post-training quantization (PTQ) or QAT fine-tuning on observation batches generated by the trained policy.
  - Calculate per-layer input scales $S_x$, weight scales $S_w$, and output scales $S_y$.
  - Compute fixed-point requantization parameters:
    $$M = \frac{S_x \cdot S_w}{S_y} \implies \text{scale\_mult} = \text{round}(M \cdot 2^{\text{scale\_shift}})$$
  - Validate that bias scaling matches $S_{\text{bias}} = S_x \cdot S_w$.
- **Validation Suite:**
  - Evaluate quantized INT8 policy inside the 2D environment simulator (`sw/env/eval_quantized.py`).
  - Compare action degradation and task success rate between Float32 and INT8.
  - Generate comprehensive RTL test vectors from real policy observations and verify bit-exact outputs against `tb_nna_top.v`.

#### 3. Dependencies
- Phase 1 trained float32 policy model (`trained_float32_policy.npz`).
- Verilog RTL `rv_nna` accelerator and testbench infrastructure.

#### 4. Acceptance Criteria
1. Quantized INT8 policy evaluated in the 2D environment retains $\ge 95\%$ of the original Float32 policy success rate.
2. Bit-exact match ($0$ LSB difference across all outputs) between the Python INT8 reference implementation and the Verilog `rv_nna` accelerator RTL simulation for 100% of tested policy evaluation vectors.
3. Automated generation of header files (`nav_weights_trained.h`, `nav_weights_trained.inc`) formatted for direct compilation into bare-metal RISC-V firmware.

#### 5. Evidence Requirements
- Numerical error analysis report documenting float vs. INT8 action MAE (Mean Absolute Error).
- Verilog simulation log (`tb_nna_trained_policy.log`) confirming 100% matching outputs against Python vectors.
- Exported firmware header files tracked in `sw/firmware/`.

#### 6. Engineering Gate 2
- **Deliverable:** `docs/14_phase2_quantization_report.md` containing scale parameters, comparative evaluation metrics, and RTL simulation logs.
- **Review Requirement:** Approval of bit-exact verification before firmware integration.

---

### Phase 3 — RISC-V Firmware and SoC Integration

#### 1. Objective
Execute the genuinely trained and validated INT8 policy through the complete simulated RISC-V CPU and memory-mapped neural accelerator, integrating observation ingestion, layer sequencing, deterministic safety filtering, and actuator PWM generation.

#### 2. Technical Scope
- **Firmware Implementation (`sw/firmware/robot_policy_firmware.s` / C HAL):**
  - Bootloader sequence: Stack initialization, trap setup, peripheral initialization.
  - Sensor input normalization: Scale simulated 16-feature sensor readings into signed INT8 observation vector in CPU registers/RAM.
  - Neural inference orchestration:
    1. Write Layer 1 weights and biases to `rv_nna` scratchpad (`0x5000_0000`).
    2. Write Layer 1 input vector to scratchpad input buffer.
    3. Configure `0x5000_0004` (dimensions $K=16, M=16$, `ACT_RELU`, scale multiplier/shift).
    4. Trigger computation (`0x5000_0000 = 0x1`) and poll `ST_DONE` status flag.
    5. Feed Layer 1 output activations into Layer 2 input buffer.
    6. Configure Layer 2 ($K=16, M=2$, `ACT_CLIP`, scale parameters) and execute.
    7. Read raw unconstrained neural actions ($v_{\text{raw}}, \omega_{\text{raw}}$).
  - Deterministic Safety Supervisor:
    - Evaluate frontal proximity threshold; dynamically clamp forward velocity if distance $< d_{\text{safe}}$.
    - Enforce maximum angular turn rate based on obstacle clearance.
    - Refresh hardware safety watchdog heartbeat (`0x5000_0600 = 0x5A5A_0001`).
  - Motor Control:
    - Map clamped $(v, \omega)$ to differential drive left and right motor duty cycles.
    - Write commanded duty cycles to PWM channel registers (`0x5000_0404`, `0x5000_0408`).
  - Telemetry:
    - Stream execution cycle counts, sensor features, neural outputs, safety clamp flags, and motor commands over UART.

#### 3. Dependencies
- Phase 2 validated INT8 trained policy weights.
- Hardened RISC-V SoC Verilog RTL (`soc_top.v`, `soc_ram.v`, `soc_rom.v`, `safety_filter.v`, `rv_nna.v`, `uart.v`, `pwm.v`).

#### 4. Acceptance Criteria
1. Bare-metal firmware compiles cleanly with GNU RISC-V binutils into ROM/RAM hex image.
2. Cycle-accurate simulation of `tb_soc_nav.v` executes multi-step inference cycles without bus hang or timeout.
3. Accelerator execution cycle latency per inference is strictly quantified and bounded ($< 600$ clock cycles for 2 layers).
4. Watchdog timer is refreshed deterministically; simulated hardware safety interlock remains unarmed/armed per specification.
5. Injected emergency conditions (e.g. proximate obstacle or software delay) trigger deterministic safety override and motor shutdown in simulation.

#### 5. Evidence Requirements
- Compiled firmware binary, disassembly dump (`.dump`), and memory map inspection.
- Full Icarus Verilog simulation log showing cycle-by-cycle execution, UART output telemetry, and PWM duty cycle registers.
- Execution profiling report detailing CPU overhead vs. accelerator speedup.

#### 6. Engineering Gate 3
- **Deliverable:** `docs/15_phase3_soc_integration_report.md` documenting firmware architecture, timing breakdowns, and simulation logs.
- **Review Requirement:** Verified full SoC simulation before closed-loop environment coupling.

---

### Phase 4 — Closed-Loop Robotics Evaluation

#### 1. Objective
Connect the cycle-accurate RISC-V SoC simulation directly to the 2D robotics navigation environment, evaluating complete autonomous navigation episodes in closed-loop operation and reporting statistical performance against baselines.

#### 2. Technical Scope
- **Co-Simulation Architecture (`sim/closed_loop_harness.py`):**
  - Implement a synchronized co-simulation bridge between Python 2D kinematics and Icarus Verilog SoC simulation.
  - *Mechanism:* Lock-step IPC (via socket, pipe, or file-based step vector interchange):
    1. Python environment computes sensor rays from current robot pose.
    2. Injects sensor readings into SoC simulation memory or UART RX stream.
    3. Simulates SoC for one control period ($\Delta t = 20\text{ ms}$, corresponding to $N$ clock cycles at target clock).
    4. Extracts resulting PWM motor commands from SoC output pins/registers.
    5. Updates robot state in 2D physics simulation.
- **Evaluation Benchmark:**
  - Execute 50+ closed-loop episodes across standard, randomized, and adversarial obstacle courses.
  - Measure:
    - Episode Success Rate (% reached goal without collision).
    - Hard Collision Rate (physical contact with obstacle).
    - Deterministic Safety Intervention Rate (% of control steps where safety supervisor overrode neural policy).
    - Path Efficiency (actual trajectory length vs. optimal Euclidean distance).
    - Average Control Latency (simulated clock cycles per step).

#### 3. Dependencies
- Phase 1 2D navigation environment.
- Phase 3 integrated SoC firmware and simulation RTL.

#### 4. Acceptance Criteria
1. Closed-loop harness completes full multi-episode test runs deterministically with reproducible seed tracking.
2. The closed-loop SoC platform achieves an episode success rate $\ge 80\%$ on standard evaluation arenas.
3. Deterministic safety filter strictly prevents 100% of catastrophic frontal collisions, intervening whenever neural policy commands unsafe forward velocity near obstacles.
4. Comprehensive comparison matrix confirms agreement between software simulation (Phase 1/2) and hardware SoC simulation (Phase 4).

#### 5. Evidence Requirements
- Automated test script `sim/run_closed_loop_eval.py` executing unattended with summary results.
- Trajectory plots comparing paths of Phase 1 float policy vs. Phase 4 SoC hardware closed-loop execution.
- Statistical metrics table (Success rate, collisions, interventions, cycle latency).

#### 6. Engineering Gate 4
- **Deliverable:** `docs/16_phase4_closed_loop_evaluation_report.md` documenting co-simulation architecture, episode trajectories, intervention logs, and performance analysis.
- **Review Requirement:** Approval of closed-loop verification before FPGA physical synthesis optimizations.

---

### Phase 5 — FPGA Implementation and Timing Closure

#### 1. Objective
Resolve hardware resource inefficiencies—specifically inferring dedicated Block RAM (EBR/BRAM) for the accelerator scratchpad memory instead of distributed LUT logic—and achieve complete place-and-route and static timing closure for a target FPGA device.

#### 2. Technical Scope
- **Scratchpad BRAM Inefficiency Resolution (`rtl/rv_nna/nna_scratchpad.v`):**
  - Current baseline synthesizes scratchpad memory to **~1,200 LUTs/flip-flops** on Lattice ECP5 because the register interface uses asynchronous dual-port reads.
  - Refactor scratchpad interface to synchronous single-cycle read latency (`reg [31:0] rdata <= mem[addr]`) with Wishbone bus wait-state insertion (`ack` delayed by 1 cycle), enabling Yosys/Nextpnr and Vivado to infer true hardware Block RAM (DP16KD on ECP5, RAMB18/36 on Xilinx).
- **Target FPGA Selection & Justification:**
  - *Primary Target:* Lattice ECP5 `LFE5U-25F-6BG256C` (low-cost, fully open-source Yosys+Nextpnr toolchain, 24k LUTs, 56 EBR blocks, 28 DSP slices).
  - *Secondary / Alternative Target:* AMD/Xilinx Artix-7 `XC7A35T-1CSG324C` (Vivado / openXC7 toolchain, 33k logic cells, 90 DSPs, 50 BRAMs).
- **Place-and-Route & Static Timing Analysis (STA):**
  - Implement top-level constraints file (`syn/constraints/robot_soc.lpf` or `.xdc`).
  - Target system clock frequency: **25.0 MHz to 50.0 MHz**.
  - Execute full synthesis, placement, routing, and timing analysis.
  - Verify zero timing violations ($WNS \ge 0\text{ ns}, TNS = 0\text{ ns}$).

#### 3. Dependencies
- Phase 3/4 validated Verilog RTL.
- FPGA EDA toolchain (Yosys + Nextpnr-ecp5 or Vivado).

#### 4. Acceptance Criteria
1. Scratchpad memory infers dedicated Block RAM (EBR / BRAM), reducing core LUT utilization significantly compared to baseline.
2. Complete place-and-route completes with **0 unrouted nets**.
3. Static Timing Analysis confirms positive setup and hold slack at $\ge 25\text{ MHz}$ under worst-case commercial operating conditions.
4. Bitstream generated successfully.

#### 5. Evidence Requirements
- Verilog RTL commit with BRAM-friendly scratchpad implementation and passing regression suite.
- Nextpnr / Vivado synthesis and PnR log files showing resource utilization (LUTs, FFs, BRAM, DSP) and timing report.
- Reproducible build script (`syn/build_ecp5.sh` or Makefile target).

#### 6. Engineering Gate 5
- **Deliverable:** `docs/17_phase5_fpga_timing_closure_report.md` documenting resource utilization before/after BRAM optimization, critical timing path breakdown, and bitstream artifacts.
- **Review Requirement:** Timing report audit before physical robot integration.

---

### Phase 6 — Physical Robot Integration

#### 1. Objective
Deploy the validated FPGA bitstream onto a physical mobile robot platform, interface real physical sensors and motor drivers, and validate autonomous navigation under deterministic safety constraints with direct human supervision.

#### 2. Technical Scope
- **Physical Hardware Interfaces:**
  - *Sensors:* I2C/SPI or UART peripheral bridge for ToF rangefinders (e.g. VL53L1X / TFmini LiDAR) and 6-DOF IMU (e.g. MPU6050 / BMI088).
  - *Actuators:* Dual H-Bridge motor driver (e.g. TB6612FNG) driven by SoC PWM outputs and directional GPIOs.
  - *Physical Emergency Stop:* Hardware normally-closed push button and physical bumper microswitches wired directly to `pin_estop` with pull-up resistor and RC glitch filter.
- **Deterministic Hardware Safety Testing Protocol:**
  - *Test 1: Tethered / Elevated Run:* Verify wheel speeds, direction, and heartbeat watchdog under zero ground contact.
  - *Test 2: Physical E-Stop Cutoff:* Depress physical E-stop button at full commanded motor speed; verify motor cutoff latency ($< 10\text{ ns}$ asynchronous cutoff to driver disable pins).
  - *Test 3: Hardware Watchdog Timeout:* Intentionally halt CPU via debugger or simulated firmware loop lockup; verify watchdog trips within $50\text{ ms}$ and completely halts motors.
  - *Test 4: Proximity Clamping in Arena:* Command robot toward a wall; verify deterministic software/hardware safety clamp prevents physical impact regardless of neural policy output.
- **Closed-Loop Physical Navigation Testing:**
  - Evaluate physical arena navigation across marked obstacle courses under continuous human observer supervision with dead-man wireless cutoff switch.

#### 3. Dependencies
- Phase 5 verified bitstream and timing closure.
- Physical mobile robot chassis, battery, sensors, and FPGA board.
- Physical safety protocol and human test supervisor.

#### 4. Acceptance Criteria
1. Physical E-stop and bumper switches unconditionally disarm motor outputs within hardware timing specification.
2. Sensor readings are acquired, preprocessed, and ingested into inference pipeline with no I/O bus hangs.
3. Mobile robot demonstrates autonomous collision-free navigation in a physical arena over repeated trials.
4. All real-world safety interventions and telemetry are recorded and analyzed.

#### 5. Evidence Requirements
- Electrical schematic and pin mapping documentation (`docs/schematics/`).
- Sensor calibration and verification logs.
- Physical test log signed by test operator documenting safety cutoff tests, response times, and run outcomes.
- Telemetry logs and video documentation of physical navigation runs.

#### 6. Engineering Gate 6
- **Deliverable:** `docs/18_phase6_physical_robot_report.md` documenting electrical integration, safety certification tests, and physical arena results.
- **Review Requirement:** Final Project Review and Owner Acceptance.

---

## 3. Engineering Gate Review Protocol

Progress between phases is governed by strict engineering gates:
1. **No Speculative Advancements:** A phase cannot be marked complete without reproducible code, automated test passing, and measured metrics committed to the repository.
2. **Dedicated Branch & Pull Request:** Each phase must be developed on a dedicated Git task branch (`flowbot/<phase-name>`).
3. **Owner Approval Required:** Task branches must never be merged to `main` without explicit owner review and approval.
4. **Transparent Risk Reporting:** If unexpected physical or architectural constraints arise, work must stop at the gate and report blockers clearly rather than fabricating results or relaxing safety requirements.
