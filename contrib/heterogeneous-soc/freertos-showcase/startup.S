    .section .text.init
    .globl _start

_start:
    la sp, _stack_top

    /* Install the FreeRTOS trap handler before any exception can occur.
     * This also prevents --gc-sections from removing the trap handler section,
     * since startup.S now holds a direct reference to the symbol. */
    la t0, freertos_risc_v_trap_handler
    csrw mtvec, t0

    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b

2:
    call main

3:
    j 3b
