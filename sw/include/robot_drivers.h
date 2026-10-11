/**
 * @file robot_drivers.h
 * @brief High-level hardware abstraction layer for Robot SoC peripherals.
 */

#ifndef ROBOT_DRIVERS_H
#define ROBOT_DRIVERS_H

#include "soc_regs.h"

/* ============================================================================
 * UART Functions
 * ============================================================================ */
static inline void uart_putc(char c) {
    while (REG32(UART_REG_STATUS) & UART_STATUS_TX_BUSY) {
        /* wait */
    }
    REG32(UART_REG_TXDATA) = (uint32_t)(uint8_t)c;
}

static inline void uart_puts(const char *s) {
    while (*s) {
        uart_putc(*s++);
    }
}

static inline void uart_puthex(uint32_t val) {
    const char hex_chars[] = "0123456789ABCDEF";
    for (int i = 7; i >= 0; i--) {
        uart_putc(hex_chars[(val >> (i * 4)) & 0xF]);
    }
}

/* ============================================================================
 * Safety Interlock Functions
 * ============================================================================ */
static inline void safety_init(uint32_t wd_limit) {
    REG32(SAFETY_REG_WD_LIMIT) = wd_limit;
    REG32(SAFETY_REG_PET) = SAFETY_KEY_PET;
    REG32(SAFETY_REG_CLEAR) = SAFETY_KEY_CLEAR;
}

static inline void safety_pet_watchdog(void) {
    REG32(SAFETY_REG_PET) = SAFETY_KEY_PET;
}

static inline void safety_emergency_stop(void) {
    REG32(SAFETY_REG_FORCE) = SAFETY_KEY_FORCE;
}

static inline uint32_t safety_get_status(void) {
    return REG32(SAFETY_REG_STATUS);
}

static inline int safety_is_armed(void) {
    return !(REG32(SAFETY_REG_STATUS) & SAFETY_STATUS_DISARM);
}

/* ============================================================================
 * PWM Actuator Functions
 * ============================================================================ */
static inline void pwm_init(uint32_t period) {
    REG32(PWM_REG_PERIOD) = period;
    REG32(PWM_REG_DUTY_LEFT) = 0;
    REG32(PWM_REG_DUTY_RIGHT) = 0;
    REG32(PWM_REG_CTRL) = PWM_CTRL_ENABLE;
}

static inline void pwm_set_motors(uint32_t left_duty, uint32_t right_duty) {
    REG32(PWM_REG_DUTY_LEFT) = left_duty;
    REG32(PWM_REG_DUTY_RIGHT) = right_duty;
}

/* ============================================================================
 * Neural Accelerator (rv_nna) Functions
 * ============================================================================ */
static inline void nna_load_inputs(const uint32_t *words, uint32_t num_words) {
    volatile uint32_t *buf = (volatile uint32_t *)NNA_BUF_IN;
    for (uint32_t i = 0; i < num_words; i++) {
        buf[i] = words[i];
    }
}

static inline void nna_load_weights(const uint32_t *words, uint32_t num_words) {
    volatile uint32_t *buf = (volatile uint32_t *)NNA_BUF_WEIGHT;
    for (uint32_t i = 0; i < num_words; i++) {
        buf[i] = words[i];
    }
}

static inline void nna_load_biases(const uint32_t *words, uint32_t num_words) {
    volatile uint32_t *buf = (volatile uint32_t *)NNA_BUF_BIAS;
    for (uint32_t i = 0; i < num_words; i++) {
        buf[i] = words[i];
    }
}

static inline void nna_read_outputs(uint32_t *dst, uint32_t num_words) {
    volatile uint32_t *buf = (volatile uint32_t *)NNA_BUF_OUT;
    for (uint32_t i = 0; i < num_words; i++) {
        dst[i] = buf[i];
    }
}

static inline uint32_t nna_run_layer(uint8_t k, uint8_t m,
                                     uint16_t scale_mult, uint8_t scale_shift,
                                     uint8_t act_type) {
    REG32(NNA_REG_CONFIG_DIM) = ((uint32_t)m << 8) | (uint32_t)k;
    REG32(NNA_REG_CONFIG_SCALE) = (uint32_t)scale_mult;
    REG32(NNA_REG_CONFIG_SHIFT) = (uint32_t)scale_shift;
    REG32(NNA_REG_CONFIG_ACT) = (uint32_t)act_type;

    /* Start execution */
    REG32(NNA_REG_CTRL) = NNA_CTRL_START;

    /* Poll for completion */
    while (!(REG32(NNA_REG_STATUS) & NNA_STATUS_DONE)) {
        /* wait */
    }

    /* Clear done flag */
    REG32(NNA_REG_INT_CLEAR) = 1;

    return REG32(NNA_REG_PERF_CYCLES);
}

#endif /* ROBOT_DRIVERS_H */
