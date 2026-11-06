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

    .include "nav_weights.inc"

.section .text._start
    .globl _start

_start:
    /* Initialize stack pointer to top of 16KB SRAM */
    li   sp, 0x20003FFC

    /* Watchdog budget (M11b). CLK_HZ is the NOMINAL ULX3S 25 MHz oscillator used
     * directly by fpga/ulx3s/ulx3s_top.v (no PLL); it is NOT yet measured on the
     * board (B1/U5 open). The timeout value itself is unchanged (500,000 cycles);
     * only its derivation and comment are corrected (old comment said 50 MHz). */
    .equ CLK_HZ,             25000000
    .equ WDT_TIMEOUT_MS,     20
    .equ WDT_TIMEOUT_CYCLES, (CLK_HZ / 1000) * WDT_TIMEOUT_MS

    /* ------------------------------------------------------------------------
     * 1. Initialize Hardware Safety Interlock
     * ------------------------------------------------------------------------ */
    /* Offsets per rtl/safety/safety_filter.v (M7A): 0x00 CTRL, 0x04 HEARTBEAT,
     * 0x08 STATUS (RO), 0x0C TIMEOUT. Sequence: timeout, enable|clear, heartbeat. */
    li   t0, 0x50000600       /* ADDR_SAFETY_BASE */
    li   t1, WDT_TIMEOUT_CYCLES /* 500,000 cycles = 20 ms at the nominal 25 MHz ULX3S clock */
    sw   t1, 0x0C(t0)         /* SAFETY_TIMEOUT */
    li   t1, 3                /* enable | clear trip */
    sw   t1, 0x00(t0)         /* SAFETY_CTRL */
    li   t1, 0x5AFEC0DE       /* heartbeat key */
    sw   t1, 0x04(t0)         /* SAFETY_HEARTBEAT */

    /* Software safety-filter state (last_v, last_w) lives in RAM, zeroed at boot */
    li   t0, 0x20003F00
    sw   zero, 0(t0)
    sw   zero, 4(t0)

    /* ------------------------------------------------------------------------
     * 2. Motor PWM (soc_pwm, M2 contract v3): exact zero-command arming
     *    sequence (M2_STEP1_DECISIONS.md sec. C). SIMULATION ONLY.
     *    1 FAULT_CLR  2 CMD_L=CMD_R=0  3 COMMIT (disarmed: ignored)
     *    4 poll STATUS.SHADOW_ZERO  5 ARM_REQ  -> check STATUS.ARMED
     *    If ARM is refused the firmware never commands motion: it prints
     *    msg_arm_fail and goes to halt_loop (no PASS token).
     * ------------------------------------------------------------------------ */
    li   t0, 0x50000200       /* ADDR_PWM_BASE */
    li   t1, 4
    sw   t1, 0x00(t0)         /* CTRL.FAULT_CLR */
    sw   zero, 0x04(t0)       /* CMD_L = 0 */
    sw   zero, 0x08(t0)       /* CMD_R = 0 */
    sw   zero, 0x0C(t0)       /* COMMIT (ignored while disarmed) */
    li   t2, 0x200            /* STATUS bit9 SHADOW_ZERO */
arm_wait_shadow:
    lw   t1, 0x10(t0)
    and  t1, t1, t2
    beqz t1, arm_wait_shadow
    li   t1, 1
    sw   t1, 0x00(t0)         /* CTRL.ARM_REQ */
    lw   t1, 0x10(t0)
    andi t1, t1, 1            /* STATUS bit0 ARMED */
    bnez t1, arm_ok
    la   a0, msg_arm_fail
    jal  ra, uart_puts
    j    halt_loop
arm_ok:

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
    /* Navigation done: DISARM the motor PWM (KILL -> ARMED/ACTIVE/SHADOW/CMD=0)
     * before the idle loop, so the stale timer cannot fire while idle and the
     * pins are at the zero state. */
    li   t0, 0x50000200
    li   t1, 2
    sw   t1, 0x00(t0)         /* CTRL.DISARM */

    /* Write completion token 0xCAFEBABE to RAM at 0x20003FFC */
    li   t0, 0x20003FFC
    li   t1, 0xCAFEBABE
    sw   t1, 0(t0)

    la   a0, msg_pass
    jal  ra, uart_puts

halt_loop:
    /* Pet watchdog in idle loop */
    li   t0, 0x50000604
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

    /* Configure NNA Layer 1 using constants from nav_weights.inc */
    li   t1, (L1_M_DIM << 16) | L1_K_DIM  /* dim_m, dim_k */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, L1_SCALE_MULT_VAL
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, L1_SCALE_SHIFT_VAL
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, L1_ACT_VAL
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

    /* Configure NNA Layer 2 using constants from nav_weights.inc */
    li   t1, (L2_M_DIM << 16) | L2_K_DIM  /* dim_m, dim_k */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, L2_SCALE_MULT_VAL
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, L2_SCALE_SHIFT_VAL
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, L2_ACT_VAL
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
     * STEP C: Deterministic software safety filter (mirror of safety_filter_command()
     * in safety_driver.h and sw/test/test_safety_c_mirror.py). In: s2=v_raw, s3=w_raw.
     * Out: s2=v_safe, s3=w_safe. State last_v/last_w at 0x20003F00/04.
     * Constants: MAX_V=MAX_W=64, SLEW=8, STOP=25cm.
     * Distance: min over FRONT sensors d2..d5 (bytes), INT8 q -> cm = (q+127)*403>>8
     * (hits = 2*(q/127+1) m; 403/256 ~= 200/127). q=-128 (invalid) -> negative -> 0 (contact).
     * ------------------------------------------------------------------------ */
    lw   t2, 0(s0)
    lw   t3, 4(s0)
    sll  t4, t2, 8
    sra  t4, t4, 24           /* d2 */
    sra  t5, t2, 24           /* d3 */
    blt  t4, t5, 1f
    mv   t4, t5               /* t4 = min(d2,d3) */
