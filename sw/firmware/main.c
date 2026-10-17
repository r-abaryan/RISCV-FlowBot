// ============================================================================
// File: main.c
// Description: Bare-metal Firmware for RISC-V Robot Control SoC
// Integrates NNA INT8 Inference with Deterministic Safety Filter and Actuator PWM
// ============================================================================

#include "soc_regs.h"
#include "nna_driver.h"
#include "safety_driver.h"

// Simple UART Character Output
static void uart_putc(char c) {
    while (UART_REG_STATUS & UART_STATUS_TX_BUSY); // Wait until TX idle (write while busy is dropped)
    UART_REG_TXDATA = (uint32_t)c;
}

static void uart_puts(const char *str) {
    while (*str) {
        uart_putc(*str++);
    }
}

// Convert 8-bit integer to hex string for UART printing
static void uart_puthex8(uint8_t val) {
    const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[(val >> 4) & 0xF]);
    uart_putc(hex[val & 0xF]);
}

int main(void) {
    uart_puts("\r\n========================================\r\n");
    uart_puts("RISC-V Robot SoC Online (RV32IM + NNA)\r\n");
    uart_puts("========================================\r\n");

    // 1. Arm Hardware Safety Watchdog (50000 clock cycles timeout)
    safety_hw_enable(50000);
    safety_hw_heartbeat();
    uart_puts("[SAFETY] Hardware Watchdog Armed.\r\n");

    // 2. Initialize Safety State
    safety_state_t safety_state = {
        .last_v = 0,
        .last_w = 0,
        .fault_count = 0
    };

    // 3. Initialize rv_nna Accelerator
    nna_reset();
    uart_puts("[NNA] Accelerator Reset Complete.\r\n");

    // 4. Load Pre-Trained MLP Policy Weights into Scratchpad
    // Test Vector: 8 Input Features:
    // [0] = 50 cm (Obstacle distance)
    // [1..7] = Goal navigation and odometry features
    // Packed into 2 words:
    // Word 0: [50, 20, 10, -5] -> 0xFB0A1432
    // Word 1: [15, 0, 30, -10] -> 0xF61E000F
    nna_scratchpad_write(0x0000, 0xFB0A1432);
    nna_scratchpad_write(0x0001, 0xF61E000F);

    // Weights for Neuron 0 (linear velocity):
    // Word 2: [1, 2, 1, 0] -> 0x00010201
    // Word 3: [1, -1, 0, 1] -> 0x0100FF01
    nna_scratchpad_write(0x0002, 0x00010201);
    nna_scratchpad_write(0x0003, 0x0100FF01);

    // 5. Trigger NNA Matrix-Vector Inference
    // Dim = 8 features, Scale shift = 4, Bias = 16, Linear Activation (0)
    nna_start_layer(8, 4, 16, 0);
    nna_wait_done();

    uint32_t cycles = nna_get_cycles();
    uint32_t out_val = nna_scratchpad_read(0x0080);
    int8_t raw_v = (int8_t)(out_val & 0xFF);
    int8_t raw_w = 12; // Test steering output

    uart_puts("[NNA] Policy Inference Finished in ");
    uart_puthex8((uint8_t)cycles);
    uart_puts(" cycles. Raw v = 0x");
    uart_puthex8((uint8_t)raw_v);
    uart_puts("\r\n");

    // 6. Run Deterministic Safety Filter Checks
    int8_t safe_v, safe_w;
    int16_t obstacle_distance_cm = 50; // Clear path
    safety_filter_command(&safety_state, raw_v, raw_w, obstacle_distance_cm, &safe_v, &safe_w);

    uart_puts("[SAFETY] Safe Command: v = 0x");
    uart_puthex8((uint8_t)safe_v);
    uart_puts(", w = 0x");
    uart_puthex8((uint8_t)safe_w);
    uart_puts("\r\n");

    // 7. Dispatch to Motor PWM Peripheral
    // Convert velocities to PWM duty cycles (baseline 5000 + delta)
    uint16_t pwm_l = (uint16_t)(5000 + ((int16_t)safe_v * 20) - ((int16_t)safe_w * 10));
    uint16_t pwm_r = (uint16_t)(5000 + ((int16_t)safe_v * 20) + ((int16_t)safe_w * 10));

    PWM_REG_LEFT_DUTY  = pwm_l;
    PWM_REG_RIGHT_DUTY = pwm_r;
    PWM_REG_CTRL       = 0x01; // Enable PWM output

    // Refresh Heartbeat
    safety_hw_heartbeat();

    uart_puts("[PWM] Motor PWM Actuators Dispatched Successfully!\r\n");
    uart_puts("SoC Execution Loop Verification Complete.\r\n");

    // Halt testbench with magic value in RAM
    REG32(RAM_BASE + 0x3FFC) = 0xCAFEBABE;

    while (1) {
        safety_hw_heartbeat();
    }

    return 0;
}
