    .syntax unified
    .arm

    /* ── Exception vector table ──────────────────────────────────────────── */
    .section .vectors, "ax"
    .globl _start
_start:
    b    reset_handler            /* Reset */
    b    .                        /* Undefined */
    ldr  pc, =FreeRTOS_SWI_Handler/* Supervisor Call (FreeRTOS yield) */
    b    .                        /* Prefetch Abort */
    b    .                        /* Data Abort */
    nop                           /* Reserved (HYP trap entry on R-profile) */
    ldr  pc, =FreeRTOS_IRQ_Handler/* IRQ */
    b    .                        /* FIQ */

    /* ── Reset ───────────────────────────────────────────────────────────── */
    .section .text.init, "ax"
    .globl reset_handler
reset_handler:
    /* Point the vector base at our table. */
    ldr  r0, =_start
    mcr  p15, 0, r0, c12, c0, 0   /* VBAR */

    /* IRQ mode stack */
    cps  #0x12                    /* IRQ mode */
    ldr  sp, =_stack_irq_top

    /* Supervisor mode stack */
    cps  #0x13                    /* SVC mode */
    ldr  sp, =_stack_svc_top

    /* System mode (shares the System/User stack used by tasks before sched) */
    cps  #0x1F                    /* System mode */
    ldr  sp, =_stack_top

    /* Enable the FPU/NEON: CPACR cp10/cp11 full access, then FPEXC.EN. */
    mrc  p15, 0, r0, c1, c0, 2    /* CPACR */
    orr  r0, r0, #(0xF << 20)     /* cp10 + cp11 full access */
    mcr  p15, 0, r0, c1, c0, 2
    isb
    mov  r0, #0x40000000          /* FPEXC.EN */
    vmsr fpexc, r0

    /* Clear BSS */
    ldr  r0, =__bss_start
    ldr  r1, =__bss_end
    mov  r2, #0
1:
    cmp  r0, r1
    bge  2f
    str  r2, [r0], #4
    b    1b
2:
    bl   main
3:
    b    3b

    /* ── Mode stacks (reserve space inside .bss) ─────────────────────────── */
    .section .bss
    .align 3
    .space 1024
_stack_irq_top:
    .space 1024
_stack_svc_top:
