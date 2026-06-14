/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Host unit test for shell_heap_test.h parse helper.
 * Build: cc -O2 -Wall -o test_heap_test test_heap_test.c */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "shell_parse.h"
#include "shell_heap_test.h"

int main(void)
{
    uint32_t size;

    /* HEAP_TEST_SHOW — exact 2-arg form */
    {
        char *argv[] = { "heap-test", "show", NULL };
        size = 0xDEAD;
        assert(heap_test_parse(2, argv, &size) == HEAP_TEST_SHOW);
        assert(size == 0xDEAD);  /* unchanged by show */
    }

    /* HEAP_TEST_FREE — exact 2-arg form */
    {
        char *argv[] = { "heap-test", "free", NULL };
        size = 0xDEAD;
        assert(heap_test_parse(2, argv, &size) == HEAP_TEST_FREE);
        assert(size == 0xDEAD);
    }

    /* HEAP_TEST_RELEASE — exact 2-arg form */
    {
        char *argv[] = { "heap-test", "release", NULL };
        size = 0xDEAD;
        assert(heap_test_parse(2, argv, &size) == HEAP_TEST_RELEASE);
        assert(size == 0xDEAD);
    }

    /* HEAP_TEST_ALLOC with valid size */
    {
        char *argv[] = { "heap-test", "alloc", "4096", NULL };
        size = 0;
        assert(heap_test_parse(3, argv, &size) == HEAP_TEST_ALLOC);
        assert(size == 4096);
    }

    /* argc < 2 -> INVALID */
    {
        char *argv[] = { "heap-test", NULL };
        assert(heap_test_parse(1, argv, &size) == HEAP_TEST_INVALID);
    }

    /* Unknown verb -> INVALID */
    {
        char *argv[] = { "heap-test", "bogus", NULL };
        assert(heap_test_parse(2, argv, &size) == HEAP_TEST_INVALID);
    }

    /* alloc with argc < 3 (missing N) -> INVALID */
    {
        char *argv[] = { "heap-test", "alloc", NULL };
        assert(heap_test_parse(2, argv, &size) == HEAP_TEST_INVALID);
    }

    /* alloc with size == 0 -> INVALID */
    {
        char *argv[] = { "heap-test", "alloc", "0", NULL };
        size = 0xDEAD;
        assert(heap_test_parse(3, argv, &size) == HEAP_TEST_INVALID);
        assert(size == 0);  /* shell_parse_uint("0") returns 0 */
    }

    /* alloc with non-numeric -> INVALID (shell_parse_uint returns 0) */
    {
        char *argv[] = { "heap-test", "alloc", "abc", NULL };
        size = 0xDEAD;
        assert(heap_test_parse(3, argv, &size) == HEAP_TEST_INVALID);
        assert(size == 0);
    }

    printf("test_heap_test: OK\n");
    return 0;
}
