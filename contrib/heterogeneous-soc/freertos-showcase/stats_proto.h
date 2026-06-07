#ifndef HETEROGENEOUS_SOC_STATS_PROTO_H
#define HETEROGENEOUS_SOC_STATS_PROTO_H

#include <stdint.h>

#define HSOC_STATS_MAGIC 0x53544154U  /* "STAT" */

/*
 * Written exclusively by FreeRTOS into IVSHMEM3 shmem.
 * ARM-Linux polls generation to detect new snapshots.
 *
 * Write protocol (FreeRTOS):
 *   1. Write all payload fields via direct volatile store (one field at a time).
 *   2. __sync_synchronize()
 *   3. generation = generation + 1  (volatile store + fence)
 *   magic is written once at init and never changes.
 *
 * Read protocol (ARM-Linux):
 *   1. shm_read the whole struct into a local copy.
 *   2. __sync_synchronize()
 *   3. Skip if local.generation == last_seen_generation.
 *   4. Verify local.magic == HSOC_STATS_MAGIC.
 */
struct hsoc_stats_snapshot {
    uint32_t          magic;       /* HSOC_STATS_MAGIC — identifies this BAR2 */
    volatile uint32_t generation;  /* monotonically incremented by FreeRTOS */
    uint32_t          arm_count;   /* total HELLOs received from ARM-Linux */
    uint32_t          riscv_count; /* total HELLOs received from RISCV-Linux */
    uint32_t          mips_count;  /* total HELLOs received from MIPS-Linux */
    uint32_t          pad;
    int64_t           tick_sec;    /* FreeRTOS tick time of this snapshot */
    int64_t           tick_nsec;
    uint32_t          arm_cpu_pct_x100;   /* latest ARM-Linux CPU busy %, x100 */
    uint32_t          arm_mem_pct_x100;   /* latest ARM-Linux used-mem %, x100 */
    uint32_t          riscv_cpu_pct_x100; /* latest RISCV-Linux CPU busy %, x100 */
    uint32_t          riscv_mem_pct_x100; /* latest RISCV-Linux used-mem %, x100 */
    uint32_t          mips_cpu_pct_x100;  /* latest MIPS-Linux CPU busy %, x100 */
    uint32_t          mips_mem_pct_x100;  /* latest MIPS-Linux used-mem %, x100 */
};

#endif
