/* ============================================================================
 * File: soc_firmware.s
 * Description: Bare-metal Test & Integration Firmware for RISC-V Robot SoC
 * Exercises RV32IM CPU, rv_nna INT8 Accelerator, Safety Filter, UART, & PWM
 * ============================================================================
 */

    .section .text
    .globl _start

_start:
    /* 1. Initialize Stack Pointer (Top of RAM: 0x2000_4000) */
    li sp, 0x20004000

    /* 2. Base Addresses */
    li s0, 0x40000000   /* NNA_BASE */
    li s1, 0x50000600   /* SAFETY_BASE */
    li s2, 0x50000100   /* UART_BASE */
    li s3, 0x50000200   /* PWM_BASE */
    li s4, 0x20000000   /* RAM_BASE */

    /* 3. Send UART Startup Banner ('S', 'o', 'C', '\n').
       Poll STATUS (0x08) bit 0 TX_BUSY before every byte: a write while busy is dropped. */
banner_wait0:
    lw t1, 0x08(s2)
    andi t1, t1, 1
    bnez t1, banner_wait0
    li t0, 0x53         /* 'S' */
    sw t0, 0(s2)
banner_wait1:
    lw t1, 0x08(s2)
    andi t1, t1, 1
    bnez t1, banner_wait1
    li t0, 0x6F         /* 'o' */
    sw t0, 0(s2)
banner_wait2:
    lw t1, 0x08(s2)
    andi t1, t1, 1
    bnez t1, banner_wait2
    li t0, 0x43         /* 'C' */
    sw t0, 0(s2)
banner_wait3:
    lw t1, 0x08(s2)
    andi t1, t1, 1
    bnez t1, banner_wait3
    li t0, 0x0A         /* '\n' */
    sw t0, 0(s2)

    /* 4. Arm Safety Interlock */
    /* SAFETY_CTRL: bit 0 = ARM */
    li t0, 1
    sw t0, 0(s1)

    /* Feed Safety Watchdog */
    li t0, 1
    sw t0, 0x08(s1)

    /* 4b. Motor PWM (soc_pwm, M2 contract v3) exact zero-command arming
       sequence (M2_STEP1_DECISIONS.md sec. C). SIMULATION ONLY.
       ARM refused -> skip to spin_loop without the CAFEBABE token (TB fails). */
    li t0, 4
    sw t0, 0(s3)        /* CTRL.FAULT_CLR */
    sw zero, 0x04(s3)   /* CMD_L = 0 */
    sw zero, 0x08(s3)   /* CMD_R = 0 */
    sw zero, 0x0C(s3)   /* COMMIT (ignored while disarmed) */
arm_wait_shadow:
    lw t1, 0x10(s3)
    andi t1, t1, 512    /* STATUS bit9 SHADOW_ZERO */
    beqz t1, arm_wait_shadow
    li t0, 1
    sw t0, 0(s3)        /* CTRL.ARM_REQ */
    lw t1, 0x10(s3)
    andi t1, t1, 1      /* STATUS bit0 ARMED */
    beqz t1, spin_loop

    /* 5. Load Input Features into NNA Input Buffer (NNA_BASE + 0x100) */
    /* Feature vector: [0x14, 0xEC, 0x28, 0xD8] = [20, -20, 40, -40] packed as 0xD828EC14 */
    li t0, 0xD828EC14
    sw t0, 0x100(s0)

    /* 6. Load Bias and Weights into NNA Buffers */
    /* Bias: 0x00000010 (16) at Bias Buffer (NNA_BASE + 0x200) */
    li t0, 16
    sw t0, 0x200(s0)

    /* Weights for neuron 0: [0x05, 0x06, 0x07, 0x08] = [5, 6, 7, 8] packed as 0x08070605 */
    /* Weight Buffer (NNA_BASE + 0x400) */
    li t0, 0x08070605
    sw t0, 0x400(s0)

    /* 7. Configure and Launch Policy Inference */
    /* CONFIG_DIM: k_dim = 4 (inputs), m_dim = 1 (neuron) -> (1 << 16) | 4 = 0x00010004 */
    li t0, 0x00010004
    sw t0, 0x08(s0)

    /* CONFIG_ACT: act_type = 0 (Linear) */
    sw zero, 0x0C(s0)

    /* CONFIG_SCALE: scale_mult = 0x8000 (0.5 in Q16), scale_shift = 16 -> (16 << 16) | 0x8000 = 0x00108000 */
    li t0, 0x00108000
    sw t0, 0x10(s0)

    /* Launch NNA: CTRL = 0x01 (START) */
    li t0, 1
    sw t0, 0(s0)

wait_nna:
    /* Poll NNA STATUS (0x04) until bit 1 (DONE) is set */
    lw t0, 0x04(s0)
    andi t1, t0, 2
    beqz t1, wait_nna

    /* 8. Clear Done flag by writing 1 to CTRL bit 1 (CLEAR_DONE) */
    li t0, 2
    sw t0, 0(s0)

    /* Read execution cycle counter (0x18) */
    lw a1, 0x18(s0)
    sw a1, 0x104(s4)

    /* 9. Read Result from Output Buffer (NNA_BASE + 0x800) */
    li t2, 0x40000800
    lw a0, 0(t2)

    /* Store NNA inference result into RAM (RAM_BASE + 0x100) */
    sw a0, 0x100(s4)

    /* 10. Software Safety Verification & Clamping */
    /* Extract lower 8-bit signed velocity command */
    andi t0, a0, 0xFF
    slli t0, t0, 24
    srai t0, t0, 24

    /* Max allowed velocity = 64 */
    li t1, 64
    ble t0, t1, check_min
    mv t0, t1
    j apply_motor

check_min:
    li t1, -64
    bge t0, t1, apply_motor
    mv t0, t1

apply_motor:
    /* Write safe commanded velocity to Motor 0 Register (SAFETY_BASE + 0x10) */
    sw t0, 0x10(s1)

    /* Left motor signed command (contract v3, sign-magnitude, |cmd|<=1000):
       the clamped velocity [-64, 64] is written directly as CMD_L, CMD_R = 0,
       then COMMIT. (Old map: duty = t0 + 64 on the removed duty register.) */
    sw t0, 0x04(s3)     /* CMD_L */
    sw zero, 0x08(s3)   /* CMD_R */
    sw zero, 0x0C(s3)   /* COMMIT */

    /* DISARM before idling (ARMED/ACTIVE/SHADOW/CMD -> 0) */
    li t3, 2
    sw t3, 0(s3)

    /* Send Completion Character 'K' to UART */
    li t0, 0x4B         /* 'K' */
    sw t0, 0(s2)

    /* Store magic completion word 0xCAFEBABE to RAM at 0x20003FFC */
    li t1, 0x20003FFC
    li t0, 0xCAFEBABE
    sw t0, 0(t1)

spin_loop:
    /* Feed Watchdog periodically */
    li t0, 1
    sw t0, 0x08(s1)
    j spin_loop
