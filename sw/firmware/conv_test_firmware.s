/* V-CONV test ROM (M11b M2 step 3a). Runs motor_cmd_conv for every
 * v_wheel in -256..255 (512 values) and stores cmd[i] (v = i - 256) as a
 * 32-bit word at RAM 0x20001000 + 4*i. Then writes 0xC0BDC0DE to
 * 0x20003FFC. Touches no peripheral (motors stay disarmed/zero). Sim only. */
.section .text._start
    .globl _start
_start:
    li   s0, -256             /* v */
    li   s1, 256              /* end (exclusive) */
    li   s2, 0x20001000       /* out pointer */
loop:
    mv   a0, s0
    jal  ra, motor_cmd_conv
    sw   a0, 0(s2)
    addi s2, s2, 4
    addi s0, s0, 1
    blt  s0, s1, loop
    li   t0, 0x20003FFC
    li   t1, 0xC0BDC0DE
    sw   t1, 0(t0)
halt:
    j    halt

    .include "motor_cmd.inc"
