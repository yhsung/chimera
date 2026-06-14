/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#ifndef HETEROGENEOUS_SOC_FREERTOS_SHELL_PARSE_H
#define HETEROGENEOUS_SOC_FREERTOS_SHELL_PARSE_H

#include <stdint.h>

#define SHELL_MAX_ARGS 4

/* Exact string comparison (freestanding libc has no strcmp). */
static inline int shell_str_eq(const char *a, const char *b)
{
    while (*a != '\0' && *b != '\0') {
        if (*a != *b) {
            return 0;
        }
        a++;
        b++;
    }
    return *a == *b;
}

/* Decimal string -> uint32_t. Stops at the first non-digit. Empty/non-digit
 * input returns 0. */
static inline uint32_t shell_parse_uint(const char *s)
{
    uint32_t v = 0;

    while (*s >= '0' && *s <= '9') {
        v = (v * 10u) + (uint32_t)(*s - '0');
        s++;
    }

    return v;
}

/* Split `line` in place on runs of spaces, writing '\0' at each separator and
 * filling argv[] with pointers to up to SHELL_MAX_ARGS tokens. Returns the
 * token count (argc). Extra tokens beyond SHELL_MAX_ARGS are ignored (argc
 * caps at SHELL_MAX_ARGS, but parsing still consumes the whole line so a
 * later '\0' isn't left mid-string). */
static inline int shell_tokenize(char *line, char *argv[SHELL_MAX_ARGS])
{
    int argc = 0;
    char *p = line;

    while (*p != '\0') {
        while (*p == ' ') {
            *p = '\0';
            p++;
        }

        if (*p == '\0') {
            break;
        }

        if (argc < SHELL_MAX_ARGS) {
            argv[argc++] = p;
        }

        while (*p != '\0' && *p != ' ') {
            p++;
        }
    }

    return argc;
}

#endif
