/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_SHELL_HEAP_TEST_H
#define HETEROGENEOUS_SOC_FREERTOS_SHELL_HEAP_TEST_H

#include <stdint.h>
#include "shell_parse.h"

#define HEAP_TEST_MAX 8

enum heap_test_verb {
    HEAP_TEST_INVALID = 0,
    HEAP_TEST_ALLOC,
    HEAP_TEST_FREE,
    HEAP_TEST_RELEASE,
    HEAP_TEST_SHOW,
};

/* Parse argv[1..] into a verb + optional size.
 *
 * Returns HEAP_TEST_INVALID for any malformed input (no verb, unknown verb,
 * alloc with missing or zero size). `out_size` is written only for
 * HEAP_TEST_ALLOC; callers must not rely on its value for other verbs.
 *
 * This is static inline so a host unit test can include the header and
 * verify argument parsing without linking the FreeRTOS kernel. */
static inline enum heap_test_verb heap_test_parse(
    int argc, char *argv[], uint32_t *out_size)
{
    if (argc < 2) {
        return HEAP_TEST_INVALID;
    }

    if (shell_str_eq(argv[1], "alloc")) {
        if (argc != 3) {
            return HEAP_TEST_INVALID;
        }
        *out_size = shell_parse_uint(argv[2]);
        if (*out_size == 0) {
            return HEAP_TEST_INVALID;
        }
        return HEAP_TEST_ALLOC;
    }

    if (shell_str_eq(argv[1], "free")) {
        if (argc != 2) {
            return HEAP_TEST_INVALID;
        }
        return HEAP_TEST_FREE;
    }

    if (shell_str_eq(argv[1], "release")) {
        if (argc != 2) {
            return HEAP_TEST_INVALID;
        }
        return HEAP_TEST_RELEASE;
    }

    if (shell_str_eq(argv[1], "show")) {
        if (argc != 2) {
            return HEAP_TEST_INVALID;
        }
        return HEAP_TEST_SHOW;
    }

    return HEAP_TEST_INVALID;
}

#endif
