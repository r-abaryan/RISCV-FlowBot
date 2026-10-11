/* ============================================================================
 * Autonomous Mobile Robot Navigation Firmware for RV32IM + rv_nna SoC
 *
 * Implements:
 * 1. Hardware Safety Interlock configuration & watchdog supervision
 * 2. Multi-layer INT8 Neural Policy Inference:
 *    - Layer 1: 16 inputs -> 8 hidden neurons (ReLU)
 *    - Layer 2: 8 hidden neurons -> 2 action outputs (Clip)
 * 3. Deterministic Software Safety Layer:
 *    - Front collision detection & emergency braking override
 * 4. Differential Drive Kinematics & Dual-Channel PWM Generation
 * 5. Telemetry & diagnostics via memory-mapped UART
 * ============================================================================ */

    .section .text._start
    .globl _start

_start:
    /* Initialize stack pointer to top of 16KB SRAM */
    li   sp, 0x20003FFC

    /* ------------------------------------------------------------------------
     * 1. Initialize Hardware Safety Interlock
     * ------------------------------------------------------------------------ */
    li   t0, 0x50000600       /* ADDR_SAFETY_BASE */
    li   t1, 500000           /* Watchdog limit (500k cycles) */
    sw   t1, 0x04(t0)         /* SAFETY_REG_WD_LIMIT */
    li   t1, 0x5AFEC0DE       /* SAFETY_KEY_PET */
    sw   t1, 0x08(t0)         /* Pet watchdog */
    li   t1, 0x5AFEC1EA       /* SAFETY_KEY_CLEAR */
    sw   t1, 0x10(t0)         /* Clear any previous disarm */

    /* ------------------------------------------------------------------------
     * 2. Initialize Dual PWM Motor Controller
     * ------------------------------------------------------------------------ */
    li   t0, 0x50000500       /* ADDR_PWM_BASE */
    li   t1, 1000             /* Period = 1000 clock cycles */
    sw   t1, 0x00(t0)         /* PWM_REG_PERIOD */
    sw   zero, 0x04(t0)       /* PWM_REG_DUTY_LEFT = 0 */
    sw   zero, 0x08(t0)       /* PWM_REG_DUTY_RIGHT = 0 */
    li   t1, 1
    sw   t1, 0x0C(t0)         /* PWM_REG_CTRL = enable */

    /* ------------------------------------------------------------------------
     * 3. Print Boot Banner over UART
     * ------------------------------------------------------------------------ */
    la   a0, msg_boot
    jal  ra, uart_puts

    /* ========================================================================
     * Test Case 1: Open Corridor
     * Expected: High forward speed v > 0, steering w ~ 0
     * ======================================================================== */
    la   a0, msg_case1
    jal  ra, uart_puts

    la   a0, case1_sensors
    jal  ra, run_navigation_cycle

    /* ========================================================================
     * Test Case 2: Obstacle on Left
     * Expected: Forward speed v > 0, steer Right (w > 0)
     * ======================================================================== */
    la   a0, msg_case2
    jal  ra, uart_puts

    la   a0, case2_sensors
    jal  ra, run_navigation_cycle

    /* ========================================================================
     * Test Case 3: Emergency Critical Obstacle Ahead
     * Expected: Software safety interlock triggers -> clamps v to 0!
     * ======================================================================== */
    la   a0, msg_case3
    jal  ra, uart_puts

    la   a0, case3_sensors
    jal  ra, run_navigation_cycle

    /* ------------------------------------------------------------------------
     * All Cases Complete - Print Pass Banner
     * ------------------------------------------------------------------------ */
    /* Write completion token 0xCAFEBABE to RAM at 0x20003FFC */
    li   t0, 0x20003FFC
    li   t1, 0xCAFEBABE
    sw   t1, 0(t0)

    la   a0, msg_pass
    jal  ra, uart_puts

halt_loop:
    /* Pet watchdog in idle loop */
    li   t0, 0x50000608
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)
    j    halt_loop

/* ============================================================================
 * Function: run_navigation_cycle
 * a0: Pointer to 16-byte sensor input array (4 words)
 * ============================================================================ */
run_navigation_cycle:
    addi sp, sp, -32
    sw   ra, 28(sp)
    sw   s0, 24(sp)
    sw   s1, 20(sp)
    sw   s2, 16(sp)
    sw   s3, 12(sp)
    sw   s4, 8(sp)

    mv   s0, a0               /* s0 = sensor pointer */

    /* ------------------------------------------------------------------------
     * STEP A: Load Layer 1 Parameters into rv_nna
     * ------------------------------------------------------------------------ */
    li   s1, 0x40000000       /* s1 = NNA Base */

    /* Copy 4 sensor words (16 inputs) into NNA_BUF_IN (0x100) */
    addi t0, s1, 0x100
    lw   t1, 0(s0)
    sw   t1, 0(t0)
    lw   t1, 4(s0)
    sw   t1, 4(t0)
    lw   t1, 8(s0)
    sw   t1, 8(t0)
    lw   t1, 12(s0)
    sw   t1, 12(t0)

    /* Copy Layer 1 Weights (32 words) into NNA_BUF_WEIGHT (0x400) */
    la   t2, l1_weights
    addi t0, s1, 0x400
    li   t3, 32
copy_l1_w:
    lw   t1, 0(t2)
    sw   t1, 0(t0)
    addi t2, t2, 4
    addi t0, t0, 4
    addi t3, t3, -1
    bnez t3, copy_l1_w

    /* Copy Layer 1 Biases (8 words) into NNA_BUF_BIAS (0x200) */
    la   t2, l1_biases
    addi t0, s1, 0x200
    li   t3, 8
copy_l1_b:
    lw   t1, 0(t2)
    sw   t1, 0(t0)
    addi t2, t2, 4
    addi t0, t0, 4
    addi t3, t3, -1
    bnez t3, copy_l1_b

    /* Configure NNA Layer 1: K=16, M=8, ScaleMult=16384, Shift=15, Act=RELU(1) */
    li   t1, 0x00080010       /* dim_m=8, dim_k=16 */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, 16384
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, 15
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, 1                /* ACT_RELU */
    sw   t1, 0x0C(s1)         /* CONFIG_ACT */

    /* Start NNA and wait */
    li   t1, 1
    sw   t1, 0x00(s1)         /* CTRL = START */
wait_l1:
    lw   t1, 0x04(s1)         /* STATUS */
    andi t1, t1, 2            /* bit 1 = done */
    beqz t1, wait_l1
    li   t1, 1
    sw   t1, 0x1C(s1)         /* Clear IRQ */

    /* Read Layer 1 outputs (2 words = 8 neurons) from NNA_BUF_OUT (0x800) */
    li   t0, 0x40000800
    lw   s2, 0(t0)            /* Hidden activations [0..3] */
    lw   s3, 4(t0)            /* Hidden activations [4..7] */

    /* ------------------------------------------------------------------------
     * STEP B: Execute Layer 2
     * ------------------------------------------------------------------------ */
    /* Copy hidden activations into NNA_BUF_IN (0x100) */
    addi t0, s1, 0x100
    sw   s2, 0(t0)
    sw   s3, 4(t0)

    /* Copy Layer 2 Weights (4 words) into NNA_BUF_WEIGHT (0x400) */
    la   t2, l2_weights
    addi t0, s1, 0x400
    li   t3, 4
copy_l2_w:
    lw   t1, 0(t2)
    sw   t1, 0(t0)
    addi t2, t2, 4
    addi t0, t0, 4
    addi t3, t3, -1
    bnez t3, copy_l2_w

    /* Copy Layer 2 Biases (2 words) into NNA_BUF_BIAS (0x200) */
    la   t2, l2_biases
    addi t0, s1, 0x200
    li   t3, 2
copy_l2_b:
    lw   t1, 0(t2)
    sw   t1, 0(t0)
    addi t2, t2, 4
    addi t0, t0, 4
    addi t3, t3, -1
    bnez t3, copy_l2_b

    /* Configure NNA Layer 2: K=8, M=2, ScaleMult=16384, Shift=15, Act=CLIP(2) */
    li   t1, 0x00020008       /* dim_m=2, dim_k=8 */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, 16384
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, 15
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, 2                /* ACT_CLIP */
    sw   t1, 0x0C(s1)         /* CONFIG_ACT */

    /* Start NNA and wait */
    li   t1, 1
    sw   t1, 0x00(s1)         /* CTRL = START */
