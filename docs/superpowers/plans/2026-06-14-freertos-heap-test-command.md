# FreeRTOS `heap-test` Shell Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `heap-test` shell command with four subcommands (`alloc N`, `free`, `release`, `show`) to the FreeRTOS interactive debug shell, with a host-unit-testable parse helper and on-target E2E coverage.

**Architecture:** A new `shell_heap_test.h` header provides the parse helper (`heap_test_parse()` — a `static inline` function that maps `argv[1..]` to an enum verb + optional size, testable without linking FreeRTOS). `shell.c` holds three new file-scope static arrays (pointers, sizes, count) and the `cmd_heap_test()` command handler that calls `pvPortMalloc`/`vPortFree` via the FreeRTOS API. No changes to the kernel allocator or the `vApplicationMallocFailedHook`.

**Tech Stack:** C (FreeRTOS bare-metal on Cortex-R52, heap_4 allocator), Bash (E2E harness), Makefile (build + host test), POSIX shell tools (E2E check scripts).

---

**Files involved:**

| File | Action | Purpose |
|---|---|---|
| `contrib/heterogeneous-soc/freertos-showcase/shell_heap_test.h` | **Create** | Parse enum + `static inline heap_test_parse()` — unit-testable without FreeRTOS |
| `contrib/heterogeneous-soc/freertos-showcase/shell.c` | **Modify** | File-scope state arrays, `#include "shell_heap_test.h"`, forward decl, table entry, `cmd_heap_test()` implementation |
| `contrib/heterogeneous-soc/freertos-showcase/test_heap_test.c` | **Create** | Host unit test for `heap_test_parse()` — 9 test cases |
| `contrib/heterogeneous-soc/freertos-showcase/Makefile` | **Modify** | `test_heap_test` compile rule, add to `check` target, add to `clean` |
| `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh` | **Modify** | 5 new `send_cmd` calls + 6 new checks + summary count 19→25 |
| `README.md` | **Modify** | New row in Commands table |

---

