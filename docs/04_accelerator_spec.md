# 04. Neural Accelerator Architecture (`rv_nna`)

## 1. Accelerator Architectural Overview

The `rv_nna` accelerator is a memory-mapped, fixed-point Matrix-Vector Engine optimized for dense (fully connected) neural network layer inference. Mobile robot reinforcement learning policies are typically compact 2–3 layer Multi-Layer Perceptrons (MLPs). The inference workload is strictly memory-bandwidth and dot-product bound, not convolution-bound.

The accelerator performs the core GEMV (General Matrix-Vector Multiply) calculation:
$$Y = \sigma \left( \left\lfloor \frac{(W \cdot X + B) \times S}{2^N} \right\rfloor \right)$$

where:
- $X \in \mathbb{Z}^{K}$ (Input activation vector, signed INT8)
- $W \in \mathbb{Z}^{M \times K}$ (Weight matrix, signed INT8)
- $B \in \mathbb{Z}^{M}$ (Bias vector, signed INT32)
- $S \in \mathbb{Z}$ (16-bit fixed-point multiplier scale)
- $N \in [0, 31]$ (Arithmetic right shift)
- $\sigma$ (Activation function: Passthrough, ReLU, or Clamp)
- $Y \in \mathbb{Z}^{M}$ (Output activation vector, signed INT8)

---

## 2. Microarchitecture Datapath

```
                                  +---------------------------+
                                  |    Input Vector Buffer    |
                                  |       (32 x 32-bit)       |
                                  +-------------+-------------+
                                                |
                                        4 x INT8| X[k+3:k]
                                                v
+--------------------------+          +---------+---------+
|    Weight Matrix Buffer  |--------->|   4-way INT8      |
|      (256 x 32-bit)      | 4 x INT8 | Multiply Unit     |
+--------------------------+ W[m,k+3:k]+---------+---------+
                                                | 4 x INT16 Products
                                                v
                                      +---------+---------+
                                      | 4-input Adder Tree|
                                      +---------+---------+
                                                | 18-bit partial sum
                                                v
+--------------------------+          +---------+---------+
|    Bias Vector Buffer    |--------->|  32-bit Saturating|
|       (64 x 32-bit)      |  INT32   |    Accumulator    |<---+ (Feedback)
+--------------------------+          +---------+---------+    |
                                                |              |
                                                +--------------+
                                                |
                                                v 32-bit Acc
                                      +---------+---------+
                                      | Fixed-Point Scale | (Acc * S)
                                      | & Rounding Shifter| >> N
                                      +---------+---------+
                                                |
                                                v
                                      +---------+---------+
                                      | Activation Unit   | (Passthrough / ReLU /
                                      |  & INT8 Saturator |  Symmetric Clamp)
                                      +---------+---------+
                                                | 8-bit output
                                                v
                                      +---------+---------+
                                      | Output Pack/Buffer|
                                      |   (32 x 32-bit)   |
                                      +-------------------+
```

---

## 3. Detailed Datapath Elements

### 3.1 4-Way INT8 Dot-Product Engine (`nna_mac4`)
Every cycle during the inner loop, four 8-bit signed activations ($X_0, X_1, X_2, X_3$) and four 8-bit signed weights ($W_0, W_1, W_2, W_3$) are unpacked from two 32-bit words:
$$\text{Prod}_i = W_i \times X_i \quad (i = 0, 1, 2, 3)$$
$$\text{Sum}_4 = \text{Prod}_0 + \text{Prod}_1 + \text{Prod}_2 + \text{Prod}_3$$
Each product $\text{Prod}_i$ is a signed 16-bit integer (range: $-128 \times 127 = -16256$ to $-128 \times -128 = +16384$). The sum $\text{Sum}_4$ fits safely within 18 bits.

### 3.2 32-Bit Accumulator
The accumulator initializes with the 32-bit bias $B_m$ for output neuron $m$:
$$\text{Acc}_m \leftarrow B_m$$
For every group of 4 inputs, it accumulates:
$$\text{Acc}_m \leftarrow \text{Acc}_m + \text{Sum}_4$$
A 32-bit signed integer accommodates up to $2^{31}-1 \approx 2.14 \times 10^9$, completely eliminating overflow even for long vectors ($K > 1000$).

