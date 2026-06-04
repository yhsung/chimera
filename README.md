# Chimera — Heterogeneous SoC Demo

A QEMU-based demo of a heterogeneous SoC: ARM-Linux, RISCV-Linux, and MIPS-Linux guests each exchange timestamped HELLO/ACK messages with a bare-metal RISCV FreeRTOS firmware over three independent ivshmem (inter-VM shared memory) channels.

---

## Architecture

```
 ┌─────────────────────────┐      ivshmem-arm-freertos      ┌──────────────────────────────────┐
 │  ARM-Linux (aarch64)    │ ◄────────────────────────────► │                                  │
 │  Debian Linux            │  /tmp/ivshmem-arm-freertos/    │  RISCV FreeRTOS (bare-metal)     │
 │  QEMU virt (gic-version=3)│  IVSHMEM0_SHMEM=0x31000000   │  QEMU chimera-riscv-freertos-demo│
 └─────────────────────────┘                                 │                                  │
                                                             │  Polls all three channels every  │
 ┌─────────────────────────┐      ivshmem-riscv-freertos    │  1 ms; sends ACK with FreeRTOS   │
 │  RISCV-Linux (rv64)     │ ◄────────────────────────────► │  tick timestamp                  │
 │  Debian Linux            │  /tmp/ivshmem-riscv-freertos/  │                                  │
 │  QEMU virt (OpenSBI)    │  IVSHMEM1_SHMEM=0x36000000    │                                  │
 └─────────────────────────┘                                 │                                  │
                                                             │                                  │
 ┌─────────────────────────┐      ivshmem-mips-freertos     │                                  │
 │  MIPS-Linux (mips32)    │ ◄────────────────────────────► │                                  │
 │  Debian Linux 12        │  /tmp/ivshmem-mips-freertos/   │                                  │
 │  QEMU malta             │  IVSHMEM2_SHMEM=0x3B000000    └──────────────────────────────────┘
 └─────────────────────────┘
```

### Components

| Component | Machine | OS | Role |
|---|---|---|---|
| ARM-Linux | QEMU `virt` aarch64, Cortex-A57 | Debian Linux 12 (bookworm) | Sends HELLO, waits for ACK |
| RISCV-Linux | QEMU `virt` rv64, OpenSBI | Debian Linux 12 (bookworm) | Sends HELLO, waits for ACK |
| MIPS-Linux | QEMU `malta` mips32 | Debian Linux 12 (bookworm) | Sends HELLO, waits for ACK |
| RISCV FreeRTOS | QEMU `chimera-riscv-freertos-demo` | Bare-metal FreeRTOS | Receives HELLO from all three, sends ACK |
| ivshmem-server (ARM) | Host process | — | Brokers shared memory for ARM↔FreeRTOS |
| ivshmem-server (RISCV) | Host process | — | Brokers shared memory for RISCV↔FreeRTOS |
| ivshmem-server (MIPS) | Host process | — | Brokers shared memory for MIPS↔FreeRTOS |

### ivshmem Device Types

- **Linux guests** use `ivshmem-doorbell` (PCI device, BAR2 = 64 MiB shared memory window)
- **FreeRTOS** uses `ivshmem-flat` (custom sysbus device, memory-mapped at fixed addresses)

The custom QEMU machine (`hw/riscv/chimera_freertos_demo.c`) connects FreeRTOS to all three ivshmem servers simultaneously:

| Link | MMIO base | SHMEM base |
|---|---|---|
| ARM ↔ FreeRTOS | `0x30000000` | `0x31000000` |
| RISCV ↔ FreeRTOS | `0x35000000` | `0x36000000` |
| MIPS ↔ FreeRTOS | `0x3A000000` | `0x3B000000` |

---

## Wire Protocol

Defined in `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h`.

### Message layout (`struct hsoc_hello_msg`, 96 bytes)

| Field | Type | Description |
|---|---|---|
| `magic` | `uint32_t` | `0x48454c4f` ("HELO") |
| `version` | `uint16_t` | Protocol version (1) |
| `msg_type` | `uint16_t` | `HSOC_MSG_HELLO` (1) or `HSOC_MSG_ACK` (2) |
| `seq` | `uint32_t` | Sequence number |
| `sender_id` | `uint32_t` | `ARM_LINUX`=1, `RISCV_LINUX`=2, `RISCV_FREERTOS`=3, `MIPS_LINUX`=4 |
| `ts_sec` | `int64_t` | Send timestamp — seconds |
| `ts_nsec` | `int64_t` | Send timestamp — nanoseconds |
| `text` | `char[64]` | Human-readable label |

