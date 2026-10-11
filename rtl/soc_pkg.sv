// ============================================================================
// RISC-V Robot SoC Package Definitions
// ============================================================================
`ifndef SOC_PKG_SV
`define SOC_PKG_SV

// Memory Map Bases (Base 32-bit addresses)
`define ADDR_ROM_BASE       32'h0000_0000
`define ADDR_RAM_BASE       32'h2000_0000
`define ADDR_NNA_BASE       32'h4000_0000
`define ADDR_TIMER_BASE     32'h5000_0000
`define ADDR_UART_BASE      32'h5000_0100
`define ADDR_GPIO_BASE      32'h5000_0200
`define ADDR_PWM_BASE       32'h5000_0500
`define ADDR_SAFETY_BASE    32'h5000_0600

// NNA Accelerator Register Offsets (relative to ADDR_NNA_BASE)
`define NNA_REG_CTRL        12'h000
`define NNA_REG_STATUS      12'h004
`define NNA_REG_CONFIG_DIM  12'h008
`define NNA_REG_CONFIG_ACT  12'h00C
`define NNA_REG_CONFIG_SCALE 12'h010
`define NNA_REG_CONFIG_SHIFT 12'h014
`define NNA_REG_PERF_CYCLES 12'h018
`define NNA_REG_INT_CLEAR   12'h01C

// NNA Memory Buffer Ranges
`define NNA_IN_BUF_BASE     12'h100   // 32 words (128 bytes)
`define NNA_BIAS_BUF_BASE   12'h200   // 64 words (256 bytes)
`define NNA_WEIGHT_BUF_BASE 12'h400   // 256 words (1024 bytes)
`define NNA_OUT_BUF_BASE    12'h800   // 32 words (128 bytes)

// Activation Types
`define ACT_PASSTHROUGH     2'b00
`define ACT_RELU            2'b01
`define ACT_CLIP            2'b10

`endif // SOC_PKG_SV
