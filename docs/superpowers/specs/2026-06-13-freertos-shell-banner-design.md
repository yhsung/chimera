# FreeRTOS Shell Startup Banner Design

**Date:** 2026-06-13
**Status:** Draft

## Goal

Display a "CHIMERA" ASCII-art banner once when the FreeRTOS interactive shell
(`shell.c`, added in the prior interactive-shell work) starts up, before the
first `chimera> ` prompt is printed.

## Banner Content

ANSI-Shadow FIGlet rendering of "CHIMERA": 6 rows, 54 visible columns, using
UTF-8 box-drawing characters (`█ ╗ ║ ╝ ═ ╔` etc.). Printed standalone — no
border or tagline.

```
 ██████╗██╗  ██╗██╗███╗   ███╗███████╗██████╗  █████╗ 
██╔════╝██║  ██║██║████╗ ████║██╔════╝██╔══██╗██╔══██╗
██║     ███████║██║██╔████╔██║█████╗  ██████╔╝███████║
██║     ██╔══██║██║██║╚██╔╝██║██╔══╝  ██╔══██╗██╔══██║
╚██████╗██║  ██║██║██║ ╚═╝ ██║███████╗██║  ██║██║  ██║
 ╚═════╝╚═╝  ╚═╝╚═╝╚═╝     ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
```

## Implementation

### `shell.c`

- Add `static const char SHELL_BANNER[]` holding the 6 lines above joined by
  `\n` (no trailing blank row).
- In `shell_task()`, change the existing one-time startup print:

  ```c
  shell_print("\n" SHELL_PROMPT);
  ```

  to:

  ```c
  shell_print(SHELL_BANNER);
  shell_print("\n" SHELL_PROMPT);
  ```

  This prints the banner exactly once, before the shell's main read loop
  begins and before the first prompt.

### UTF-8 over UART

`shell_print()` translates each `\n` (`0x0A`) byte to `\r\n` and otherwise
passes bytes through unchanged via `uart_putc()`. UTF-8 continuation bytes
for box-drawing characters (e.g. `0xE2 0x96 0x88` for `█`) never collide with
`0x0A`, so the multi-byte sequences pass through untouched. The receiving
terminal (tmux pane / serial console) must be UTF-8-aware to render the
glyphs correctly — true for the project's existing tmux-based showcase setup,
so no fallback is needed.

`shell.c` is saved as UTF-8 (GCC's default source encoding), so the string
literal's bytes match the banner above exactly. Adds ~830 bytes to
`.rodata` — negligible for the R52 firmware's flash budget.

## Documentation

Add one sentence to the README's **Interactive Shell** section noting that
the shell prints a "CHIMERA" startup banner before the first prompt.

## Testing

1. `make freertos-r52-demo.elf` builds cleanly with the new constant.
2. Launch the showcase, attach to the FreeRTOS tmux pane
   (`freertos-showcase:0.5`), `tmux capture-pane` and confirm the banner
   renders correctly (box-drawing glyphs, not mojibake) before the first
   `chimera> ` prompt.
3. Confirm the banner prints exactly once (not on every command / reconnect —
   there's no reconnect concept here, just startup).
4. Existing shell commands (`help`, `stats`, etc.) continue to work
   unaffected.
