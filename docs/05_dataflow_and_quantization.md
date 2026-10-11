# 05. Data Flow and INT8 Quantization Format

## 1. End-to-End Control Pipeline

The mobile robot control loop runs periodically at 200 Hz to 1000 Hz (1–5 ms period). The figure below traces data from physical sensors, through the software stack and hardware accelerator, down to the motor drivers:

```
+-----------------------------------------------------------------------------------+
| 1. SENSOR ACQUISITION & ESTIMATION (CPU Drivers & DSP)                            |
|    - 8x ToF / Ultrasonic ranges [meters]                                          |
|    - IMU Gyro yaw-rate [rad/s], Accel [m/s^2]                                     |
|    - Wheel encoders -> Odometry linear & angular velocity [m/s, rad/s]            |
|    - Goal relative coordinates (dx, dy) [meters]                                  |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| 2. FEATURE NORMALIZATION & INT8 QUANTIZATION (CPU Core)                           |
|    - Normalize features into continuous [-1.0, +1.0] range                        |
|    - Quantize: X_int8[i] = clamp(round(feature[i] * 127.0), -128, 127)            |
|    - Pack into 32-bit words and write to NNA Input Buffer (0x4000_0100)           |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| 3. NEURAL ACCELERATOR INFERENCE (`rv_nna`)                                        |
|    - Layer 1 (16 in -> 32 hidden, ReLU) [~194 cycles]                             |
|    - Layer 2 (32 in -> 16 hidden, ReLU) [~162 cycles]                             |
|    - Layer 3 (16 in -> 2 actions: [v_raw, w_raw], Linear/Clip) [~14 cycles]       |
|    - Total latency: ~370 cycles (< 10 us at 50 MHz)                               |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| 4. RAW ACTION UNPACKING & DEQUANTIZATION (CPU Core)                               |
|    - Read action vector from NNA Output Buffer (0x4000_0800)                      |
|    - Dequantize: v_cmd_raw = action[0] * v_scale, w_cmd_raw = action[1] * w_scale |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| 5. DETERMINISTIC SAFETY FILTER & SANITIZER (CPU Supervisor)                       |
|    - Check Policy Inference Watchdog (did inference finish on time?)              |
|    - Absolute Velocity Limit: |v| <= v_max, |w| <= w_max                          |
|    - Slew Rate / Acceleration Clamping: |dv/dt| <= a_max                          |
|    - Obstacle Proximity & Time-To-Collision (TTC) Dynamic Braking                 |
|    - Fail-Safe Override: If danger detected -> Force safe stop or turn            |
+-----------------------------------------+-----------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
| 6. HARDWARE ACTUATION (PWM & Direction Interlock)                                 |
|    - Write sanitized setpoints to Motor PWM registers                            |
|    - Generate complementary H-Bridge pulses for Left & Right drive motors         |
+-----------------------------------------------------------------------------------+
```

---

## 2. Proposed INT8 Quantization Scheme

### 2.1 Symmetric vs. Asymmetric Quantization Tradeoff
In neural network quantization:
- **Asymmetric Quantization (uint8):**
  $$q = \text{round}\left(\frac{r}{S}\right) + Z$$
  Requires non-zero zero-point offsets $Z_w$ and $Z_x$. During matrix multiplication:
  $$\sum (W_i - Z_w)(X_i - Z_x) = \sum W_i X_i - Z_w \sum X_i - Z_x \sum W_i + K Z_w Z_x$$
  This creates three additional correction cross-terms that must be accumulated per row, adding significant register storage, adder overhead, and logic area on an FPGA.

- **Symmetric Signed Quantization (int8):**
  $$q = \text{clamp}\left(\text{round}\left(\frac{r}{S}\right), -128, 127\right) \quad \text{with } Z = 0$$
  Since zero-points $Z_w = 0$ and $Z_x = 0$, all cross-terms vanish:
  $$\sum (W_i - 0)(X_i - 0) = \sum_{i} W_i \cdot X_i$$
  **Decision:** We adopt **Symmetric Signed INT8 Quantization** for both activations and weights. This reduces FPGA arithmetic resources by over 40% and simplifies datapath verification while matching modern RL training frameworks (PyTorch FX Quantization, TFLite).

### 2.2 Mathematical Quantization Specification
1. **Weights ($W$):**
   - Stored in off-line pre-trained tables.
   - Scaled such that $W_{int8} \in [-127, +127]$.
   - Scale factor: $S_W = \frac{\max(|W|)}{127.0}$.
2. **Activations ($X$):**
   - Normalized in range $[-128, +127]$.
   - Scale factor: $S_X$.
3. **Biases ($B$):**
   - Represented as 32-bit signed integers ($B_{int32}$).
   - Scale factor: $S_B = S_W \times S_X$.
   - $B_{int32} = \text{round}\left(\frac{B_{float}}{S_B}\right)$.
4. **Output Scale and Requantization:**
   To requantize the 32-bit accumulated sum $\text{Acc}$ back to INT8 for the subsequent layer:
   $$S_{req} = \frac{S_W \times S_X}{S_{Y}} \approx \frac{M_0}{2^N}$$
   where:
   - $M_0 \in [1, 65535]$ is a 16-bit integer multiplier (stored in `CONFIG_SCALE`).
   - $N \in [0, 31]$ is an integer right shift amount (stored in `CONFIG_SHIFT`).
   - Rounding rule:
     $$Y_{int8} = \text{clamp}\left(\left\lfloor \frac{\text{Acc} \times M_0 + 2^{N-1}}{2^N} \right\rfloor, -128, 127\right)$$
