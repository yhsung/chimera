ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
    .text : {
        *(.text.init)
        *(.text*)
        *(.rodata*)
    } > RAM

    .data : {
        *(.data*)
    } > RAM

    .bss : {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        __bss_end = .;
    } > RAM

    . = ALIGN(16);
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