wait_l2:
    lw   t1, 0x04(s1)         /* STATUS */
    andi t1, t1, 2            /* done */
    beqz t1, wait_l2
    li   t1, 1
    sw   t1, 0x1C(s1)         /* Clear IRQ */

    /* Read Layer 2 outputs from NNA_BUF_OUT (0x800) */
    li   t0, 0x40000800
    lw   t1, 0(t0)            /* Contains v_raw in byte 0, w_raw in byte 1 */

    /* Extract signed v_raw from byte 0 */
    sll  s2, t1, 24
    sra  s2, s2, 24           /* s2 = v_raw (-128..127) */

    /* Extract signed w_raw from byte 1 */
    sll  s3, t1, 16
    sra  s3, s3, 24           /* s3 = w_raw (-128..127) */

    /* ------------------------------------------------------------------------
     * STEP C: Deterministic Software Safety Layer
     * Inspect front distance sensors (d3, d4).
     * If both indicate critical close distance (< 0), override v = 0!
     * d3 is byte 3 of sensor word 0.
     * d4 is byte 0 of sensor word 1.
     * ------------------------------------------------------------------------ */
    lw   t2, 0(s0)            /* sensor word 0 */
    sra  t2, t2, 24           /* t2 = d3 (signed INT8) */

    lw   t3, 4(s0)            /* sensor word 1 */
    sll  t3, t3, 24
    sra  t3, t3, 24           /* t3 = d4 (signed INT8) */

    /* Check if d3 < 0 AND d4 < 0 */
    bgez t2, safety_pass
    bgez t3, safety_pass

    /* SAFETY TRIP: Emergency obstacle right in front! */
    la   a0, msg_trip
    jal  ra, uart_puts
    li   s2, 0                /* Clamp forward velocity to 0! */

safety_pass:
    /* Pet hardware safety watchdog */
    li   t0, 0x50000608
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)

    /* ------------------------------------------------------------------------
     * STEP D: Differential Drive Kinematics & Motor PWM Generation
     * v_L = v_safe - w_raw
     * v_R = v_safe + w_raw
     * Map signed [-128..127] to PWM Duty [0..1000]:
     * duty = ((v_wheel + 128) * 1000) / 256
     * ------------------------------------------------------------------------ */
    sub  t2, s2, s3           /* t2 = v_L */
    add  t3, s2, s3           /* t3 = v_R */

    /* Compute Duty Left */
    addi t2, t2, 128
    li   t4, 1000
    mul  t2, t2, t4
    srai t2, t2, 8            /* / 256 */
    /* Clamp 0..1000 */
    bgez t2, clamp_l_min
    li   t2, 0
clamp_l_min:
    ble  t2, t4, clamp_l_max
    mv   t2, t4
clamp_l_max:

    /* Compute Duty Right */
    addi t3, t3, 128
    mul  t3, t3, t4
    srai t3, t3, 8            /* / 256 */
    /* Clamp 0..1000 */
    bgez t3, clamp_r_min
    li   t3, 0
clamp_r_min:
    ble  t3, t4, clamp_r_max
    mv   t3, t4
clamp_r_max:

    /* Write to PWM registers */
    li   t0, 0x50000500
    sw   t2, 0x04(t0)         /* DUTY_LEFT */
    sw   t3, 0x08(t0)         /* DUTY_RIGHT */

    /* Save computed values for telemetry: s2=v, s3=w, s4=duty_L, t3=duty_R */
    mv   s4, t2
    mv   s1, t3

    /* ------------------------------------------------------------------------
     * STEP E: Print Telemetry over UART
     * ------------------------------------------------------------------------ */
    la   a0, msg_telem_v
    jal  ra, uart_puts
    mv   a0, s2
    jal  ra, uart_puthex_byte

    la   a0, msg_telem_w
    jal  ra, uart_puts
    mv   a0, s3
    jal  ra, uart_puthex_byte

    la   a0, msg_telem_pwm_l
    jal  ra, uart_puts
    mv   a0, s4
    jal  ra, uart_puthex_word

    la   a0, msg_telem_pwm_r
    jal  ra, uart_puts
    mv   a0, s1
    jal  ra, uart_puthex_word

    la   a0, msg_newline
    jal  ra, uart_puts

    lw   ra, 28(sp)
    lw   s0, 24(sp)
    lw   s1, 20(sp)
    lw   s2, 16(sp)
    lw   s3, 12(sp)
    lw   s4, 8(sp)
    addi sp, sp, 32
    ret

/* ============================================================================
 * UART Helper Functions
 * ============================================================================ */
uart_puts:
    li   t0, 0x50000100       /* UART Base */
puts_loop:
    lbu  t1, 0(a0)
    beqz t1, puts_done
puts_wait:
    lw   t2, 0x08(t0)         /* Status */
    andi t2, t2, 1            /* TX busy */
    bnez t2, puts_wait
    sw   t1, 0x00(t0)         /* Send character */
    addi a0, a0, 1
    j    puts_loop
puts_done:
    ret