### Shared memory layout (`struct hsoc_layout`)

```
Offset 0x0000  struct hsoc_channel  linux_to_freertos   (flag + msg)
               ... pad to 0x1000 ...
Offset 0x1000  struct hsoc_channel  freertos_to_linux   (flag + msg)
```

Each `hsoc_channel` holds a `volatile uint32_t flag` (0 = empty, 1 = ready) followed by an `hsoc_hello_msg`.

### Handshake sequence

```mermaid
sequenceDiagram
    participant L as Linux
    participant S as Shared Memory (BAR2)
    participant F as FreeRTOS

    L->>S: shm_write(msg)
    Note over L: __sync_synchronize()
    L->>S: flag = 1
    S-->>F: poll detects flag == 1
    Note over F: __sync_synchronize()
    F->>S: shmem_read(msg)
    F->>S: flag = 0
    Note over F: __sync_synchronize()
    F->>S: shmem_write(ack)
    Note over F: __sync_synchronize()
    F->>S: flag = 1
    S-->>L: wait detects flag == 1
    L->>S: shm_read(ack)
    Note over L: __sync_synchronize()
    L->>S: flag = 0
```

---

## Tmux Pane Layout

```
┌──────────────────────┬──────────────────────┬──────────────────────┐
│  ivshmem-server      │  ivshmem-server      │  ivshmem-server      │
│  (ARM ↔ FreeRTOS)   │  (RISCV ↔ FreeRTOS) │  (MIPS ↔ FreeRTOS)  │
│  pane 0              │  pane 1              │  pane 2              │
├──────────────────────┴──────────────────────┴──────────────────────┤
│                                                                      │
│  RISCV FreeRTOS                                                     │
│  (receives HELLO from all three Linux guests, sends ACK)            │
│  pane 3                                                              │
├──────────────────────┬──────────────────────┬──────────────────────┤
│  ARM-Linux           │  RISCV-Linux         │  MIPS-Linux          │
│  hello-arm-linux     │  hello-riscv-linux   │  hello-mips-linux    │
│  pane 4              │  pane 5              │  pane 6              │
└──────────────────────┴──────────────────────┴──────────────────────┘
```

Navigate with **Ctrl-b** + arrow keys. All Linux panes auto-login as `root`, mount the 9p virtfs share, and launch the hello binary once the guest boots.

---

## Running the Demo

### One command (recommended)

```bash
limactl shell qemu-dev -- bash ~/chimera-src/scripts/heterogeneous-soc/run-chimera-showcase.sh
```

`run-chimera-showcase.sh` is the full-stack launcher. It runs 8 stages, each idempotent:

| Stage | What it does | Skip condition |
|---|---|---|
| 1 — apt packages | Installs all build deps including `gcc-mips-linux-gnu` | Already installed |
| 2 — kernel packages | Downloads ARM / RISCV / MIPS Debian kernel .deb packages | File already exists |
| 3 — QEMU build | Builds `qemu-system-riscv64/aarch64` + `ivshmem-server` | Binaries already in `BUILD_DIR` |
| 4 — FreeRTOS kernel | Clones / pulls FreeRTOS-Kernel | Already cloned (pulls latest) |
| 5 — Showcase binaries | Builds ELF + `hello-{arm,riscv,mips}-linux` | Warns if MIPS binary absent |
| 6 — Debian rootfs | Creates minimal Debian qcow2 disks via debootstrap | Skipped if disk exists |
| 7 — boot assets | Extracts kernel + initramfs from Debian kernel .deb packages | Skipped if already extracted |
| 8 — Launch | Opens 7-pane tmux session | — |

**Environment overrides:**

| Variable | Effect |
|---|---|
| `SKIP_PREREQS=1` | Skip stages 1–2 (fast re-run after first setup) |
| `SKIP_BUILD=1` | Skip stages 1–7 (jump straight to tmux launch using cached binaries) |
| `BUILD_DIR` | QEMU build output directory (default: `~/chimera-build-linux`) |
| `ASSET_DIR` | Kernel .deb / disk image cache directory (default: `~/iso`) |

### Manual step-by-step

