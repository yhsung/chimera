#include <stddef.h>
#include <stdint.h>

#include <glib.h>

#include "../../contrib/heterogeneous-soc/ivshmem_proto.h"

static void test_magic_values(void)
{
    g_assert_cmphex(PING_MAGIC, ==, 0x50494e47U);
    g_assert_cmphex(PONG_MAGIC, ==, 0x504f4e47U);
}

static void test_layout_offsets(void)
{
    g_assert_cmpuint(sizeof(struct shm_msg), ==, 24);
    g_assert_cmpuint(sizeof(struct shm_channel), ==, 32);
    g_assert_cmpuint(offsetof(struct shm_channel, msg), ==, 8);
    g_assert_cmpuint(offsetof(struct shm_layout, arm_to_riscv), ==, 0);
    g_assert_cmpuint(offsetof(struct shm_layout, riscv_to_arm), ==, 0x1000);
    g_assert_cmpuint(sizeof(struct shm_layout), ==, 0x1000 + sizeof(struct shm_channel));
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/heterogeneous-soc/magic-values", test_magic_values);
    g_test_add_func("/heterogeneous-soc/layout-offsets", test_layout_offsets);

    return g_test_run();
}
