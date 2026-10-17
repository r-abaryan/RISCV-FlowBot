/**
 * @file soc_regs.h
 * @brief Memory map and register definitions for RV32IM Mobile Robot SoC.
 */

#ifndef SOC_REGS_H
#define SOC_REGS_H

#include <stdint.h>

#define REG32(addr) (*(volatile uint32_t *)(uintptr_t)(addr))

/* Base Addresses */
#define ADDR_ROM_BASE       0x00000000U
#define ADDR_RAM_BASE       0x20000000U
#define ADDR_NNA_BASE       0x40000000U
#define ADDR_TIMER_BASE     0x50000000U
#define ADDR_UART_BASE      0x50000100U
#define ADDR_PWM_BASE       0x50000500U
#define ADDR_SAFETY_BASE    0x50000600U

/* NNA Register Offsets */
#define NNA_REG_CTRL        (ADDR_NNA_BASE + 0x000U)
#define NNA_REG_STATUS      (ADDR_NNA_BASE + 0x004U)
#define NNA_REG_CONFIG_DIM  (ADDR_NNA_BASE + 0x008U)
#define NNA_REG_CONFIG_ACT  (ADDR_NNA_BASE + 0x00CU)
#define NNA_REG_CONFIG_SCALE (ADDR_NNA_BASE + 0x010U)
#define NNA_REG_CONFIG_SHIFT (ADDR_NNA_BASE + 0x014U)
#define NNA_REG_PERF_CYCLES (ADDR_NNA_BASE + 0x018U)
#define NNA_REG_INT_CLEAR   (ADDR_NNA_BASE + 0x01CU)
#define NNA_BUF_IN          (ADDR_NNA_BASE + 0x100U)
#define NNA_BUF_BIAS        (ADDR_NNA_BASE + 0x200U)
#define NNA_BUF_WEIGHT      (ADDR_NNA_BASE + 0x400U)
#define NNA_BUF_OUT         (ADDR_NNA_BASE + 0x800U)

/* NNA Control / Status Bits */
#define NNA_CTRL_START      (1U << 0)
#define NNA_CTRL_IRQ_EN     (1U << 1)
#define NNA_STATUS_BUSY     (1U << 0)
#define NNA_STATUS_DONE     (1U << 1)

#define NNA_ACT_NONE        0U
#define NNA_ACT_RELU        1U
#define NNA_ACT_CLIP        2U

/* Timer Registers */
#define TIMER_REG_CYCLES_LO (ADDR_TIMER_BASE + 0x00U)
#define TIMER_REG_CYCLES_HI (ADDR_TIMER_BASE + 0x04U)
#define TIMER_REG_CMP_LO    (ADDR_TIMER_BASE + 0x08U)
#define TIMER_REG_CMP_HI    (ADDR_TIMER_BASE + 0x0CU)
#define TIMER_REG_CTRL      (ADDR_TIMER_BASE + 0x10U)

/* UART Registers */
#define UART_REG_TXDATA     (ADDR_UART_BASE + 0x00U)
#define UART_REG_RXDATA     (ADDR_UART_BASE + 0x04U)
#define UART_REG_STATUS     (ADDR_UART_BASE + 0x08U)
#define UART_REG_BAUD       (ADDR_UART_BASE + 0x0CU)
#define UART_STATUS_TX_BUSY (1U << 0)
#define UART_STATUS_RX_VALID (1U << 1)  /* reserved, reads 0 (no RX) */
#define UART_STATUS_TX_OVERRUN (1U << 2) /* sticky; write 1 to clear (W1C) */

/* PWM Registers */
#define PWM_REG_PERIOD      (ADDR_PWM_BASE + 0x00U)
#define PWM_REG_DUTY_LEFT   (ADDR_PWM_BASE + 0x04U)
#define PWM_REG_DUTY_RIGHT  (ADDR_PWM_BASE + 0x08U)
#define PWM_REG_CTRL        (ADDR_PWM_BASE + 0x0CU)
#define PWM_CTRL_ENABLE     (1U << 0)

/* Safety Interlock Registers */
#define SAFETY_REG_STATUS   (ADDR_SAFETY_BASE + 0x00U)
#define SAFETY_REG_WD_LIMIT (ADDR_SAFETY_BASE + 0x04U)
#define SAFETY_REG_PET      (ADDR_SAFETY_BASE + 0x08U)
#define SAFETY_REG_FORCE    (ADDR_SAFETY_BASE + 0x0CU)
#define SAFETY_REG_CLEAR    (ADDR_SAFETY_BASE + 0x10U)

#define SAFETY_STATUS_DISARM (1U << 0)
#define SAFETY_STATUS_WD_TRIP (1U << 1)
#define SAFETY_STATUS_ESTOP  (1U << 2)
#define SAFETY_STATUS_SW_TRIP (1U << 3)
#define SAFETY_STATUS_WD_EN  (1U << 4)

#define SAFETY_KEY_PET      0x5AFEC0DEU
#define SAFETY_KEY_FORCE    0xDEADBEEFU
#define SAFETY_KEY_CLEAR    0x5AFEC1EAU

#endif /* SOC_REGS_H */