```bash
# One-time: set up Lima VM (macOS host)
scripts/heterogeneous-soc/install-lima-host.sh

# Inside Lima:
limactl shell qemu-dev

# Install build dependencies (once)
bash ~/chimera-src/scripts/heterogeneous-soc/install-lima-guest.sh

# Fetch Debian kernel packages
bash ~/chimera-src/scripts/heterogeneous-soc/fetch-images.sh

# Build QEMU + ivshmem-server
BUILD_DIR=$HOME/chimera-build-linux VM_SOURCE_DIR=$HOME/chimera-src \
    bash ~/chimera-src/scripts/heterogeneous-soc/build-ivshmem-tools.sh

# Fetch FreeRTOS kernel source
bash ~/chimera-src/scripts/heterogeneous-soc/fetch-freertos-kernel.sh

# Build FreeRTOS showcase binaries
bash ~/chimera-src/scripts/heterogeneous-soc/build-freertos-showcase.sh

# Launch the showcase
CHIMERA_ROOT=~/chimera-src BUILD_DIR=~/chimera-build-linux \
    bash ~/chimera-src/scripts/heterogeneous-soc/run-phase5-tmux.sh
```

### Prerequisites

- macOS host with [Lima](https://lima-vm.io/) (`brew install lima`)
- QEMU built from this tree inside the Lima VM (`qemu-dev`)
- Debian kernel .deb packages for arm64, riscv64, and mips (fetched automatically)

Cross-compilation happens inside the Lima VM, which provides:

| Cross-compiler | Target |
|---|---|
| `aarch64-linux-gnu-gcc` | ARM-Linux hello binary |
| `riscv64-linux-gnu-gcc` | RISCV-Linux hello binary |
| `mips-linux-gnu-gcc` | MIPS-Linux hello binary |
| `riscv64-unknown-elf-gcc` | FreeRTOS bare-metal ELF |

> **MIPS OS note:** Debian dropped big-endian 32-bit MIPS (mips) after Debian 8 (jessie). The demo uses the `4kc-malta` kernel from the Debian 12 `debian-ports` archive. The MIPS rootfs is built via `debootstrap` using the `debian-ports` suite.

---

## Source Layout

```
contrib/heterogeneous-soc/freertos-showcase/
  hello_proto.h               — shared wire protocol (sender IDs, message structs)
  linux_hello.c               — Linux sender (ARM, RISCV, and MIPS, compiled separately)
  freertos_main.c             — FreeRTOS task: polls all three channels, sends ACK
  freertos_ivshmem_flat.c     — ivshmem poll/send helpers (volatile byte access)
  freertos_ivshmem_flat.h
  Makefile

scripts/heterogeneous-soc/
  run-chimera-showcase.sh               — full-stack launcher (prereqs + build + tmux)
  run-phase5-tmux.sh                    — tmux session launcher (7 panes)
  build-freertos-showcase.sh            — builds all binaries via Lima
  fetch-images.sh                       — downloads Debian kernel .deb packages
  install-lima-guest.sh                 — installs apt packages in Lima VM
  start-ivshmem-server-arm-freertos.sh  — starts ARM ivshmem-server
  start-ivshmem-server-riscv-freertos.sh — starts RISCV ivshmem-server
  start-ivshmem-server-mips-freertos.sh — starts MIPS ivshmem-server
  run-arm-phase5.sh                     — launches ARM-Linux QEMU
  run-riscv-phase5.sh                   — launches RISCV-Linux QEMU
  run-chimera.sh                        — launches MIPS-Linux QEMU (Malta machine)
  run-riscv-freertos-phase5.sh          — launches FreeRTOS QEMU
  prepare-debian-rootfs.sh              — creates minimal Debian qcow2 rootfs disks via debootstrap
  prepare-debian-boot-assets.sh         — extracts kernel + initramfs from Debian kernel .deb packages

hw/riscv/chimera_freertos_demo.c  — custom QEMU machine (3 ivshmem channels)
hw/misc/ivshmem-flat.c            — custom ivshmem sysbus device (used by FreeRTOS)
```

---

## Implementation Notes

### Volatile byte helpers

All copies to/from ivshmem use explicit volatile byte loops instead of `memcpy`/struct assignment:

- **ARM-Linux**: ARM `printf`/`memcpy` use NEON instructions, which SIGBUS on non-cacheable PCI BAR2 memory. The `shm_write`/`shm_read` helpers in `linux_hello.c` avoid this.
- **FreeRTOS**: GCC `-O2` loop-invariant code motion (LICM) hoists non-volatile struct reads out of the poll loop, returning stale zeros on every iteration. The `shmem_read`/`shmem_write` helpers in `freertos_ivshmem_flat.c` prevent this.

### Memory barriers

`__sync_synchronize()` is placed around every flag write and read:
- RISCV: emits `fence iorw,iorw`
- AArch64: emits `dmb ish`

This ensures message body writes are globally visible before the flag is set, and that the flag read completes before the message body is read.
