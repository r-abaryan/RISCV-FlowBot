# 03. SoC Memory Map

## 1. System Memory Space Allocation

The memory architecture uses a flat 32-bit physical address space divided into distinct functional segments:

| Address Range | Size | Region Name | Access | Description |
|---|---|---|---|---|
| `0x0000_0000 - 0x0000_1FFF` | 8 KB | **Boot ROM** | R/X | Reset vector, bootloader, initial diagnostics |
| `0x2000_0000 - 0x2000_FFFF` | 64 KB | **Main SRAM** | R/W/X | Code execution, stack, heap, sensor ring buffers |
| `0x4000_0000 - 0x4000_0FFF` | 4 KB | **Neural Accelerator (`rv_nna`)** | R/W | Control registers and scratchpad buffers |
| `0x5000_0000 - 0x5000_00FF` | 256 B | **System Timer & Watchdog** | R/W | 64-bit microsecond counter and safety watchdog |
| `0x5000_0100 - 0x5000_01FF` | 256 B | **UART Controller** | R/W | Serial TX/RX FIFOs, baud divisor, status |
| `0x5000_0200 - 0x5000_02FF` | 256 B | **GPIO & Encoders** | R/W | General I/O pins and hardware quadrature counters |
| `0x5000_0300 - 0x5000_03FF` | 256 B | **SPI Master** | R/W | High-speed bus for 6-DOF IMU sensor |
| `0x5000_0400 - 0x5000_04FF` | 256 B | **I2C Master** | R/W | Low-speed bus for ToF distance sensors |
| `0x5000_0500 - 0x5000_05FF` | 256 B | **Motor PWM Unit** | R/W | Dual H-bridge PWM generators (speed/dir) |
| `0x5000_0600 - 0x5000_06FF` | 256 B | **Safety Interlock** | R/W | Hardware velocity clamp and watchdog supervisor |

---

## 2. Neural Network Accelerator (`rv_nna`) Detailed Map

Base Address: `0x4000_0000`

### 2.1 Control & Status Registers (Offset `0x0000 - 0x00FF`)

| Offset | Name | Type | Reset | Description |
|---|---|---|---|---|
| `0x0000` | `CTRL` | R/W | `0x00000000` | Bit 0: `START` (Write 1 to trigger inference; self-clearing)<br>Bit 1: `COPY_OUT_TO_IN` (Auto-copy layer output to input buffer for next layer)<br>Bit 2: `IRQ_EN` (Interrupt enable on completion)<br>Bit 3: `SOFT_RESET` (Resets internal FSM and accumulators) |
| `0x0004` | `STATUS` | RO | `0x00000000` | Bit 0: `BUSY` (1 = calculation in progress)<br>Bit 1: `DONE` (1 = calculation finished; cleared on next START or write-1)<br>Bit 2: `ERR` (1 = invalid dimension configuration) |
| `0x0008` | `CONFIG_DIM` | R/W | `0x00000000` | Bits [15:0]: `K_DIM` (Number of inputs, must be multiple of 4, max 64)<br>Bits [31:16]: `M_DIM` (Number of output neurons, max 64) |
| `0x000C` | `CONFIG_ACT` | R/W | `0x00000000` | Bits [1:0]: Activation function:<br>`00` = None / Pass-through<br>`01` = ReLU (`max(0, x)`)<br>`10` = Symmetrical Clip (`[-128, 127]`)<br>`11` = Reserved |
| `0x0010` | `CONFIG_SCALE` | R/W | `0x00010000` | Signed/Unsigned 16-bit multiplier $M_0$ for fixed-point requantization |
| `0x0014` | `CONFIG_SHIFT` | R/W | `0x00000010` | Bits [4:0]: Right-shift amount $n$ (0 to 31) for requantization |
| `0x0018` | `CYCLE_COUNT` | RO | `0x00000000` | Elapsed clock cycles of the most recent layer execution |
| `0x001C` | `INT_CLEAR` | WO | `0x00000000` | Write 1 to clear completion interrupt flag |

### 2.2 Scratchpad Buffers (Offset `0x0100 - 0x0FFF`)

- **Input Vector Buffer (`0x0100 - 0x017F`):**
  - Size: 128 bytes (32 words).
  - Format: Packed 4 x signed INT8 per 32-bit word (`[31:24]=X[3], [23:16]=X[2], [15:8]=X[1], [7:0]=X[0]`).
  - Supports vector lengths up to $K=64$ (or 128 with half-word addressing).

- **Bias Vector Buffer (`0x0200 - 0x02FF`):**
  - Size: 64 words (256 bytes).
  - Format: One signed 32-bit integer per output neuron $m \in [0, M-1]$.

- **Weight Matrix Buffer (`0x0400 - 0x07FF`):**
  - Size: 1024 bytes (256 words).
  - Format: Row-major order. Each 32-bit word contains 4 packed signed INT8 weights:
    `Word = {W[m, k+3], W[m, k+2], W[m, k+1], W[m, k]}`.
  - Accommodates any dense layer where $M \times K \le 1024$ bytes (e.g., $32 \times 32 = 1024$, $64 \times 16 = 1024$, $16 \times 32 = 512$).

- **Output Vector Buffer (`0x0800 - 0x087F`):**
  - Size: 128 bytes (32 words).
  - Format: Packed 4 x signed INT8 per word following requantization and activation.
  - Can also be read as raw 32-bit unquantized accumulators in debug mode at `0x0900 - 0x09FF`.
