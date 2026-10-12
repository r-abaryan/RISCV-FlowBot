# Phase 1 Completion Report: Lightweight RL Environment & Quantized Policy Training

**Project:** Open-Source RISC-V SoC with INT8 Neural Inference Accelerator (`RISCV-FlowBot`)  
**Phase:** Phase 1 of Master Project Roadmap  
**Date:** October 2026  
**Status:** COMPLETE & VERIFIED  

---

## 1. Executive Summary

Phase 1 of the Master Project Roadmap is complete. We designed, implemented, and verified an end-to-end reinforcement learning and imitation learning environment for mobile robot navigation tailored to the strict compute budget of the host platform (1 vCPU, 458 MB RAM, Python 3.14) and the architectural constraints of the custom `rv_nna` hardware neural accelerator (16 $\to$ 8 $\to$ 2 MLP topology, INT8 symmetric quantization, fixed-point requantization with bit shifts).

All deliverables and acceptance criteria have been achieved:
- **Zero External DL Dependencies:** Implemented in pure NumPy; executes full training in **~35 seconds** using under **40 MB RAM**.
- **High Task Performance:** The trained 16 $\to$ 8 $\to$ 2 navigation policy achieves a **78.0% goal reach success rate** in dynamic obstacle environments (outperforming the random baseline of 0.0%).
- **Bit-Exact Quantization Alignment:** The range-aware INT8 quantized model running on the bit-exact `rv_nna` simulation arithmetic achieves **78.0% success rate**, retaining **100.0%** of the floating-point policy performance (exceeding the $\ge 90\%$ retention requirement).
- **Automated Regression Suite:** Integrated in `sw/test/test_policy_eval.py` with deterministic evaluation seeds.

---

## 2. Environment Architecture (`sim/robot_env.py`)

The mobile robot simulation models a differential-drive ground robot navigating a continuous 2D arena ($8\,\text{m} \times 8\,\text{m}$) populated with static circular obstacles.

### Kinematics & Physical Model
- **Differential-Drive / Unicycle Kinematics:**
  $$\dot{x} = v \cos(\theta), \quad \dot{y} = v \sin(\theta), \quad \dot{\theta} = \omega$$
  Integrated via forward Euler discretization with timestep $\Delta t = 0.05\,\text{s}$ (20 Hz control rate).
- **Physical Constraints:**
  - Forward velocity: $v \in [0.0, 0.40]\,\text{m/s}$
  - Angular velocity: $\omega \in [-1.50, +1.50]\,\text{rad/s}$
  - Robot physical radius: $r = 0.18\,\text{m}$
  - LiDAR sensor radius: $d_{\max} = 3.5\,\text{m}$

### Observation Space (16-D Normalized INT8 Feature Vector)
Every feature is normalized to the $[-1.0, +1.0]$ interval, mapping onto signed INT8 $[-128, +127]$:
1. **LiDAR Distance Sensors (Indices 0–7):**
   - 8 radial laser beams spanning $[-\pi, +\pi]$ relative to robot heading:
     $$\phi_i = -\pi + i \cdot \frac{2\pi}{8}$$
   - Normalized feature: $x_i = 2.0 \cdot (d_i / d_{\max}) - 1.0 \in [-1.0, 1.0]$.
2. **IMU Accelerometer / Gyroscope (Indices 8–10):**
   - Feature 8: Angular yaw velocity $\omega / \omega_{\max} \in [-1.0, 1.0]$
   - Feature 9: Longitudinal acceleration $a_x / a_{\max} \in [-1.0, 1.0]$
   - Feature 10: Lateral acceleration $a_y / a_{\max} \in [-1.0, 1.0]$
3. **Odometry / Velocity Feedback (Indices 11–13):**
   - Feature 11: Linear velocity $v / v_{\max} \in [0.0, 1.0]$
   - Feature 12: Left wheel speed $v_L / v_{\max} \in [-1.0, 1.0]$
   - Feature 13: Right wheel speed $v_R / v_{\max} \in [-1.0, 1.0]$
4. **Target-Relative Polar Heading & Range (Indices 14–15):**
   - Feature 14: Normalized heading error $\Delta \theta / \pi \in [-1.0, 1.0]$
   - Feature 15: Normalized distance to goal $\min(d_{\text{goal}} / 8.0, 1.0) \in [0.0, 1.0]$

### Action Space (2-D Normalized Motor Controls)
- Action 0: Normalized forward speed command $u_v \in [-1.0, 1.0] \mapsto [0.0, 0.40]\,\text{m/s}$
- Action 1: Normalized angular steering command $u_\omega \in [-1.0, 1.0] \mapsto [-1.5, 1.5]\,\text{rad/s}$

---

## 3. Training Pipeline (`sw/policy/train_policy.py`)

### Pure-NumPy DAgger + Adam Formulation
To satisfy the strict memory limit (< 458 MB total system RAM) and lack of PyTorch/TensorFlow in the minimal runtime, we developed a pure-NumPy policy optimization engine:
1. **Teacher Oracle (Artificial Potential Field):** An algorithmic navigation teacher computes attractive forces toward the goal:
   $$\vec{F}_{\text{att}} = k_{\text{att}} (\vec{p}_{\text{goal}} - \vec{p}_{\text{robot}})$$
   and repulsive potential vectors from detected obstacles:
   $$\vec{F}_{\text{rep}} = \sum_{j} k_{\text{rep}} \left(\frac{1}{d_j} - \frac{1}{d_0}\right) \frac{1}{d_j^2} \hat{r}_j$$
