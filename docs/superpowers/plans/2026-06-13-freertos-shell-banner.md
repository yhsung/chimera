# FreeRTOS Shell Startup Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print a "CHIMERA" ASCII-art banner once, before the first `chimera> ` prompt, when the FreeRTOS interactive shell starts.

**Architecture:** Add a `static const char shell_banner[]` constant (the 6-row ANSI-Shadow "CHIMERA" FIGlet art, UTF-8 box-drawing characters) to `shell.c`, and print it once at the top of `shell_task()` before the existing `"\n" SHELL_PROMPT` print.

**Tech Stack:** Bare-metal C (Cortex-R52, `-ffreestanding`), existing `shell_print()` UART helper.

---

### Task 1: Add `shell_banner` constant and print it at shell startup

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/shell.c:250-252`

- [ ] **Step 1: Insert the banner constant**

In `contrib/heterogeneous-soc/freertos-showcase/shell.c`, insert a new `static const char shell_banner[]` declaration between the end of `cmd_can()` (line 250) and the start of `shell_dispatch()` (line 252):

```c
static void cmd_can(const struct chimera_shell_ctx *ctx, int argc, char *argv[])
{
    struct can_status st;
    char buf[12];

    (void)ctx;

    if (argc < 2 || !shell_str_eq(argv[1], "status")) {
        shell_print("usage: can status\n");
        return;
    }

    can_get_status(&st);

    shell_print("sr=");
    shell_utoa_hex(buf, st.sr);
    shell_print(buf);
    shell_print(" rx_frames=");
    shell_utoa(buf, st.rx_frames);
    shell_print(buf);
    shell_print("\n");
}

static const char shell_banner[] =
    " ██████╗██╗  ██╗██╗███╗   ███╗███████╗██████╗  █████╗ \n"
    "██╔════╝██║  ██║██║████╗ ████║██╔════╝██╔══██╗██╔══██╗\n"
    "██║     ███████║██║██╔████╔██║█████╗  ██████╔╝███████║\n"
    "██║     ██╔══██║██║██║╚██╔╝██║██╔══╝  ██╔══██╗██╔══██║\n"
    "╚██████╗██║  ██║██║██║ ╚═╝ ██║███████╗██║  ██║██║  ██║\n"
    " ╚═════╝╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝\n";

static void shell_dispatch(const struct chimera_shell_ctx *ctx, char *line)
{
```

- [ ] **Step 2: Print the banner once at shell startup**

In the same file, in `shell_task()`, change:

```c
    shell_print("\n" SHELL_PROMPT);
```

to:

```c
    shell_print(shell_banner);
    shell_print("\n" SHELL_PROMPT);
```

`shell_banner` already ends with `\n`, so combined with the leading `\n` in `"\n" SHELL_PROMPT` this produces: 6 banner rows, one blank line, then `chimera> ` — matching the standalone-banner design (no `=` border/tagline).

- [ ] **Step 3: Verify the file is valid UTF-8**

Run:

```bash
file -I contrib/heterogeneous-soc/freertos-showcase/shell.c
```

Expected: `... charset=utf-8` (confirms the box-drawing characters were written as proper UTF-8 multi-byte sequences, not mangled/replaced).

- [ ] **Step 4: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/shell.c
git commit -m "feat(freertos): print CHIMERA banner at shell startup"
```

---

### Task 2: Document the startup banner in the README

**Files:**
- Modify: `README.md:376` (end of the **Interactive Shell** intro paragraph)

- [ ] **Step 1: Add a sentence about the banner**

In `README.md`, the **Interactive Shell** section currently reads (lines 369-377):

```markdown
## Interactive Shell

The FreeRTOS firmware exposes an interactive debug shell on UART0 — the same
serial console used for log output (`-nographic`, tmux pane 5 in the 9-pane
layout above). UART0 RX is interrupt-driven (GIC SPI32 / INTID 32,
level-sensitive); a dedicated `shell` task reads bytes from `uart_rx_queue`
(filled by `uart_rx_isr()`), does line editing (echo, backspace/DEL, CR/LF),
tokenizes, and dispatches into `shell_cmd_table[]` (`shell.c`).

Attach to the FreeRTOS pane and type at the `chimera> ` prompt:
```

Change the last sentence of the first paragraph from:

```markdown
tokenizes, and dispatches into `shell_cmd_table[]` (`shell.c`).
```

to:

```markdown
tokenizes, and dispatches into `shell_cmd_table[]` (`shell.c`). On startup,
before the first prompt, the shell prints a "CHIMERA" ASCII-art banner
(ANSI-Shadow FIGlet font, UTF-8 box-drawing characters).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document the FreeRTOS shell startup banner"
```

---

### Task 3: Build in Lima and verify the banner renders correctly

**Files:** none (verification only)

- [ ] **Step 1: Deploy source to the Lima VM**

Run from the macOS host, repo root:

```bash
bash scripts/heterogeneous-soc/host-install-lima-host.sh
```

Expected: completes without error (syncs the repo, including the updated `shell.c`, into `~/chimera-src` on the `qemu-dev` Lima VM).

- [ ] **Step 2: Run the FreeRTOS harness (builds + boots + checks HELLO)**

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-freertos-harness.sh
```

Expected: `[harness] PASS after <N>s` (confirms `freertos-r52-demo.elf` rebuilt cleanly with the new `shell_banner` constant and FreeRTOS booted normally).

- [ ] **Step 3: Confirm the banner appears in the captured FreeRTOS UART log**

```bash
limactl shell qemu-dev -- bash -c 'grep -c "██████" $(ls -t /tmp/harness-logs/freertos-*.log | head -1)'
```

Expected: a non-zero count — the banner's block-drawing characters were transmitted and rendered correctly (not mojibake) before the first `chimera> ` prompt.

- [ ] **Step 4: (Optional) View the rendered banner**

```bash
limactl shell qemu-dev -- bash -c 'head -10 $(ls -t /tmp/harness-logs/freertos-*.log | head -1)'
```

Expected: the 6-row "CHIMERA" ASCII-art banner, followed by a blank line and `chimera> `.

No commit for this task — it's verification of Tasks 1-2's changes, already deployed via source sync.
