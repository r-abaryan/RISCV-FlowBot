/* ============================================================================
 * Hardware-in-the-Loop Co-Simulation Firmware for RV32IM + rv_nna SoC
 * File: soc_cosim_firmware.s
 *
 * Implements:
 * 1. Hardware Safety Interlock & watchdog maintenance
 * 2. Multi-layer INT8 Neural Policy Inference via rv_nna:
 *    - Layer 1: 16 inputs -> 8 hidden neurons (ReLU)
 *    - Layer 2: 8 hidden neurons -> 2 action outputs (Clip)
 * 3. Deterministic Software Safety Layer:
 *    - Front collision detection & emergency braking override
 * 4. Differential Drive Kinematics & Dual-Channel PWM Generation
 * 5. Bidirectional Mailbox Protocol with Host Python Simulation
 *
 * Mailbox Memory Map (Base: 0x20001000, RAM Word 1024):
 *   0x00: SIM_MAGIC       (0x53494D31 = "SIM1")
 *   0x04: STEP_CMD         (Token: 1..N, -1 = SHUTDOWN)
 *   0x08: STEP_STATUS      (0x00=BUSY, 0xA0=BOOT_READY, 1..N = DONE TOKEN)
 *   0x0C: STEP_SEQ         (Active token)
 *   0x10: SENSORS[0..3]    (4 words = 16 bytes INT8 sensor features)
 *   0x20: OUT_V_RAW        (Raw linear velocity INT8 from neural policy)
 *   0x24: OUT_W_RAW        (Raw angular velocity INT8)
 *   0x28: OUT_V_CMD        (Filtered linear velocity after safety layer)
 *   0x2C: OUT_W_CMD        (Filtered angular velocity)
 *   0x30: SAFETY_TRIP      (1 if safety intervened, 0 otherwise)
 *   0x34: PWM_LEFT         (Hardware PWM Left duty cycle 0..1000)
 *   0x38: PWM_RIGHT        (Hardware PWM Right duty cycle 0..1000)
 * ============================================================================ */

    .include "nav_weights.inc"

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
    li   t0, 0x50000200       /* ADDR_PWM_BASE */
    li   t1, 1                /* Enable bit = 1 */
    sw   t1, 0x00(t0)         /* PWM_REG_CTRL = enable */
    sw   zero, 0x04(t0)       /* PWM_REG_DUTY_LEFT = 0 */
    sw   zero, 0x08(t0)       /* PWM_REG_DUTY_RIGHT = 0 */

    /* ------------------------------------------------------------------------
     * 3. Mailbox Handshake with Co-Simulation Testbench
     * Base: 0x20001000
     * ------------------------------------------------------------------------ */
    li   s7, 0x20001000       /* s7 = Mailbox Base */

    /* Signal BOOT_READY token (0xA0) to testbench */
    li   t1, 0xA0
    sw   t1, 8(s7)

cosim_step_loop:
    /* Pet hardware safety watchdog */
    li   t0, 0x50000608
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)

    /* Poll STEP_CMD at offset 4 until nonzero */
    lw   s8, 4(s7)
    beqz s8, cosim_step_loop

    /* Check for SHUTDOWN command (0xFFFFFFFF = -1) */
    li   t2, -1
    beq  s8, t2, cosim_shutdown

    /* Set STEP_STATUS = 0 (BUSY) */
    sw   zero, 8(s7)

    /* Sensor input pointer is at Mailbox + 16 (0x20001010) */
    addi s0, s7, 16

    /* ------------------------------------------------------------------------
     * STEP A: Execute Layer 1 on rv_nna (16 Inputs -> 8 Neurons, ReLU)
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

    /* Configure NNA Layer 1 */
    li   t1, (L1_M_DIM << 16) | L1_K_DIM  /* dim_m, dim_k */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, L1_SCALE_MULT_VAL
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, L1_SCALE_SHIFT_VAL
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, L1_ACT_VAL
    sw   t1, 0x0C(s1)         /* CONFIG_ACT */

    /* Start NNA and wait for done */
    li   t1, 1
    sw   t1, 0x00(s1)         /* CTRL = START */
wait_l1:
    lw   t1, 0x04(s1)         /* STATUS */
    andi t1, t1, 2            /* done bit */
    beqz t1, wait_l1
    li   t1, 1
    sw   t1, 0x1C(s1)         /* Clear IRQ */

    /* Read Layer 1 outputs (2 words = 8 neurons) from NNA_BUF_OUT (0x800) */
    li   t0, 0x40000800
    lw   s2, 0(t0)            /* Hidden activations [0..3] */
    lw   s3, 4(t0)            /* Hidden activations [4..7] */

    /* ------------------------------------------------------------------------
     * STEP B: Execute Layer 2 on rv_nna (8 Hidden -> 2 Action, Clip)
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

    /* Configure NNA Layer 2 */
    li   t1, (L2_M_DIM << 16) | L2_K_DIM  /* dim_m, dim_k */
    sw   t1, 0x08(s1)         /* CONFIG_DIM */
    li   t1, L2_SCALE_MULT_VAL
    sw   t1, 0x10(s1)         /* CONFIG_SCALE */
    li   t1, L2_SCALE_SHIFT_VAL
    sw   t1, 0x14(s1)         /* CONFIG_SHIFT */
    li   t1, L2_ACT_VAL
    sw   t1, 0x0C(s1)         /* CONFIG_ACT */

    /* Start NNA and wait for done */
    li   t1, 1
    sw   t1, 0x00(s1)         /* CTRL = START */
wait_l2:
    lw   t1, 0x04(s1)         /* STATUS */
    andi t1, t1, 2            /* done bit */
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

    /* Save raw values */
    mv   s5, s2               /* s5 = v_raw */

    /* ------------------------------------------------------------------------
     * STEP C: Deterministic Software Safety Layer
     * Inspect front distance sensors (d3, d4).
     * If both indicate critical close distance (< 0), clamp v = 0!
     * d3 is byte 3 of sensor word 0.
     * d4 is byte 0 of sensor word 1.
     * ------------------------------------------------------------------------ */
    lw   t2, 0(s0)            /* sensor word 0 */
    sra  t2, t2, 24           /* t2 = d3 (signed INT8) */

    lw   t3, 4(s0)            /* sensor word 1 */
    sll  t3, t3, 24
    sra  t3, t3, 24           /* t3 = d4 (signed INT8) */

    li   s6, 0                /* s6 = safety_trip = 0 */

    /* Check if d3 < 0 AND d4 < 0 */
    bgez t2, safety_pass
    bgez t3, safety_pass

    /* SAFETY TRIP: Emergency obstacle right in front! */
    li   s2, 0                /* Clamp forward velocity to 0! */
    li   s6, 1                /* Set safety_trip = 1 */

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
    li   t0, 0x50000200
    sw   t2, 0x04(t0)         /* DUTY_LEFT */
    sw   t3, 0x08(t0)         /* DUTY_RIGHT */

    /* ------------------------------------------------------------------------
     * STEP E: Write Results to Mailbox
     * ------------------------------------------------------------------------ */
    sw   s5, 0x20(s7)         /* OUT_V_RAW */
    sw   s3, 0x24(s7)         /* OUT_W_RAW */
    sw   s2, 0x28(s7)         /* OUT_V_CMD */
    sw   s3, 0x2C(s7)         /* OUT_W_CMD */
    sw   s6, 0x30(s7)         /* SAFETY_TRIP */
    sw   t2, 0x34(s7)         /* PWM_LEFT */
    sw   t3, 0x38(s7)         /* PWM_RIGHT */

    /* Clear STEP_CMD to acknowledge */
    sw   zero, 4(s7)

    /* Write completed token to STEP_STATUS */
    sw   s8, 8(s7)

    j    cosim_step_loop

cosim_shutdown:
    /* Signal shutdown acknowledge */
    li   t1, 0xFF
    sw   t1, 8(s7)
    li   t0, 0x20003FFC
    li   t1, 0xCAFEBABE
    sw   t1, 0(t0)

halt_loop:
    li   t0, 0x50000608
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)
    j    halt_loop