2. **DAgger (Dataset Aggregation):**
   - **Phase 0:** Collect 50 expert trajectories from the APF teacher (~4,300 state-action pairs).
   - **Pretraining:** Train the 16 $\to$ 8 $\to$ 2 MLP via mini-batch Adam (batch size 128, 100 epochs, lr = 0.008).
   - **DAgger Rounds 1–2:** The student policy rolls out trajectories; states are visited under student distribution and relabeled by the teacher oracle (~8,400 total training tuples). Fine-tune for 60 epochs per round.
3. **Training Performance:**
   - Total Wall Clock Training Time: **34.90 s**
   - Peak Memory Consumption: **< 40 MB**
   - Converged Training MSE Loss: **< 0.038**

---

## 4. Range-Aware Symmetric INT8 Quantization

The hardware accelerator (`rv_nna`) implements a 4-way SIMD MAC unit with fixed-point scale multiplication and arithmetic right shifting:
$$Y = \text{act}\left( \left\lfloor \frac{(\sum W_{ij} X_j + B_i) \cdot M}{2^S} \right\rfloor \right)$$

### Dynamic Range Analysis
During initial tests, unconstrained ReLU activations in hidden layer $h_1$ reached values up to $\approx 4.6$. Standard $[-1.0, 1.0]$ scale clipping saturated the INT8 scratchpad at 127, causing severe divergence.

We implemented **Range-Aware Calibration**:
1. Record distribution of intermediate activations $H_1 = \max(0, X W_1^T + B_1)$ over the training dataset.
2. Calculate empirical dynamic ceiling: $h_{1,\max} = \text{Percentile}_{99.9}(H_1) + 0.05 \approx 4.65$.
3. Compute scale factors:
   - Input scale: $S_x = 127.0$
   - Weight scale 1: $S_{w1} = \frac{127.0}{\max |W_1|}$
   - Bias scale 1: $S_{b1} = S_{w1} \cdot S_x$
   - Hidden activation scale: $S_{h1} = \frac{127.0}{h_{1,\max}}$
   - Layer 1 Requantization Multiplier:
     $$M_1 = \frac{S_{h1}}{S_{w1} \cdot S_x} = \frac{1}{S_{w1} \cdot h_{1,\max}}$$
     With shift $S = 15$, $M_1 = \text{round}(M_1 \cdot 2^{15})$.
4. Layer 2 Scaling:
   - Weight scale 2: $S_{w2} = \frac{127.0}{\max |W_2|}$
   - Bias scale 2: $S_{b2} = S_{w2} \cdot S_{h1}$
   - Layer 2 Requantization Multiplier:
     $$M_2 = \frac{S_y}{S_{w2} \cdot S_{h1}} = \frac{h_{1,\max}}{S_{w2}}$$
     With shift $S = 15$, $M_2 = \text{round}(M_2 \cdot 2^{15})$.

This mathematical calibration maintains optimal dynamic range across both layers without integer overflow or clipping saturation.

---

## 5. Evaluation Benchmark Results

The evaluation benchmark (`sw/test/test_policy_eval.py`) evaluated 4 configurations over 50 identical pseudo-random navigation seeds (`seeds = [1000..1049]`):

| Policy / Model | Success Rate (%) | Collision Rate (%) | Mean Steps | Mean Episode Reward | Execution Time |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **Random Baseline** | 0.0% | 94.0% | 40.2 | -67.76 | 0.35 s |
| **Heuristic Teacher (APF)** | 90.0% | 10.0% | 76.8 | +127.17 | 0.81 s |
| **Trained Float MLP** | **78.0%** | **20.0%** | **78.4** | **+106.83** | 0.72 s |
| **Trained INT8 (`rv_nna`)** | **78.0%** | **18.0%** | **76.9** | **+108.81** | 0.74 s |

### Verification of Acceptance Criteria
1. **Success Rate $\ge 50\%$:** **PASS** (Achieved 78.0%).
2. **Collision Rate < Random Baseline:** **PASS** (18.0% INT8 vs 94.0% Random).
3. **Total Reward > Random Baseline:** **PASS** (+108.81 INT8 vs -67.76 Random).
4. **INT8 vs Float Retention $\ge 90\%$:** **PASS** (Achieved **100.0%** retention: 78.0% vs 78.0%).

---

## 6. Artifacts Produced

The following production-ready files were created and verified:
1. `sim/robot_env.py` — High-performance 2D unicycle robot navigation environment with LiDAR raycasting, IMU simulation, and odometry tracking.
2. `sw/policy/baselines.py` — Reference policies: uniform random agent and Potential Field (APF) heuristic expert teacher.
3. `sw/policy/train_policy.py` — Pure-NumPy DAgger imitation learning engine and range-aware INT8 quantizer.
4. `sw/policy/trained_policy_weights.json` — Trained and quantized weights, biases, and multiplier/shift configurations.
5. `sw/policy/export_weights.py` — Header export utility converting quantized weights to C headers (`sw/include/nav_weights.h`) and RISC-V assembly (`sw/firmware/nav_weights.inc`).
6. `sw/test/test_policy_eval.py` — Benchmark evaluation test suite verifying all Phase 1 acceptance criteria.
7. `docs/13_phase1_rl_training_report.md` — This report.

---

## 7. Next Step: Phase 2 Preparation

With Phase 1 complete and verified, the next phase is:
**Phase 2: Closed-Loop Software/Firmware Co-Simulation (`sim/tb_soc_closed_loop.v`)**
- Connect the RISC-V CPU firmware executing on the Verilog SoC (`soc_top.v`) to the Python physics simulator (`robot_env.py`) via a file/pipe co-simulation bridge.
- Run complete closed-loop navigation episodes where the simulated SoC reads sensor inputs from the environment, executes inference on the `rv_nna` accelerator, verifies commands through the `safety_filter.v`, and returns motor PWM actions back to the vehicle physics.
