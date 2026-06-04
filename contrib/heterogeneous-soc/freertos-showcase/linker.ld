ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 8M
}

SECTIONS
{
    .text : {
        *(.text.init)
        KEEP(*(.text.freertos_risc_v_trap_handler*))
        KEEP(*(.text.freertos_risc_v_exception_handler*))
        KEEP(*(.text.freertos_risc_v_interrupt_handler*))
        KEEP(*(.text.freertos_risc_v_mtimer_interrupt_handler*))
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