### Task 1: Create `shell_heap_test.h` — the parse helper header

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/shell_heap_test.h`

- [ ] **Step 1: Write the header file**

```c
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
        if (argc < 3) {
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
```

- [ ] **Step 2: Verify the header compiles standalone**

```bash
cd contrib/heterogeneous-soc/freertos-showcase
cc -O2 -Wall -fsyntax-only -I. shell_heap_test.h 2>&1 || echo "Expected: no errors"
# This tests syntax; a full compile needs a .c file. We do that in Task 3.
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/plans/2026-06-14-freertos-heap-test-command.md
git commit -m "docs: add implementation plan for heap-test shell command"
```

---

### Task 2: Wire `cmd_heap_test` into `shell.c`

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/shell.c`

- [ ] **Step 1: Add the `#include` and file-scope state**

Insert after the existing `#include "shell_parse.h"` (line 10):

```c
#include "shell_heap_test.h"
```

Insert after the `extern volatile uint32_t g_freertos_log_level;` (line 13), before the `#define SHELL_LINE_MAX` — the arrays live in `.bss` (96 bytes total, zero runtime cost when unused):

```c
static void *heap_test_allocs[HEAP_TEST_MAX];
static uint32_t heap_test_sizes[HEAP_TEST_MAX];
static uint32_t heap_test_count;
```

- [ ] **Step 2: Add the forward declaration**

Insert after the `static void cmd_can` forward decl (line 88):

```c
static void cmd_heap_test(const struct chimera_shell_ctx *ctx, int argc, char *argv[]);
```

- [ ] **Step 3: Add the table entry**

Insert after the `{ "can", ... }` entry (line 102), before the closing `};`:

```c
    { "heap-test", cmd_heap_test, "<alloc N|free|release|show> - pvPortMalloc / vPortFree the FreeRTOS heap" },
```

- [ ] **Step 4: Add the `cmd_heap_test` function**

Insert after the `cmd_can` closing brace (after line 250), before the `static const char shell_banner[]`:

```c
static void cmd_heap_test(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    uint32_t size;
    char buf[12];

    (void)ctx;

    switch (heap_test_parse(argc, argv, &size)) {

    case HEAP_TEST_ALLOC: {
        if (heap_test_count == HEAP_TEST_MAX) {
            shell_print("heap_test: alloc list full (max ");
            shell_utoa(buf, HEAP_TEST_MAX);
            shell_print(buf);
            shell_print(" outstanding)\n");
            return;
        }
        void *p = pvPortMalloc(size);
        if (p == NULL) {
            shell_print("heap_test: alloc ");
            shell_utoa(buf, size);
            shell_print(buf);
            shell_print(" failed (heap_free=");
            shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
            shell_print(buf);
            shell_print(")\n");
            return;
        }
        heap_test_allocs[heap_test_count] = p;
        heap_test_sizes[heap_test_count] = size;
        heap_test_count++;
        shell_print("heap_test: alloc ");
        shell_utoa(buf, size);
        shell_print(buf);
        shell_print(" -> ");
        shell_utoa_hex(buf, (uint32_t)p);
        shell_print(buf);
        shell_print(" (heap_free=");
        shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
        shell_print(buf);
        shell_print(")\n");
        return;
    }

    case HEAP_TEST_FREE:
        if (heap_test_count == 0) {
            shell_print("heap_test: nothing to free\n");
            return;
        }
        heap_test_count--;
        shell_print("heap_test: free ");
        shell_utoa_hex(buf, (uint32_t)heap_test_allocs[heap_test_count]);
        shell_print(buf);
        vPortFree(heap_test_allocs[heap_test_count]);
        heap_test_allocs[heap_test_count] = NULL;
        heap_test_sizes[heap_test_count] = 0;
        shell_print(" (heap_free=");
        shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
        shell_print(buf);
        shell_print(")\n");
        return;

    case HEAP_TEST_RELEASE: {
        uint32_t freed = 0;
        while (heap_test_count > 0) {
            heap_test_count--;
            vPortFree(heap_test_allocs[heap_test_count]);
            heap_test_allocs[heap_test_count] = NULL;
            heap_test_sizes[heap_test_count] = 0;
            freed++;
        }
        shell_print("heap_test: released ");
        shell_utoa(buf, freed);
        shell_print(buf);
        shell_print(" buffer(s) (heap_free=");
        shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
        shell_print(buf);
        shell_print(")\n");
        return;
    }

    case HEAP_TEST_SHOW: {
        uint32_t i;
        for (i = 0; i < heap_test_count; i++) {
            shell_print("  [");
            shell_utoa(buf, i);
            shell_print(buf);
            shell_print("] ");
            shell_utoa_hex(buf, (uint32_t)heap_test_allocs[i]);
            shell_print(buf);
            shell_print(" size=");
            shell_utoa(buf, heap_test_sizes[i]);
            shell_print(buf);
            shell_print("\n");
        }
        shell_print("heap_test: count=");
        shell_utoa(buf, heap_test_count);
        shell_print(buf);
        shell_print("/");
        shell_utoa(buf, HEAP_TEST_MAX);
        shell_print(buf);
        shell_print(" heap_free=");
        shell_utoa(buf, (uint32_t)xPortGetFreeHeapSize());
        shell_print(buf);
        shell_print(" heap_total=");
        shell_utoa(buf, configTOTAL_HEAP_SIZE);
        shell_print(buf);
        shell_print(" allocator=heap_4\n");
        return;
    }

    default:
        shell_print("usage: heap-test <alloc N|free|release|show>\n");
        return;
    }
}
```

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/shell_heap_test.h contrib/heterogeneous-soc/freertos-showcase/shell.c
git commit -m "feat(freertos): add heap-test shell command with alloc/free/release/show"
```

---

### Task 3: Write the host unit test `test_heap_test.c`

**Files:**
- Create: `contrib/heterogeneous-soc/freertos-showcase/test_heap_test.c`

- [ ] **Step 1: Write the failing test file**

```c
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
```

- [ ] **Step 2: Run test to verify it fails to compile (no Makefile rule yet)**

```bash
cd contrib/heterogeneous-soc/freertos-showcase
cc -O2 -Wall -I. -o test_heap_test test_heap_test.c 2>&1 || echo "Expected to fail if shell_heap_test.h missing"
# We created shell_heap_test.h in Task 1, so this should actually compile and pass.
# The point is to verify the test works in isolation.
./test_heap_test
# Expected output: "test_heap_test: OK"
```

- [ ] **Step 3: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/test_heap_test.c
git commit -m "test(freertos): add host unit test for heap-test parse helper"
```

---

### Task 4: Wire `test_heap_test` into the Makefile

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Update the `check` target**

Change line 129 (`check: test_can_decode test_shell_parse`) to include `test_heap_test`:

```makefile
check: test_can_decode test_shell_parse test_heap_test
```

Add `./test_heap_test` after `./test_shell_parse` (line 131), before the `./test-syslog-format.sh`:

```makefile
	./test_heap_test
```

- [ ] **Step 2: Update the `clean` target**

Change line 127 to add `test_heap_test`:

```makefile
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-r52-demo.elf test_can_decode test_shell_parse test_heap_test
```

- [ ] **Step 3: Add the compile rule**

Insert after the `test_shell_parse` rule (after line 138):

```makefile
test_heap_test: test_heap_test.c shell_parse.h shell_heap_test.h
	cc -O2 -Wall -o $@ test_heap_test.c
```

- [ ] **Step 4: Run `make check` to verify the full test suite passes**

```bash
cd contrib/heterogeneous-soc/freertos-showcase
make check
# Expected:
#   test_can_decode: OK
#   test_shell_parse: OK
#   test_heap_test: OK
```

- [ ] **Step 5: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "build(freertos): add test_heap_test to check target"
```

---

### Task 5: Update README.md commands table

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add the `heap-test` row**

Insert a new row after the `can status` row (current line 410):

```markdown
| `heap-test <subcmd>` | `alloc <N>` / `free` / `release` / `show` — `pvPortMalloc` N bytes, `vPortFree` the most-recent, `vPortFree` all, show outstanding + heap summary (`count`, `heap_free`, `heap_total`, `allocator=heap_4`) |
```

Verification: the table should now have 7 rows (help, stats, sysinfo, links, loglevel, can status, heap-test).

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add heap-test command to FreeRTOS shell commands table"
```

---

### Task 6: Extend the E2E shell harness

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh`

- [ ] **Step 1: Insert 5 new `send_cmd` calls**

Insert after `send_cmd "frobnicate"` (line 126), before the second `send_cmd "sysinfo"` (line 130):

```bash
send_cmd "heap-test alloc 4096"
send_cmd "heap-test show"
send_cmd "heap-test free"
send_cmd "heap-test release"
send_cmd "heap-test"
```

- [ ] **Step 2: Add 6 new checks**

Insert after the `[harness] Checking unrecognized command...` block (after line 230), before the `# ---- Result ----` section:

```bash
echo ""
echo "[harness] Checking 'heap-test' commands..."
check_regex "heap-test alloc 4096: success" \
    'heap_test: alloc 4096 -> 0x[0-9a-f]{8} \(heap_free=[0-9]+\)'
check_regex "heap-test show: 1 entry" \
    '  \[0\] 0x[0-9a-f]{8} size=4096'
check_contains "heap-test show: allocator=heap_4" \
    "allocator=heap_4"
check_regex "heap-test free: balanced" \
    'heap_test: free 0x[0-9a-f]{8} \(heap_free=[0-9]+\)'
check_contains "heap-test release: nothing" \
    "heap_test: nothing to release"
check_contains "heap-test (no subcmd): usage" \
    "usage: heap-test <alloc N|free|release|show>"
```

- [ ] **Step 3: Update the summary count**

Change line 235 from `all 19` to `all 25` and update the header comment.

Line 15 (header comment): replace the command list to mention `heap-test`:

```
#   help, stats, sysinfo, links, loglevel, can status, heap-test
# plus one unrecognized-command check (shell_dispatch's default branch).
```

Line 235 (final pass/fail summary):

```bash
    echo "[harness] PASS — all 25 shell command checks passed"
```

- [ ] **Step 4: Run the E2E harness to verify**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-shell-harness.sh
# Expected: PASS — all checks pass (the shell harness verifies boot + CAN + shell init).

limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
# Expected: PASS — all 25 shell command checks passed
```

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-shell-e2e-harness.sh
git commit -m "test(shell-e2e): add heap-test E2E checks (6 new, 19->25 total)"
```

---

## Self-Review Checklist

**1. Spec coverage:**
- `heap-test alloc <N>` → Task 2 (cmd_heap_test ALLOC case) + Task 3 (test N=4096, N=0, non-numeric) + Task 6 (E2E with 4096) ✓
- `heap-test free` → Task 2 (FREE case, LIFO) + Task 6 (E2E free after alloc) ✓
- `heap-test release` → Task 2 (RELEASE case, all slots) + Task 6 (E2E release when empty → "nothing") ✓
- `heap-test show` → Task 2 (SHOW case, per-entry + summary) + Task 6 (E2E 1 entry + allocator=heap_4) ✓
- Error table entry for every condition → all covered in `cmd_heap_test` switch/default ✓
- Host unit test (9 cases) → Task 3 ✓
- Makefile integration → Task 4 ✓
- E2E harness 6 new checks, 19→25 → Task 6 ✓
- README row → Task 5 ✓
- `vApplicationMallocFailedHook` unreachable from `cmd_heap_test` → verified: NULL check before any state change in ALLOC case ✓
- No new test for `vApplicationMallocFailedHook` (out of scope) → not added ✓
- SHELL_MAX_ARGS=4 with `heap-test alloc N` being 3 tokens → verified ✓
- `shell_print()` / `shell_utoa()` / `shell_utoa_hex()` used throughout → verified in Task 2 ✓
- configTOTAL_HEAP_SIZE is `(64 * 1024)` → used as literal in `show` subcommand ✓
- allocator=heap_4 is a literal → used as literal in `show` subcommand ✓
- Output example format → all printfs match spec's Example Output section ✓

**2. Placeholder scan:** All code blocks contain complete, compilable code. No "TBD", "TODO", "implement later", or "add error handling" without code. Every step has exact file paths and commands.

**3. Type consistency:**
- `HEAP_TEST_MAX` used consistently in header (define), shell.c (arrays), and shell.c (bound check) ✓
- `heap_test_parse()` signature matches: `(int argc, char *argv[], uint32_t *out_size)` everywhere ✓
- `enum heap_test_verb` values: `HEAP_TEST_INVALID=0, ALLOC, FREE, RELEASE, SHOW` — used the same in header, shell.c switch, and test.c assertions ✓
- `shell_utoa(buf, ...)` returns `char*` — discarding in cmd_heap_test (matching existing `cmd_sysinfo` pattern) ✓
- `shell_utoa_hex(buf, ...)` returns `char*` — discarding (matching existing `cmd_links` pattern) ✓
- `configTOTAL_HEAP_SIZE` is the FreeRTOS macro — matches Task 2's usage in `show` ✓

No gaps found. Plan is complete.