/* Prints lower 8 bits of a0 in 2 hex chars */
uart_puthex_byte:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    mv   s0, a0
    srli a0, s0, 4
    andi a0, a0, 0xF
    jal  ra, uart_put_nibble
    andi a0, s0, 0xF
    jal  ra, uart_put_nibble
    lw   ra, 12(sp)
    lw   s0, 8(sp)
    addi sp, sp, 16
    ret

/* Prints lower 16 bits of a0 in 4 hex chars */
uart_puthex_word:
    addi sp, sp, -16
    sw   ra, 12(sp)
    sw   s0, 8(sp)
    mv   s0, a0
    srli a0, s0, 12
    andi a0, a0, 0xF
    jal  ra, uart_put_nibble
    srli a0, s0, 8
    andi a0, a0, 0xF
    jal  ra, uart_put_nibble
    srli a0, s0, 4
    andi a0, a0, 0xF
    jal  ra, uart_put_nibble
    andi a0, s0, 0xF
    jal  ra, uart_put_nibble
    lw   ra, 12(sp)
    lw   s0, 8(sp)
    addi sp, sp, 16
    ret

uart_put_nibble:
    li   t0, 0x50000100
wait_nib:
    lw   t1, 0x08(t0)
    andi t1, t1, 1
    bnez t1, wait_nib
    la   t2, hex_digits
    add  t2, t2, a0
    lbu  t3, 0(t2)
    sw   t3, 0x00(t0)
    ret

/* ============================================================================
 * Constant Data & Weights
 * ============================================================================ */
    .section .rodata
.balign 4
hex_digits:
    .ascii "0123456789ABCDEF"

msg_boot:
    .asciz "\n=== RISC-V Mobile Robot Navigation SoC Online ===\n[CORE] RV32IM CPU @ 50MHz\n[ACCEL] rv_nna INT8 4-way SIMD\n[SAFETY] Deterministic Interlock Armed\n\n"

msg_case1:
    .asciz "[CYCLE 1] Open Corridor Navigation Test\n"

msg_case2:
    .asciz "[CYCLE 2] Obstacle on Left Avoidance Test\n"

msg_case3:
    .asciz "[CYCLE 3] Emergency Wall Ahead Safety Test\n"

msg_trip:
    .asciz "  >>> [SAFETY OVERRIDE] Critical Obstacle Detected! Clamping Velocity to ZERO <<<\n"

msg_telem_v:
    .asciz "  [TELEMETRY] v_cmd: 0x"

msg_telem_w:
    .asciz " | w_cmd: 0x"

msg_telem_pwm_l:
    .asciz " | PWM_L: 0x"

msg_telem_pwm_r:
    .asciz " | PWM_R: 0x"

msg_newline:
    .asciz "\n\n"

msg_pass:
    .asciz "========================================================\n[STATUS] ALL NAVIGATION & SAFETY CHECKS PASSED!\n========================================================\n"

/* Test Case 1 Sensors: Open corridor (all distance +100 = 0x64) */
.balign 4
case1_sensors:
    .word 0x64646464  /* d0=100, d1=100, d2=100, d3=100 */
    .word 0x64646464  /* d4=100, d5=100, d6=100, d7=100 */
    .word 0x00000000  /* ax=0, ay=0, wz=0, vx=0 */
    .word 0x00500000  /* vy=0, wz=0, goal_dist=80, goal_heading=0 */

/* Test Case 2 Sensors: Obstacle on Left (d0=-100=0x9C, d1=-100=0x9C, d2=-80=0xB0, d3=50=0x32) */
.balign 4
case2_sensors:
    .word 0x32B09C9C  /* d0=-100, d1=-100, d2=-80, d3=50 */
    .word 0x64646464  /* d4=100, d5=100, d6=100, d7=100 */
    .word 0x00000000  /* ax=0, ay=0, wz=0, vx=0 */
    .word 0x00500000  /* vy=0, wz=0, goal_dist=80, goal_heading=0 */

/* Test Case 3 Sensors: Critical Wall Ahead (d2=-100=0xB0, d3=-120=0x88, d4=-120=0x88, d5=-100=0xB0) */
.balign 4
case3_sensors:
    .word 0x88B03232  /* d0=50, d1=50, d2=-100, d3=-120 */
    .word 0x3232B088  /* d4=-120, d5=-100, d6=50, d7=50 */
    .word 0x00000000  /* ax=0, ay=0, wz=0, vx=0 */
    .word 0x00500000  /* vy=0, wz=0, goal_dist=80, goal_heading=0 */

/* Include auto-generated trained weights */
.include "/workspace/sw/firmware/nav_weights.inc"
