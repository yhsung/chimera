#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#include <stdint.h>

#define configUSE_PREEMPTION 1
#define configUSE_TIME_SLICING 1
#define configUSE_IDLE_HOOK 0
#define configUSE_TICK_HOOK 0
#define configCPU_CLOCK_HZ 10000000UL
#define configTICK_RATE_HZ 1000
#define configMAX_PRIORITIES 5
#define configMINIMAL_STACK_SIZE 256
#define configMAX_TASK_NAME_LEN 16
#define configTOTAL_HEAP_SIZE (64 * 1024)
#define configMAX_SYSCALL_INTERRUPT_PRIORITY 0
#define configKERNEL_INTERRUPT_PRIORITY 0
#define configUSE_16_BIT_TICKS 0
#define configIDLE_SHOULD_YIELD 1
#define configUSE_MUTEXES 1
#define configQUEUE_REGISTRY_SIZE 0
#define configCHECK_FOR_STACK_OVERFLOW 2
#define configUSE_RECURSIVE_MUTEXES 0
#define configUSE_MALLOC_FAILED_HOOK 1
#define configUSE_APPLICATION_TASK_TAG 0
#define configUSE_COUNTING_SEMAPHORES 0
#define configGENERATE_RUN_TIME_STATS 0
#define configSUPPORT_STATIC_ALLOCATION 0
#define configSUPPORT_DYNAMIC_ALLOCATION 1
#define configUSE_TRACE_FACILITY 0
#define configUSE_TASK_NOTIFICATIONS 1
#define configISR_STACK_SIZE_WORDS 256
#define configASSERT(x) do { if (!(x)) { for (;;) { } } } while (0)

#define INCLUDE_vTaskDelay 1
#define INCLUDE_vTaskDelete 1
#define INCLUDE_vTaskSuspend 1
#define INCLUDE_xTaskGetSchedulerState 1
#define INCLUDE_xTaskGetIdleTaskHandle 1
#define INCLUDE_xTaskGetCurrentTaskHandle 1
#define INCLUDE_uxTaskPriorityGet 1
#define INCLUDE_uxTaskGetStackHighWaterMark 1

/* ── ARM_CR5 (GICv2) port configuration ─────────────────────────────────── */
/* GIC distributor base and the offset to its CPU interface, matching the
 * chimera-r52-freertos-demo machine's memory map (GICD 0x08000000,
 * GICC 0x08010000). */
#define configINTERRUPT_CONTROLLER_BASE_ADDRESS         0x08000000UL
#define configINTERRUPT_CONTROLLER_CPU_INTERFACE_OFFSET 0x00010000UL

/* QEMU's TYPE_ARM_GIC is built with num-priority-bits = 5 -> 32 levels. */
#define configUNIQUE_INTERRUPT_PRIORITIES               32
#define configMAX_API_CALL_INTERRUPT_PRIORITY           18

/* The tick is driven by the Cortex-R52 architected generic timer; these call
 * helpers defined in freertos_main.c. */
#ifndef __ASSEMBLER__
void vConfigureTickInterrupt(void);
void vClearTickInterrupt(void);
#endif
#define configSETUP_TICK_INTERRUPT()  vConfigureTickInterrupt()
#define configCLEAR_TICK_INTERRUPT()  vClearTickInterrupt()

#endif
