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
    li   t0, 0x50000600       /* ADDR_SAFETY_BASE; offsets per safety_filter.v (M7A) */
    li   t1, 500000
    sw   t1, 0x0C(t0)         /* TIMEOUT */
    li   t1, 3
    sw   t1, 0x00(t0)         /* CTRL = enable | clear */
    li   t1, 0x5AFEC0DE
    sw   t1, 0x04(t0)         /* HEARTBEAT */

    /* ------------------------------------------------------------------------
     * 2. Motor PWM (soc_pwm, M2 contract v3): exact zero-command arming
     *    sequence (M2_STEP1_DECISIONS.md sec. C). SIMULATION ONLY.
     *    ARM refused -> no motion is commanded; firmware parks in halt_loop
     *    without BOOT_READY, so the cosim harness fails (no silent pass).
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
    beqz t1, halt_loop

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
    li   t0, 0x50000604
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
    li   t0, 0x50000604
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)

    /* ------------------------------------------------------------------------
     * STEP D: Differential drive + M2 sign-magnitude motor command (contract v3)
     * v_L = v_safe - w_raw, v_R = v_safe + w_raw
     * cmd = sign(v) * min(1000, (|v|*1000) >> 7)   (motor_cmd_conv)
     * Mailbox PWM_LEFT/PWM_RIGHT now carry the signed CMD (two's complement).
     * motor_cmd_conv clobbers only t0, t1, a0; t2/t3 survive the 2nd call.
     * ------------------------------------------------------------------------ */
    sub  a0, s2, s3           /* v_L */
    jal  ra, motor_cmd_conv
    mv   t2, a0               /* t2 = cmd_L */
    add  a0, s2, s3           /* v_R */
    jal  ra, motor_cmd_conv
    mv   t3, a0               /* t3 = cmd_R */

    li   t0, 0x50000200
    sw   t2, 0x04(t0)         /* CMD_L */
    sw   t3, 0x08(t0)         /* CMD_R */
    sw   zero, 0x0C(t0)       /* COMMIT */

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
    /* DISARM motor PWM before idling (ARMED/ACTIVE/SHADOW/CMD -> 0) */
    li   t0, 0x50000200
    li   t1, 2
    sw   t1, 0x00(t0)         /* CTRL.DISARM */
    /* Signal shutdown acknowledge */
    li   t1, 0xFF
    sw   t1, 8(s7)
    li   t0, 0x20003FFC
    li   t1, 0xCAFEBABE
    sw   t1, 0(t0)

halt_loop:
    li   t0, 0x50000604
    li   t1, 0x5AFEC0DE
    sw   t1, 0(t0)
    j    halt_loop

/* M2 wheel-command conversion (leaf, clobbers t0,t1,a0) */
    .include "motor_cmd.inc"
