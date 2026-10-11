# 09. Formal Hardware Semantics and Technical Assumptions

This document formally defines the hardware semantics, numerical representation invariants, and physical timing guarantees for the RISC-V FlowBot SoC. These definitions serve as the ground truth for all verification testbenches and hardening audits.

---

## 1. INT8 Representation and Value Semantics

### 1.1 Number Format
- **Encoding:** Standard two's complement 8-bit signed integer (`signed [7:0]`).
- **Dynamic Range:** Minimum $-128$ (`0x80`), Maximum $+127$ (`0x7F`), Zero $0$ (`0x00`).
- **Symmetric vs. Two's Complement Range:**
  - In symmetric machine learning literature, $-128$ is sometimes avoided because $-(-128) = +128$ cannot be represented in 8-bit signed format without overflow.
  - **Hardware Rule:** The `rv_nna` datapath **fully supports $-128$** (`0x80`) as a valid operand in all MAC operations.
  - $(-128) \times (-128) = +16,384$ (`16'h4000`), which is strictly within the signed 16-bit multiplier output range $[-32,768, +32,767]$.
  - $(-128) \times (+127) = -16,256$ (`16'hC080`), strictly within 16-bit range.

### 1.2 Activation Functions and Output Saturation
The accelerator provides three activation modes via `ACT_TYPE` register:
1. **`ACT_NONE` / `ACT_CLIP` (`0x0` / `0x2`):**
   - Saturated clamping to full signed INT8 range: $[-128, +127]$.
   - If requantized value $V < -128 \implies \text{output} = -128$ (`0x80`).
   - If requantized value $V > +127 \implies \text{output} = +127$ (`0x7F`).
   - If $-128 \le V \le 127 \implies \text{output} = V[7:0]$.
2. **`ACT_RELU` (`0x1`):**
   - Non-negative rectified saturation: $[0, +127]$.
   - If $V < 0 \implies \text{output} = 0$ (`0x00`).
   - If $V > +127 \implies \text{output} = +127$ (`0x7F`).
   - If $0 \le V \le 127 \implies \text{output} = V[7:0]$.
3. **Invalid / Reserved Activation Enums (Default):**
   - Hardware must safely default to saturated INT8 clamping $[-128, +127]$. Wrap-around truncation is prohibited.

### 1.3 Out-of-Bounds Sensor Inputs and NaN Policy
- INT8 has no IEEE 754 NaN or Infinity representation.
- Sensor preprocessing (in firmware running on RV32IM CPU) is strictly responsible for normalizing external physical measurements into valid $[-128, +127]$ features.
- Missing or faulted sensor readings (e.g., sensor timeout) must be deterministically mapped by software to safe invariant states (e.g., obstacle distance $0\text{ m} \to -128$, triggering immediate dynamic stop).

---

## 2. Accumulator Overflow Semantics

### 2.1 Accumulator Headroom
- **Accumulator Width:** 32-bit signed two's complement (`reg signed [31:0] acc`), range $[-2,147,483,648, +2,147,483,647]$.
- **Maximum Theoretical Dot Product for $K=64$ Inputs:**
  $$\text{Max Sum} = 64 \times ((-128) \times (-128)) = 64 \times 16,384 = 1,048,576 \approx 2^{20}$$
- **Headroom:**
  A 32-bit signed accumulator provides $31 - 20 = 11$ bits of mathematical headroom above the maximum possible dot-product sum.
  For all trained models where initial bias $|B| < 2 \times 10^9$, internal accumulator overflow is mathematically impossible during dot-product accumulation.

### 2.2 Overflow Semantics
- **Accumulation (`ST_MAC_CALC`):** Standard two's complement modular addition modulo $2^{32}$. In the adversarial event of an extreme bias loading (e.g. $B = 2^{31}-1$) plus maximum products, the 32-bit accumulator wraps around.
- **Requantization Multiplier (`scaled_acc`):**
  - Accumulator (32-bit signed) is multiplied by 16-bit unsigned scale multiplier `core_scale_mult` (zero-extended to 17-bit positive signed).
  - Intermediate product width is **49-bit signed** (`wire signed [48:0] scaled_acc`).
  - Mathematically: $(2^{31}-1) \times 65,535 \approx 1.407 \times 10^{14} < 2^{48} \approx 2.814 \times 10^{14}$.
  - The 49-bit intermediate product **never overflows or loses precision** during multiplication.
- **Rounding and Right Shift:**
  - Rounding term: $2^{\text{shift}-1}$ if $\text{shift} > 0$, else $0$.
  - Arithmetic right shift (`>>>`) preserves sign.
- **Output Saturation Invariant:**
  - As defined in Section 1.2, the 49-bit post-shift value is unconditionally saturated to the target activation bounds ($[-128, 127]$ or $[0, 127]$). Requantization can never wrap around to an inverted sign.

---

## 3. Deterministic E-Stop Timing and Interlock Semantics

### 3.1 Dual-Path Safety Architecture
The hardware interlock (`safety_filter.v`) enforces deterministic actuator cutoff via two distinct hardware mechanisms:

```
                           +-------------------------------------+
                           | Physical E-Stop Pin / Bumper Sensor |
                           +------------------+------------------+
                                              |
                     +------------------------+-----------------------+
                     | (Path 1: Asynchronous)                         | (Path 2: Synchronous)
                     v                                                v
    +---------------------------------+              +---------------------------------+
    | Asynchronous Combinational Gate |              | Glitch Filter & Latch Register  |
    |   actuator_disarm = 1 (Tpd<10ns)|              |    flag_tripped <= 1'b1         |
    +----------------+----------------+              +----------------+----------------+
                     |                                                |
                     v                                                v
    +---------------------------------+              +---------------------------------+
    | PWM Pad Drive Forced to 0       |              | Latched until CPU Unlock Key    |
    | (Motors enter hi-Z / coast)     |              | (0x5A5A0002 to 0x5000_0600)     |
    +---------------------------------+              +---------------------------------+
```

### 3.2 Exact Timing Invariants
1. **Asynchronous Cutoff Latency ($T_{\text{disarm}}$):**
   - $T_{\text{disarm}} = T_{pd}(\text{pin\_estop} \to \text{actuator\_disarm} \to \text{pwm\_gate}) \le 10\text{ ns}$ (combinational propagation delay through FPGA LUTs).
   - Occurs with **zero clock cycles latency**, even if the CPU clock is stalled, trapped, or halted.
2. **Synchronous Latching Latency ($T_{\text{latch}}$):**
   - The emergency stop event is latched into `flag_tripped` on the first rising clock edge after assertion: $T_{\text{latch}} \le 1\text{ clock cycle}$ ($20\text{ ns}$ at 50 MHz).
   - Once latched, `actuator_disarm` remains asserted even if `pin_estop_button` deasserts.
3. **Watchdog Heartbeat Timing ($T_{\text{watchdog}}$):**
   - Watchdog timer counts down every clock cycle.
   - Default timeout: $1,000,000$ cycles ($20\text{ ms}$ at 50 MHz).
   - If software fails to write `0xA5A50001` before the counter reaches 0, `flag_tripped` asserts on cycle 0 and immediately disarms actuators.
4. **Recovery Protocol:**
   - Motors can only be re-enabled by a deliberate CPU sequence:
     1. Clear physical E-Stop condition.
     2. Write `0x5A5A0002` to `SAFETY_CTRL` (`0x5000_0600`) to clear `flag_tripped`.
     3. Write `0x5A5A0001` to `SAFETY_CTRL` to re-enable watchdog.
     4. Write `0xA5A50001` to `SAFETY_HEARTBEAT` (`0x5000_0604`) to reload counter.
