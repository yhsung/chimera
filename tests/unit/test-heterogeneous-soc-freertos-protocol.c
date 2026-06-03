#include <stddef.h>
#include <stdint.h>

#include <glib.h>

#include "../../contrib/heterogeneous-soc/freertos-showcase/hello_proto.h"

static void test_magic_values(void)
{
    g_assert_cmphex(HSOC_HELLO_MAGIC, ==, 0x48454c4fU);
    g_assert_cmpuint(HSOC_PROTO_VERSION, ==, 1);
}

static void test_layout_offsets(void)
{
    g_assert_cmpuint(sizeof(struct hsoc_hello_msg), ==, 96);
    g_assert_cmpuint(sizeof(struct hsoc_channel), ==, 104);
    g_assert_cmpuint(offsetof(struct hsoc_channel, msg), ==, 8);
    g_assert_cmpuint(offsetof(struct hsoc_layout, linux_to_freertos), ==, 0);
    g_assert_cmpuint(offsetof(struct hsoc_layout, freertos_to_linux), ==,
                     0x1000);
}

int main(int argc, char **argv)
{
    g_test_init(&argc, &argv, NULL);

    g_test_add_func("/heterogeneous-soc-freertos/magic-values",
                    test_magic_values);
    g_test_add_func("/heterogeneous-soc-freertos/layout-offsets",
                    test_layout_offsets);

    return g_test_run();
}