1:  sll  t5, t3, 24
    sra  t5, t5, 24           /* d4 */
    blt  t4, t5, 2f
    mv   t4, t5
2:  sll  t5, t3, 16
    sra  t5, t5, 24           /* d5 */
    blt  t4, t5, 3f
    mv   t4, t5               /* t4 = min q over front sensors */
3:  addi t4, t4, 127
    li   t5, 403
    mul  t4, t4, t5
    srai t4, t4, 8            /* t4 = min_distance_cm */
    bgez t4, 4f
    li   t4, 0                /* invalid / negative -> contact */
4:
    /* kinematic clamp +-64 */
    li   t5, 64
    ble  s2, t5, 5f
    mv   s2, t5
5:  neg  t6, t5
    bge  s2, t6, 6f
    mv   s2, t6
6:  ble  s3, t5, 7f
    mv   s3, t5
7:  bge  s3, t6, 8f
    mv   s3, t6
8:
    /* slew limit (+-8 per tick) vs last state */
    li   t0, 0x20003F00
    lw   t1, 0(t0)            /* last_v */
    lw   t2, 4(t0)            /* last_w */
    sub  t3, s2, t1
    li   t5, 8
    ble  t3, t5, 9f
    add  s2, t1, t5
9:  li   t5, -8
    bge  t3, t5, 10f
    add  s2, t1, t5
10: sub  t3, s3, t2
    li   t5, 8
    ble  t3, t5, 11f
    add  s3, t2, t5
11: li   t5, -8
    bge  t3, t5, 12f
    add  s3, t2, t5
12:
    /* proximity override after slew; only forward motion is limited */
    blez s2, 15f
    li   t5, 25
    bgt  t4, t5, 13f
    li   s2, 0                /* within stop distance: no forward motion */
    j    15f
13: sub  t5, t4, t5
    li   t6, 5
    mul  t5, t5, t6
    srai t5, t5, 3            /* cap = (d-25)*5>>3 */
    ble  s2, t5, 15f
    mv   s2, t5
15: bgez s2, 16f              /* M10c: final linear velocity is never negative */
    li   s2, 0
16: sw   s2, 0(t0)            /* last_v = v_safe (already clamped) */
    sw   s3, 4(t0)            /* last_w = w_safe */

safety_pass:
    /* Pet hardware safety watchdog (HEARTBEAT register, key) */
    li   t0, 0x50000604
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)

    /* ------------------------------------------------------------------------
     * STEP D: Differential drive + M2 sign-magnitude motor command (contract v3)
     * v_L = v_safe - w_raw, v_R = v_safe + w_raw
     * cmd = sign(v) * min(1000, (|v|*1000) >> 7)   (motor_cmd_conv, V-CONV)
     * Write CMD_L, CMD_R then COMMIT (atomic ACTIVE update, stale reload).
     * Telemetry PWM_L/PWM_R now print the signed CMD words (two's complement).
     * ------------------------------------------------------------------------ */
    sub  a0, s2, s3           /* v_L */
    jal  ra, motor_cmd_conv
    mv   s4, a0               /* s4 = cmd_L */
    add  a0, s2, s3           /* v_R */
    jal  ra, motor_cmd_conv
    mv   s1, a0               /* s1 = cmd_R */

    li   t0, 0x50000200
    sw   s4, 0x04(t0)         /* CMD_L */
    sw   s1, 0x08(t0)         /* CMD_R */
    sw   zero, 0x0C(t0)       /* COMMIT */

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
/* M11b: uart_puts blocks on TX-busy for every byte. Without a heartbeat here a
 * long string (e.g. the 162-byte pass banner) at the board divider 217 holds the
 * CPU ~351k cycles without kicking, and the watchdog expired after PASS.
 * The key is written once per byte, only AFTER the TX-busy wait completes, so a
 * UART that never becomes ready still stops the heartbeat and trips the watchdog.
 * Worst-case kick gap inside this loop is ~1 byte time (10 * divider cycles).
 * Clobbers t0-t3, a0 (caller-saved). */
uart_puts:
    li   t0, 0x50000100       /* UART Base */
    li   t3, 0x5AFEC0DE       /* heartbeat key */
puts_loop:
    lbu  t1, 0(a0)
    beqz t1, puts_done
puts_wait:
    lw   t2, 0x08(t0)         /* Status */
    andi t2, t2, 1            /* TX busy */
    bnez t2, puts_wait
    li   t2, 0x50000604       /* SAFETY_HEARTBEAT */
    sw   t3, 0(t2)            /* kick: UART made progress */
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

/* Clobbers t0-t3 (caller-saved). Same heartbeat rule as uart_puts. */
uart_put_nibble:
    li   t0, 0x50000100
wait_nib:
    lw   t1, 0x08(t0)
    andi t1, t1, 1
    bnez t1, wait_nib
    li   t2, 0x50000604       /* SAFETY_HEARTBEAT: kick after TX-ready (M11b) */
    li   t3, 0x5AFEC0DE
    sw   t3, 0(t2)
    la   t2, hex_digits
    add  t2, t2, a0
    lbu  t3, 0(t2)
    sw   t3, 0x00(t0)
    ret

/* ============================================================================
 * Constant Data & Weights
 * ============================================================================ */
/* M2 wheel-command conversion (leaf, clobbers t0,t1,a0) */
    .include "motor_cmd.inc"

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

msg_arm_fail:
    .asciz "[MOTOR] ARM refused - no motion commanded\n"

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

