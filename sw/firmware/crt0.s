/* ============================================================================
 * File: crt0.s
 * Description: RV32IM C Runtime Startup for Robot SoC
 * ============================================================================
 */

    .section .text.entry
    .globl _start
    .type _start, @function

_start:
    /* Disable interrupts initially */
    /* Set stack pointer */
    la sp, _stack_top

    /* Copy .data from ROM (_sidata) to RAM (_sdata) */
    la a0, _sidata
    la a1, _sdata
    la a2, _edata
    bge a1, a2, 2f
1:
    lw a3, 0(a0)
    sw a3, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    blt a1, a2, 1b
2:

    /* Zero .bss section */
    la a0, _sbss
    la a1, _ebss
    bge a0, a1, 4f
3:
    sw zero, 0(a0)
    addi a0, a0, 4
    blt a0, a1, 3b
4:

    /* Call C main */
    call main

    /* Infinite loop if main returns */
_hang:
    wfi
    j _hang

    .size _start, . - _start
