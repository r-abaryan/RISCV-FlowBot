// ============================================================================
// File: soc_regs.h
// Description: Peripheral Base Addresses and MMIO Register Offsets for Robot SoC
// ============================================================================

#ifndef SOC_REGS_H
#define SOC_REGS_H

#include <stdint.h>

#define REG32(addr) (*((volatile uint32_t *)(addr)))

// ----------------------------------------------------------------------------
// Base Addresses
// ----------------------------------------------------------------------------
#define ROM_BASE             0x00000000
#define RAM_BASE             0x20000000
#define NNA_BASE             0x40000000
#define TIMER_BASE           0x50000000
#define UART_BASE            0x50000100
#define PWM_BASE             0x50000200
#define SAFETY_BASE          0x50000600

// ----------------------------------------------------------------------------
// rv_nna Accelerator Registers (0x4000_0000)
// ----------------------------------------------------------------------------
#define NNA_REG_CTRL         REG32(NNA_BASE + 0x000)
#define NNA_REG_STATUS       REG32(NNA_BASE + 0x004)
#define NNA_REG_CFG_DIM      REG32(NNA_BASE + 0x008)
#define NNA_REG_CFG_SCALE    REG32(NNA_BASE + 0x00C)
#define NNA_REG_CFG_BIAS     REG32(NNA_BASE + 0x010)
#define NNA_REG_SP_WR_ADDR   REG32(NNA_BASE + 0x014)
#define NNA_REG_SP_WR_DATA   REG32(NNA_BASE + 0x018)
#define NNA_REG_SP_RD_ADDR   REG32(NNA_BASE + 0x01C)
#define NNA_REG_SP_RD_DATA   REG32(NNA_BASE + 0x020)
#define NNA_REG_PERF_CYCLES  REG32(NNA_BASE + 0x024)

#define NNA_CTRL_START_BIT   (1 << 0)
#define NNA_CTRL_RESET_BIT   (1 << 1)
#define NNA_CTRL_RELU_BIT    (1 << 2)

#define NNA_STATUS_BUSY_BIT  (1 << 0)
#define NNA_STATUS_DONE_BIT  (1 << 1)

// ----------------------------------------------------------------------------
// Deterministic Hardware Safety Filter Registers (0x5000_0600)
// ----------------------------------------------------------------------------
// Offsets verified against rtl/safety/safety_filter.v (M7A).
#define SAFETY_REG_CTRL      REG32(SAFETY_BASE + 0x000)  // bit0 enable (reset=1), bit1 W1 clear trip
#define SAFETY_REG_HEARTBEAT REG32(SAFETY_BASE + 0x004)  // write: key reloads wdog; read: countdown
#define SAFETY_REG_STATUS    REG32(SAFETY_BASE + 0x008)  // RO: b0 enable,b1 tripped,b2 wdt_expired,b3 estop pin
#define SAFETY_REG_TIMEOUT   REG32(SAFETY_BASE + 0x00C)  // watchdog reload value (cycles)

#define SAFETY_HEARTBEAT_KEY 0x5AFEC0DE
#define SAFETY_CTRL_ENABLE   (1u << 0)
#define SAFETY_CTRL_CLEAR    (1u << 1)
#define SAFETY_STATUS_ENABLE (1u << 0)
#define SAFETY_STATUS_TRIPPED (1u << 1)
#define SAFETY_STATUS_WDT    (1u << 2)
#define SAFETY_STATUS_ESTOP  (1u << 3)

// ----------------------------------------------------------------------------
// Timer Registers (0x5000_0000)
// ----------------------------------------------------------------------------
#define TIMER_REG_MTIME_LO   REG32(TIMER_BASE + 0x000)
#define TIMER_REG_MTIME_HI   REG32(TIMER_BASE + 0x004)
#define TIMER_REG_CMP_LO     REG32(TIMER_BASE + 0x008)
#define TIMER_REG_CMP_HI     REG32(TIMER_BASE + 0x00C)
#define TIMER_REG_CTRL       REG32(TIMER_BASE + 0x010)

// ----------------------------------------------------------------------------
// UART Diagnostic Console Registers (0x5000_0100)
// ----------------------------------------------------------------------------
#define UART_REG_TXDATA      REG32(UART_BASE + 0x000)
#define UART_REG_RXDATA      REG32(UART_BASE + 0x004)  // reads 0 (no receiver)
#define UART_REG_STATUS      REG32(UART_BASE + 0x008)  // bit0 TX_BUSY, bit1 reserved, bit2 TX_OVERRUN (W1C)
#define UART_REG_BAUD        REG32(UART_BASE + 0x00C)  // reads 0, writes ignored (fixed divider)
#define UART_STATUS_TX_BUSY    (1u << 0)
#define UART_STATUS_TX_OVERRUN (1u << 2)

// ----------------------------------------------------------------------------
// Motor PWM Registers (0x5000_0200)
// ----------------------------------------------------------------------------
#define PWM_REG_CTRL         REG32(PWM_BASE + 0x000)
#define PWM_REG_LEFT_DUTY    REG32(PWM_BASE + 0x004)
#define PWM_REG_RIGHT_DUTY   REG32(PWM_BASE + 0x008)
#define PWM_REG_STATUS       REG32(PWM_BASE + 0x00C)

#endif // SOC_REGS_H
