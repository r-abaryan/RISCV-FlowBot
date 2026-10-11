# 06. Deterministic Safety Layer Design

## 1. Safety Rationale: Why Neural Policies Must Not Directly Drive Motors

Reinforcement learning policies trained in simulation exhibit known vulnerabilities when deployed on physical robots:
1. **Out-of-Distribution (OOD) Sensor States:** Unexpected reflections, sensor occlusion, or physical bumps can produce observation vectors outside the training distribution, causing unpredictable policy actions.
2. **Lack of Lyapunov Stability / Formal Guarantees:** Neural networks are black-box non-linear approximators with no inherent bounded-input bounded-output (BIBO) stability guarantees.
3. **High-Frequency Chattering:** Unregularized policies may command violent sign reversals in motor torque from one step to the next, destroying motor gears and drawing peak currents that trigger brownouts.
4. **Execution Deadlines:** If the neural inference hangs or takes too long, the robot must not maintain stale velocity commands indefinitely.

Therefore, our architecture implements an **explicit, deterministic safety supervisor layer**. The neural network acts as a *behavioral proposer* (advisory trajectory generator), while the deterministic safety filter acts as the *inviolable governor*.

---

## 2. Multi-Stage Safety Filter Pipeline

```
              +--------------------------+
              | Unverified Policy Output |
              |  [v_raw, w_raw] (INT8)   |
              +-------------+------------+
                            |
                            v
              +--------------------------+
              | Stage 1: Kinematic Clamp |
              |  |v| <= v_max            |
              |  |w| <= w_max            |
              +-------------+------------+
                            |
                            v
              +--------------------------+
              | Stage 2: Slew-Rate Limit | (Dynamic Acceleration Bounds)
              |  |v - v_prev| <= a_max*dt|
              |  |w - w_prev| <= a_w*dt  |
              +-------------+------------+
                            |
                            v
+------------>+--------------------------+
| Sensor Data | Stage 3: Proximity & TTC | (Time-To-Collision Dynamic Brake)
| (ToF/LiDAR) |  d_stop = v^2/(2*a_brake)|
+------------>|  If d < d_stop -> v = 0  |
              +-------------+------------+
                            |
                            v
              +--------------------------+
              | Stage 4: Watchdog Inter- | (Hardware Heartbeat Supervisor)
              | lock & Actuator Dispatch |
              +--------------------------+
```

---

## 3. Mathematical Safety Invariants

### 3.1 Kinematic Limits (Envelope Clamping)
Commanded linear velocity $v$ and angular velocity $\omega$ are strictly bound:
$$v_{c1} = \text{clamp}(v_{\text{raw}}, -v_{\max}, +v_{\max})$$
$$\omega_{c1} = \text{clamp}(\omega_{\text{raw}}, -\omega_{\max}, +\omega_{\max})$$
Typical micro-robot defaults: $v_{\max} = 0.5\text{ m/s}$, $\omega_{\max} = 2.0\text{ rad/s}$.

### 3.2 Dynamic Slew-Rate Clamping (Acceleration Limiting)
To prevent mechanical gear stripping and wheel slippage, rate-of-change between discrete control steps $\Delta t$ is bounded:
$$|\Delta v| = |v_{c1} - v_{k-1}| \le a_{\max} \cdot \Delta t$$
$$v_{c2} = v_{k-1} + \text{clamp}(v_{c1} - v_{k-1}, -a_{\max}\Delta t, +a_{\max}\Delta t)$$
$$\omega_{c2} = \omega_{k-1} + \text{clamp}(\omega_{c1} - \omega_{k-1}, -\alpha_{\max}\Delta t, +\alpha_{\max}\Delta t)$$
Typical defaults: $a_{\max} = 1.0\text{ m/s}^2$, $\alpha_{\max} = 4.0\text{ rad/s}^2$.

### 3.3 Obstacle Proximity & Time-To-Collision (TTC) Dynamic Braking
Given the minimum forward obstacle distance $d_{\min}$ reported by distance sensors:
1. **Critical Stop Threshold:**
   $$d_{\text{stop}}(v) = d_{\text{margin}} + \frac{v_{c2}^2}{2 \cdot a_{\text{brake}}}$$
   where $d_{\text{margin}} = 0.15\text{ m}$ (safety bubble) and $a_{\text{brake}} = 1.5\text{ m/s}^2$.
2. **Velocity Override:**
   - If $d_{\min} \le d_{\text{margin}}$: The robot is dangerously close. Command $v_{c3} = 0.0$, and if $\omega_{c2} == 0$, inject a slow deterministic rotational escape.
   - If $d_{\margin} < d_{\min} < d_{\text{stop}}(v)$: Linearly scale linear velocity:
     $$v_{c3} = v_{c2} \times \left(\frac{d_{\min} - d_{\text{margin}}}{d_{\text{stop}}(v) - d_{\text{margin}}}\right)$$
   - If $d_{\min} \ge d_{\text{stop}}(v)$: No obstacle restriction, $v_{c3} = v_{c2}$.

---

## 4. Hardware Safety Interlock & Watchdog

To protect against CPU crashes, infinite loops, or memory corruption:
1. **Heartbeat Register (`0x5000_0604`):** Software must refresh a countdown timer by writing a specific sequence token every control period (e.g., within 20 ms).
2. **Automatic Actuator Disarm:** If the heartbeat expires, the hardware safety interlock automatically disconnects the software PWM registers and drives the motor outputs to high-impedance / active braking.
3. **Direct E-Stop Pin:** An external hardware bumper or radio emergency-stop line directly asserts the interlock disable line without software intervention.
