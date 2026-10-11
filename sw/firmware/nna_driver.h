// ============================================================================
// File: nna_driver.h
// Description: Low-level C HAL Driver for rv_nna INT8 Accelerator
// ============================================================================

#ifndef NNA_DRIVER_H
#define NNA_DRIVER_H

#include "soc_regs.h"

static inline void nna_reset(void) {
    NNA_REG_CTRL = NNA_CTRL_RESET_BIT;
    NNA_REG_CTRL = 0;
}

static inline void nna_scratchpad_write(uint16_t word_addr, uint32_t data) {
    NNA_REG_SP_WR_ADDR = word_addr;
    NNA_REG_SP_WR_DATA = data;
}

static inline uint32_t nna_scratchpad_read(uint16_t word_addr) {
    NNA_REG_SP_RD_ADDR = word_addr;
    return NNA_REG_SP_RD_DATA;
}

static inline void nna_start_layer(uint16_t dim_n, uint8_t scale_shift, int32_t bias, uint8_t relu_en) {
    NNA_REG_CFG_DIM   = (uint32_t)dim_n;
    NNA_REG_CFG_SCALE = (uint32_t)scale_shift;
    NNA_REG_CFG_BIAS  = (uint32_t)bias;

    uint32_t ctrl = NNA_CTRL_START_BIT;
    if (relu_en) {
        ctrl |= NNA_CTRL_RELU_BIT;
    }
    NNA_REG_CTRL = ctrl;
}

static inline void nna_wait_done(void) {
    while (NNA_REG_STATUS & NNA_STATUS_BUSY_BIT) {
        // Spin wait
    }
}

static inline uint32_t nna_get_cycles(void) {
    return NNA_REG_PERF_CYCLES;
}

#endif // NNA_DRIVER_H