### 3.3 Requantization and Rounding Unit
After all $K$ inputs for neuron $m$ have been accumulated, the 32-bit accumulator is requantized back to 8-bit:
$$\text{Scaled} = \text{Acc}_m \times S_{\text{mult}}$$
$$\text{Rounded} = \text{Scaled} + \left(1 \ll (S_{\text{shift}} - 1)\right) \quad (\text{if } S_{\text{shift}} > 0)$$
$$\text{Requant} = \text{Rounded} \gg S_{\text{shift}}$$
This matches standard symmetric integer quantization (e.g., Google TensorFlow Lite / PyTorch `gemmlowp` standard).

### 3.4 Activation and Clamping Unit
The requantized integer is passed through the configurable non-linear activation unit:
- **Passthrough / Linear (Act = 0):**
  $$\text{Out} = \text{clamp}(\text{Requant}, -128, 127)$$
- **ReLU (Act = 1):**
  $$\text{Out} = \text{clamp}(\text{Requant}, 0, 127)$$
- **Symmetric Saturated Linear (Act = 2):**
  $$\text{Out} = \text{clamp}(\text{Requant}, -128, 127)$$

---

## 4. Sequencing Finite State Machine (FSM)

The control logic runs through five operational states:

1. **`ST_IDLE`:** Waiting for software to write `1` to `CTRL[0] (START)`. Reset counters: $m = 0, k = 0$.
2. **`ST_INIT_NEURON`:** Read $B_m$ from the Bias buffer, pre-load the 32-bit accumulator. Set $k = 0$.
3. **`ST_MAC_LOOP`:**
   - Fetch $X[k \dots k+3]$ from Input Buffer and $W[m, k \dots k+3]$ from Weight Buffer.
   - Execute 4-way MAC, add to accumulator.
   - Advance $k \leftarrow k + 4$.
   - If $k < K_{\text{dim}}$, repeat `ST_MAC_LOOP`.
   - If $k == K_{\text{dim}}$, proceed to `ST_POST_PROC`.
4. **`ST_POST_PROC`:**
   - Apply fixed-point scale multiplication, rounding shift, and activation clamp.
   - Pack 8-bit result into the output word buffer at index $m$.
   - Increment $m \leftarrow m + 1$.
   - If $m < M_{\text{dim}}$, loop back to `ST_INIT_NEURON`.
   - If $m == M_{\text{dim}}$, transition to `ST_DONE`.
5. **`ST_DONE`:**
   - If `CTRL[1]` (`COPY_OUT_TO_IN`) is set, auto-transfer output vector to input buffer for consecutive layer execution.
   - Set `STATUS[1] (DONE)` and clear `STATUS[0] (BUSY)`.
   - Assert interrupt line `irq` if `CTRL[2] (IRQ_EN)` is high.
   - Return to `ST_IDLE`.

---

## 5. Execution Latency Calculation

For a dense layer with $K$ inputs (multiple of 4) and $M$ output neurons:
$$\text{Cycles per neuron} = 1 \; (\text{Bias Load}) + \left(\frac{K}{4}\right) \; (\text{MAC steps}) + 1 \; (\text{Requant/Store}) = 2 + \frac{K}{4}$$
$$\text{Total Layer Latency} = M \times \left(2 + \frac{K}{4}\right) + 2 \; (\text{FSM overhead})$$

### Concrete Example: Mobile Robot Policy MLP
- **Input layer to Hidden 1:** $K = 16$, $M = 32$:
  $$\text{Cycles} = 32 \times (2 + 4) + 2 = 194 \text{ cycles}$$
- **Hidden 1 to Hidden 2:** $K = 32$, $M = 16$:
  $$\text{Cycles} = 16 \times (2 + 8) + 2 = 162 \text{ cycles}$$
- **Hidden 2 to Output:** $K = 16$, $M = 2$:
  $$\text{Cycles} = 2 \times (2 + 4) + 2 = 14 \text{ cycles}$$
- **Total Network Inference Latency:** $194 + 162 + 14 = 370 \text{ clock cycles}$!

At a **50 MHz clock**, 370 cycles equals **7.4 microseconds**.
At a **25 MHz clock**, 370 cycles equals **14.8 microseconds**.
Even with software register configuration overhead, full policy inference takes less than **25 microseconds**, which leaves **97.5% of CPU time free** in a 1,000 Hz (1 ms) robot control loop!
