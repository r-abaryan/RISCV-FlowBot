/* Linker script for RV32IM Mobile Robot SoC */
MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 8K
    RAM (rwx) : ORIGIN = 0x20000000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        . = ALIGN(4);
        *(.text._start)
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > ROM

    .data : {
        . = ALIGN(4);
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
    } > RAM AT > ROM

    .bss : {
        . = ALIGN(4);
        *(.bss*)
        *(.sbss*)
        . = ALIGN(4);
    } > RAM
}
