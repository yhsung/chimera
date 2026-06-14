/*
 * Copyright 2026 Yuehhsin Sung
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/* Host unit test for shell_parse.h helpers. Build: cc -O2 -Wall -o test_shell_parse test_shell_parse.c */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "shell_parse.h"

int main(void)
{
    /* shell_str_eq */
    assert(shell_str_eq("help", "help"));
    assert(!shell_str_eq("help", "hel"));
    assert(!shell_str_eq("hel", "help"));
    assert(!shell_str_eq("help", "Help"));
    assert(shell_str_eq("", ""));

    /* shell_parse_uint */
    assert(shell_parse_uint("0") == 0);
    assert(shell_parse_uint("3") == 3);
    assert(shell_parse_uint("42") == 42);
    assert(shell_parse_uint("") == 0);
    assert(shell_parse_uint("abc") == 0);
    assert(shell_parse_uint("12abc") == 12);

    /* shell_tokenize */
    {
        char line[32];
        char *argv[SHELL_MAX_ARGS];
        int argc;

        strcpy(line, "help");
        argc = shell_tokenize(line, argv);
        assert(argc == 1);
        assert(shell_str_eq(argv[0], "help"));

        strcpy(line, "can status");
        argc = shell_tokenize(line, argv);
        assert(argc == 2);
        assert(shell_str_eq(argv[0], "can"));
        assert(shell_str_eq(argv[1], "status"));

        strcpy(line, "  loglevel   2  ");
        argc = shell_tokenize(line, argv);
        assert(argc == 2);
        assert(shell_str_eq(argv[0], "loglevel"));
        assert(shell_str_eq(argv[1], "2"));

        strcpy(line, "");
        argc = shell_tokenize(line, argv);
        assert(argc == 0);

        strcpy(line, "   ");
        argc = shell_tokenize(line, argv);
        assert(argc == 0);

        /* More than SHELL_MAX_ARGS tokens: argc caps, first SHELL_MAX_ARGS
         * tokens are still correctly terminated. */
        strcpy(line, "a b c d e f");
        argc = shell_tokenize(line, argv);
        assert(argc == SHELL_MAX_ARGS);
        assert(shell_str_eq(argv[0], "a"));
        assert(shell_str_eq(argv[1], "b"));
        assert(shell_str_eq(argv[2], "c"));
        assert(shell_str_eq(argv[3], "d"));
    }

    printf("test_shell_parse: OK\n");
    return 0;
}
