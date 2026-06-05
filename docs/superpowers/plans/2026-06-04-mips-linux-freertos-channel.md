# MIPS-Linux FreeRTOS Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third ivshmem channel pairing a MIPS-Linux guest with the existing FreeRTOS firmware, displayed in the bottom-right tmux pane, with a `run-chimera.sh` launch script.

**Architecture:** A third `ivshmem-flat` device (IVSHMEM2 at 0x3A/3B000000) is added to the `chimera-riscv-freertos-demo` QEMU machine, wired to a new ivshmem server for the MIPS↔FreeRTOS channel. FreeRTOS firmware gains a third polling link. A new MIPS-Linux guest (Alpine 3.10 mips, Malta machine) runs `hello-mips-linux` built with `mips-linux-gnu-gcc`.

**Tech Stack:** QEMU (`qemu-system-mips` Malta), Alpine Linux 3.10.0 mips ISO, `mips-linux-gnu-gcc`, FreeRTOS `freertos_ivshmem_flat` link abstraction, tmux 3.4+.

> **MIPS OS note:** Alpine dropped 32-bit MIPS after v3.12. This plan uses Alpine 3.10.0-mips (`vmlinuz-vanilla`), which is still accessible from the Alpine CDN. If unavailable, substitute any kernel+initrd for QEMU Malta (e.g. Debian mips Malta packages). The kernel filename in `prepare-mips-boot-assets.sh` may need adjustment to match the ISO's `boot/` directory.

---

## File Map

| Action | Path | Responsibility |
|--------|------|----------------|
| Modify | `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h` | Add `HSOC_SENDER_MIPS_LINUX = 4` |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/Makefile` | `hello-mips-linux` target |
| Modify | `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c` | Third ivshmem link (mips) |
| Modify | `include/hw/riscv/chimera_freertos_demo.h` | IVSHMEM2 memmap entries, IRQ 18, `ivshmem_mips_freertos` prop |
| Modify | `hw/riscv/chimera_freertos_demo.c` | Getter/setter, connect IVSHMEM2 |
| Modify | `scripts/heterogeneous-soc/common.sh` | MIPS vars (ISO, kernel, sockets) |
| Modify | `scripts/heterogeneous-soc/install-lima-guest.sh` | Add `gcc-mips-linux-gnu` |
| Modify | `scripts/heterogeneous-soc/fetch-images.sh` | Fetch Alpine mips ISO |
| Modify | `scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh` | Add `ivshmem-mips-freertos` chardev |
| Modify | `scripts/heterogeneous-soc/prepare-demo-guest-overlays.sh` | Conditionally build MIPS overlay |
| Modify | `scripts/heterogeneous-soc/run-phase5-tmux.sh` | 7-pane layout + MIPS server/guest |
| Modify | `scripts/heterogeneous-soc/run-freertos-harness.sh` | Add MIPS server + guest pane |
| Create | `scripts/heterogeneous-soc/start-ivshmem-server-mips-freertos.sh` | MIPS ivshmem server |
| Create | `scripts/heterogeneous-soc/prepare-mips-boot-assets.sh` | Extract kernel/initramfs from MIPS ISO |
| Create | `scripts/heterogeneous-soc/run-chimera.sh` | MIPS-Linux QEMU launcher |

---

## Task 1: Add MIPS Sender ID to Protocol Header

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/hello_proto.h:15-19`

- [ ] **Step 1: Edit hello_proto.h — add MIPS sender ID**

```c
enum hsoc_sender_id {
    HSOC_SENDER_ARM_LINUX = 1,
    HSOC_SENDER_RISCV_LINUX = 2,
    HSOC_SENDER_RISCV_FREERTOS = 3,
    HSOC_SENDER_MIPS_LINUX = 4,
};
```

- [ ] **Step 2: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/hello_proto.h
git commit -m "proto: add HSOC_SENDER_MIPS_LINUX sender ID"
```

---

## Task 2: Add `hello-mips-linux` Build Target

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/Makefile`

- [ ] **Step 1: Edit Makefile — add CC_MIPS and hello-mips-linux target**

In the `CC_ARM`/`CC_RISCV` block, add after `CC_RISCV`:

```makefile
CC_MIPS ?= mips-linux-gnu-gcc
```

In the `HAVE_CC_*` block, add:

```makefile
HAVE_CC_MIPS  := $(shell command -v $(CC_MIPS) 2>/dev/null)
```

In `HELLO_TARGETS :=` block, add:

```makefile
ifneq ($(HAVE_CC_MIPS),)
HELLO_TARGETS += hello-mips-linux
endif
```

After the `all` target's `ifeq` warning blocks, add:

```makefile
ifeq ($(HAVE_CC_MIPS),)
	$(warning CC_MIPS=$(CC_MIPS) not found — hello-mips-linux skipped)
endif
```

After the `hello-riscv-linux` rule, add:

```makefile
hello-mips-linux: linux_hello.c hello_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"mips-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_MIPS_LINUX \
	  -o $@ linux_hello.c
```

Also extend `clean`:

```makefile
clean:
	rm -f $(HELLO_TARGETS) freertos-riscv-demo.elf
```

(No change needed — `$(HELLO_TARGETS)` already includes `hello-mips-linux` when the compiler is available.)

- [ ] **Step 2: Verify build works (if `mips-linux-gnu-gcc` present)**

```bash
command -v mips-linux-gnu-gcc && \
    make -C contrib/heterogeneous-soc/freertos-showcase/ hello-mips-linux && \
    file contrib/heterogeneous-soc/freertos-showcase/hello-mips-linux
```

Expected if compiler present: `ELF 32-bit MSB executable, MIPS`
Expected if compiler absent: `make: Nothing to be done` (skipped gracefully)

- [ ] **Step 3: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/Makefile
git commit -m "build: add hello-mips-linux target (mips-linux-gnu-gcc)"
```

---

## Task 3: Add MIPS Variables to common.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh`

- [ ] **Step 1: Edit common.sh — add MIPS environment variables**

After the `RISCV_KERNEL_CMDLINE` line (line 58), add:

```bash
MIPS_ISO="${MIPS_ISO:-${ASSET_DIR}/alpine-standard-3.10.0-mips.iso}"
MIPS_BOOT_ASSET_DIR="${MIPS_BOOT_ASSET_DIR:-${ASSET_DIR}/mips-boot}"
MIPS_KERNEL_IMAGE="${MIPS_KERNEL_IMAGE:-${MIPS_BOOT_ASSET_DIR}/vmlinuz-vanilla}"
MIPS_INITRAMFS_IMAGE="${MIPS_INITRAMFS_IMAGE:-${MIPS_BOOT_ASSET_DIR}/initramfs-vanilla}"
MIPS_INITRAMFS_OVERLAY="${MIPS_INITRAMFS_OVERLAY:-${MIPS_BOOT_ASSET_DIR}/initramfs-overlay.cpio.gz}"
MIPS_INITRAMFS_COMBINED="${MIPS_INITRAMFS_COMBINED:-${MIPS_BOOT_ASSET_DIR}/initramfs-vanilla-with-overlay}"
MIPS_KERNEL_CMDLINE="${MIPS_KERNEL_CMDLINE:-modules=loop,squashfs,sd-mod,usb-storage,9p,9pnet,9pnet_virtio console=ttyS0}"
```

After `RISCV_SSH_PORT` (line 62), add:

```bash
MIPS_SSH_PORT="${MIPS_SSH_PORT:-2224}"
```

After `IVSHMEM_RISCV_FREERTOS_SOCKET` (line 77), add:

```bash
IVSHMEM_MIPS_FREERTOS_DIR="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}"
IVSHMEM_MIPS_FREERTOS_SOCKET="${IVSHMEM_MIPS_FREERTOS_SOCKET:-${IVSHMEM_MIPS_FREERTOS_DIR}/sock}"
```

After `HELLO_RISCV_BINARY` (line 82), add:

```bash
HELLO_MIPS_BINARY="${HELLO_MIPS_BINARY:-${FREERTOS_SHOWCASE_DIR}/hello-mips-linux}"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/common.sh
git commit -m "env: add MIPS guest variables to common.sh"
```

---

## Task 4: Extend QEMU Machine Header for Third ivshmem

**Files:**
- Modify: `include/hw/riscv/chimera_freertos_demo.h`

- [ ] **Step 1: Edit chimera_freertos_demo.h**

Add `CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS` after the existing prop macros:

```c
#define CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS "ivshmem-mips-freertos"
```

Add to the `MemMapEntry` enum (after `CHIMERA_FREERTOS_IVSHMEM1_SHMEM`):

```c
    CHIMERA_FREERTOS_IVSHMEM2_MMIO,
    CHIMERA_FREERTOS_IVSHMEM2_SHMEM,
```

Add to the IRQ enum (after `CHIMERA_FREERTOS_IVSHMEM1_IRQ`):

```c
    CHIMERA_FREERTOS_IVSHMEM2_IRQ = 18,
```

Add `ivshmem_mips_freertos` to `ChimeraFreeRTOSMachineState` (after `ivshmem_riscv_freertos`):

```c
    char *ivshmem_mips_freertos;
```

- [ ] **Step 2: Commit**

```bash
git add include/hw/riscv/chimera_freertos_demo.h
git commit -m "hw/riscv: add IVSHMEM2 memmap entries, IRQ 18, and MIPS prop to chimera machine"
```

---

## Task 5: Add Third ivshmem Device to QEMU Machine Implementation

**Files:**
- Modify: `hw/riscv/chimera_freertos_demo.c`

- [ ] **Step 1: Add memmap entries for IVSHMEM2**

In `chimera_freertos_memmap[]`, after the `IVSHMEM1_SHMEM` entry, add:

```c
    [CHIMERA_FREERTOS_IVSHMEM2_MMIO] =  { 0x3A000000, 0x00001000 },
    [CHIMERA_FREERTOS_IVSHMEM2_SHMEM] = { 0x3B000000,
                                          CHIMERA_FREERTOS_IVSHMEM_SIZE },
```

- [ ] **Step 2: Add getter/setter for MIPS property**

After `chimera_freertos_set_ivshmem_riscv`, add:

```c
static char *chimera_freertos_get_ivshmem_mips(Object *obj, Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    return g_strdup(s->ivshmem_mips_freertos);
}

static void chimera_freertos_set_ivshmem_mips(Object *obj, const char *value,
                                              Error **errp)
{
    ChimeraFreeRTOSMachineState *s = CHIMERA_FREERTOS_MACHINE(obj);

    g_free(s->ivshmem_mips_freertos);
    s->ivshmem_mips_freertos = g_strdup(value);
}
```

- [ ] **Step 3: Require and connect MIPS chardev in machine init**

In `chimera_freertos_machine_init`, add `mips_chr` to local vars:

```c
    Chardev *mips_chr = NULL;
```

Add MIPS chardev requirement after the riscv one:

```c
    have_links &= chimera_freertos_require_chardev(s->ivshmem_mips_freertos,
                                                   CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS,
                                                   &mips_chr);
```

After `chimera_freertos_connect_ivshmem(... IVSHMEM1 ...)`, add:

```c
    chimera_freertos_connect_ivshmem(
        plic, mips_chr,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM2_MMIO].base,
        chimera_freertos_memmap[CHIMERA_FREERTOS_IVSHMEM2_SHMEM].base,
        CHIMERA_FREERTOS_IVSHMEM2_IRQ);
```

- [ ] **Step 4: Register MIPS property in class init**

In `chimera_freertos_machine_class_init`, after the RISCV property block, add:

```c
    object_class_property_add_str(oc, CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS,
                                  chimera_freertos_get_ivshmem_mips,
                                  chimera_freertos_set_ivshmem_mips);
    object_class_property_set_description(
        oc, CHIMERA_FREERTOS_PROP_IVSHMEM_MIPS,
        "Chardev id for the MIPS/Linux <-> FreeRTOS ivshmem link");
```

- [ ] **Step 5: Commit**

```bash
git add hw/riscv/chimera_freertos_demo.c
git commit -m "hw/riscv: add third ivshmem channel (MIPS) to chimera FreeRTOS machine"
```

---

## Task 6: Add MIPS ivshmem Link to FreeRTOS Firmware

**Files:**
- Modify: `contrib/heterogeneous-soc/freertos-showcase/freertos_main.c`

- [ ] **Step 1: Edit freertos_main.c — add mips_link**

After `static struct freertos_ivshmem_link riscv_link;`, add:

```c
static struct freertos_ivshmem_link mips_link;
```

- [ ] **Step 2: Add IVSHMEM2 address constants**

After `#define IVSHMEM1_SHMEM 0x36000000UL`, add:

```c
#define IVSHMEM2_MMIO  0x3A000000UL
#define IVSHMEM2_SHMEM 0x3B000000UL
```

- [ ] **Step 3: Init mips_link in showcase_task**

After `freertos_ivshmem_init(&riscv_link, IVSHMEM1_MMIO, IVSHMEM1_SHMEM, "riscv-linux");`, add:

```c
    freertos_ivshmem_init(&mips_link, IVSHMEM2_MMIO, IVSHMEM2_SHMEM,
                          "mips-linux");
```

- [ ] **Step 4: Poll mips_link in the main loop**

After `maybe_service_link(&riscv_link, "[freertos] received hello from riscv-linux\n");`, add:

```c
        maybe_service_link(&mips_link,
                           "[freertos] received hello from mips-linux\n");
```

- [ ] **Step 5: Add mips diagnostics to diag block**

In the `diag_count >= 3000` block, after the riscv diag lines, add:

```c
            log_uart(" mips_flag=");
            diag_print_hex32(mips_link.layout->linux_to_freertos.flag);
            log_uart(" mips_magic=");
            diag_print_hex32(mips_link.layout->linux_to_freertos.msg.magic);
```

- [ ] **Step 6: Commit**

```bash
git add contrib/heterogeneous-soc/freertos-showcase/freertos_main.c
git commit -m "freertos: add third ivshmem link (mips-linux) to showcase task"
```

---

## Task 7: Add MIPS ivshmem Server Script

**Files:**
- Create: `scripts/heterogeneous-soc/start-ivshmem-server-mips-freertos.sh`

- [ ] **Step 1: Create the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${IVSHMEM_MIPS_FREERTOS_DIR}"

if [[ -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}" ]] &&
   ss -xl | grep -Fq "${IVSHMEM_MIPS_FREERTOS_SOCKET}"; then
    echo "ivshmem-server already listening on ${IVSHMEM_MIPS_FREERTOS_SOCKET}"
    exit 0
fi

rm -f "${IVSHMEM_MIPS_FREERTOS_SOCKET}"
exec "$(find_ivshmem_server)" \
    -F \
    -M mips-freertos \
    -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -l "${IVSHMEM_SIZE}" \
    -n "${IVSHMEM_VECTORS}" \
    -v
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x scripts/heterogeneous-soc/start-ivshmem-server-mips-freertos.sh
git add scripts/heterogeneous-soc/start-ivshmem-server-mips-freertos.sh
git commit -m "scripts: add start-ivshmem-server-mips-freertos.sh"
```

---

## Task 8: Add MIPS Boot Assets Prep Script

**Files:**
- Create: `scripts/heterogeneous-soc/prepare-mips-boot-assets.sh`
- Modify: `scripts/heterogeneous-soc/fetch-images.sh`
- Modify: `scripts/heterogeneous-soc/install-lima-guest.sh`

- [ ] **Step 1: Create prepare-mips-boot-assets.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

require_file "${MIPS_ISO}" "MIPS installer ISO"

mkdir -p "${MIPS_BOOT_ASSET_DIR}"

# Alpine 3.10 mips standard ISO has vmlinuz-vanilla and initramfs-vanilla.
# If the filenames differ in the ISO, set MIPS_KERNEL_BASENAME and
# MIPS_INITRAMFS_BASENAME in the environment before calling this script.
KERNEL_BASENAME="${MIPS_KERNEL_BASENAME:-vmlinuz-vanilla}"
INITRAMFS_BASENAME="${MIPS_INITRAMFS_BASENAME:-initramfs-vanilla}"

bsdtar -xOf "${MIPS_ISO}" "boot/${KERNEL_BASENAME}"     > "${MIPS_KERNEL_IMAGE}"
bsdtar -xOf "${MIPS_ISO}" "boot/${INITRAMFS_BASENAME}"  > "${MIPS_INITRAMFS_IMAGE}"

echo "MIPS_KERNEL_IMAGE=${MIPS_KERNEL_IMAGE}"
echo "MIPS_INITRAMFS_IMAGE=${MIPS_INITRAMFS_IMAGE}"
```

- [ ] **Step 2: Add Alpine mips ISO download to fetch-images.sh**

After the RISCV uboot archive wget line, add:

```bash
[[ -f "${MIPS_ISO}" ]] || wget -O "${MIPS_ISO}" https://dl-cdn.alpinelinux.org/alpine/v3.10/releases/mips/alpine-standard-3.10.0-mips.iso
```

- [ ] **Step 3: Add mips cross-compiler to install-lima-guest.sh**

In the `apt-get install` list, add after `gcc-riscv64-linux-gnu`:

```bash
    gcc-mips-linux-gnu \
```

- [ ] **Step 4: Make executable and commit**

```bash
chmod +x scripts/heterogeneous-soc/prepare-mips-boot-assets.sh
git add scripts/heterogeneous-soc/prepare-mips-boot-assets.sh \
        scripts/heterogeneous-soc/fetch-images.sh \
        scripts/heterogeneous-soc/install-lima-guest.sh
git commit -m "scripts: add MIPS boot asset prep, ISO fetch, and cross-compiler install"
```

---

## Task 9: Update Guest Overlay Builder for MIPS

**Files:**
- Modify: `scripts/heterogeneous-soc/prepare-demo-guest-overlays.sh`

- [ ] **Step 1: Add MIPS overlay to prepare-demo-guest-overlays.sh**

At the end of the file, after the RISCV `build_overlay_archive` call, add:

```bash
if [[ -f "${MIPS_INITRAMFS_IMAGE}" ]]; then
    mkdir -p "${MIPS_BOOT_ASSET_DIR}"
    build_overlay_archive "ttyS0" "${MIPS_INITRAMFS_OVERLAY}" "${MIPS_INITRAMFS_IMAGE}" \
        "${MIPS_INITRAMFS_COMBINED}" "/mnt/pingpong/freertos-showcase/hello-mips-linux"
    echo "MIPS_INITRAMFS_COMBINED=${MIPS_INITRAMFS_COMBINED}"
fi
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/prepare-demo-guest-overlays.sh
git commit -m "scripts: build MIPS initramfs overlay when MIPS assets are available"
```

---

## Task 10: Create `run-chimera.sh` — MIPS Linux QEMU Launcher

**Files:**
- Create: `scripts/heterogeneous-soc/run-chimera.sh`

- [ ] **Step 1: Create run-chimera.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-mips)"

require_file "${MIPS_ISO}" "MIPS installer ISO"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/prepare-mips-boot-assets.sh"
bash "${SCRIPT_DIR}/prepare-demo-guest-overlays.sh"

require_file "${MIPS_KERNEL_IMAGE}"     "MIPS kernel image"
require_file "${MIPS_INITRAMFS_COMBINED}" "MIPS combined initramfs image"

exec "${qemu_bin}" \
    -machine malta \
    -cpu MIPS32R2-generic \
    -m 256M \
    -kernel "${MIPS_KERNEL_IMAGE}" \
    -initrd "${MIPS_INITRAMFS_COMBINED}" \
    -append "${MIPS_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

- [ ] **Step 2: Make executable and commit**

```bash
chmod +x scripts/heterogeneous-soc/run-chimera.sh
git add scripts/heterogeneous-soc/run-chimera.sh
git commit -m "scripts: add run-chimera.sh MIPS-Linux QEMU launcher (Malta machine)"
```

---

## Task 11: Update FreeRTOS QEMU Launch Script for Third Chardev

**Files:**
- Modify: `scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh`

- [ ] **Step 1: Add MIPS chardev to FreeRTOS QEMU command**

Replace the `-machine` line and its chardev lines:

```bash
exec "${qemu_bin}" \
    -machine chimera-riscv-freertos-demo,ivshmem-arm-freertos=armft,ivshmem-riscv-freertos=riscvft,ivshmem-mips-freertos=mipsft \
    -chardev socket,id=armft,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -chardev socket,id=riscvft,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -chardev socket,id=mipsft,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -bios "${FREERTOS_DEMO_ELF}" \
    -monitor unix:/tmp/freertos-monitor.sock,server,nowait \
    -nographic
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh
git commit -m "scripts: add ivshmem-mips-freertos chardev to FreeRTOS QEMU launch"
```

---

## Task 12: Update tmux Orchestrator — 7-Pane Layout

**Files:**
- Modify: `scripts/heterogeneous-soc/run-phase5-tmux.sh`

The new layout adds a third server pane (top-right) and a third guest pane (bottom-right):

```
┌──────────────┬──────────────┬──────────────┐
│  srv ARM-FT  │  srv RISCV-FT│  srv MIPS-FT │  panes 0, 1, 2
├──────────────┴──────────────┴──────────────┤
│                  FreeRTOS                   │  pane 3
├──────────────┬──────────────┬──────────────┤
│  ARM-Linux   │  RISCV-Linux │  MIPS-Linux  │  panes 4, 5, 6
└──────────────┴──────────────┴──────────────┘
```

- [ ] **Step 1: Update layout comment and split commands**

Replace the layout comment block and all `tmux split-window`/`tmux send-keys`/`pkill` lines with the following. This completely replaces the body of `run-phase5-tmux.sh` after the build step.

```bash
# Build a single-window layout:
#
#  ┌──────────────┬──────────────┬──────────────┐
#  │  srv ARM-FT  │  srv RISCV-FT│  srv MIPS-FT │  panes 0, 1, 2
#  ├──────────────┴──────────────┴──────────────┤
#  │                  FreeRTOS                   │  pane 3
#  ├──────────────┬──────────────┬──────────────┤
#  │  ARM-Linux   │  RISCV-Linux │  MIPS-Linux  │  panes 4, 5, 6
#  └──────────────┴──────────────┴──────────────┘
#
# Split sequence:
#   new-session → pane 0 (full)
#   split-v 80% → pane 0=top(20%), pane 1=rest(80%)
#   split-v 45% on 1 → pane 1=middle, pane 2=bottom
#   split-h on 0 → 0=top-left, 1=top-right, 2=middle, 3=bottom
#   split-h on 3 → 0=tl, 1=tr, 2=middle, 3=bottom-left, 4=bottom-right
#   split-h on 1 → 0=tl, 1=top-mid, 2=top-right(mips-srv), 3=mid, 4=bl, 5=br
#   split-h on 5 → 0=tl, 1=tm, 2=tr, 3=mid, 4=bl, 5=bm, 6=br(mips-guest)

tmux new-session -d -s "$SESSION" -x "${COLUMNS:-220}" -y "${LINES:-55}"

tmux split-window -v -t "$SESSION:0.0" -l 80%
tmux split-window -v -t "$SESSION:0.1" -l 45%
tmux split-window -h -t "$SESSION:0.0"
tmux split-window -h -t "$SESSION:0.3"
tmux split-window -h -t "$SESSION:0.1"
tmux split-window -h -t "$SESSION:0.5"

# Kill any stale QEMU processes that outlived a previous session.
pkill -f "qemu-system-riscv64.*freertos-riscv-demo" 2>/dev/null || true
pkill -f "qemu-system-riscv64.*riscv-phase5"        2>/dev/null || true
pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
pkill -f "qemu-system-mips.*run-chimera"             2>/dev/null || true
sleep 0.5

# Start ivshmem servers first; wait for all three sockets before launching guests.
tmux send-keys -t "$SESSION:0.0" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh"   Enter
tmux send-keys -t "$SESSION:0.1" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh" Enter
tmux send-keys -t "$SESSION:0.2" "cd '$REPO' && scripts/heterogeneous-soc/start-ivshmem-server-mips-freertos.sh"  Enter

ARM_SOCK="${IVSHMEM_ARM_FREERTOS_DIR:-/tmp/ivshmem-arm-freertos}/sock"
RISCV_SOCK="${IVSHMEM_RISCV_FREERTOS_DIR:-/tmp/ivshmem-riscv-freertos}/sock"
MIPS_SOCK="${IVSHMEM_MIPS_FREERTOS_DIR:-/tmp/ivshmem-mips-freertos}/sock"
for _i in $(seq 1 60); do
    if [[ -S "$ARM_SOCK"  ]] && ss -xl | grep -Fq "$ARM_SOCK"  && \
       [[ -S "$RISCV_SOCK" ]] && ss -xl | grep -Fq "$RISCV_SOCK" && \
       [[ -S "$MIPS_SOCK"  ]] && ss -xl | grep -Fq "$MIPS_SOCK"; then
        break
    fi
    sleep 0.5
done

tmux send-keys -t "$SESSION:0.3" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-freertos-phase5.sh" Enter
tmux send-keys -t "$SESSION:0.4" "cd '$REPO' && scripts/heterogeneous-soc/run-arm-phase5.sh"            Enter
tmux send-keys -t "$SESSION:0.5" "cd '$REPO' && scripts/heterogeneous-soc/run-riscv-phase5.sh"          Enter
tmux send-keys -t "$SESSION:0.6" "cd '$REPO' && scripts/heterogeneous-soc/run-chimera.sh"               Enter

auto_login_and_run() {
    local pane="$1"
    local hello_bin="$2"
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "$pane" 2>/dev/null)"
        if echo "$content" | grep -q "login:"; then
            tmux send-keys -t "$pane" "root" Enter
            sleep 3
            tmux send-keys -t "$pane" "busybox mkdir -p /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        elif echo "$content" | grep -q "~#"; then
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}

auto_login_and_run "$SESSION:0.4" "/mnt/pingpong/freertos-showcase/hello-arm-linux"   &
auto_login_and_run "$SESSION:0.5" "/mnt/pingpong/freertos-showcase/hello-riscv-linux" &
auto_login_and_run "$SESSION:0.6" "/mnt/pingpong/freertos-showcase/hello-mips-linux"  &

# Focus FreeRTOS pane
tmux select-pane -t "$SESSION:0.3"

echo ""
echo "=== Phase 5 showcase starting (session: $SESSION) ==="
echo "    Guests will auto-login and run hello senders once booted."
echo "    Navigate panes: Ctrl-b arrow keys"
echo "    Attaching..."
echo ""

tmux attach-session -t "$SESSION"
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/run-phase5-tmux.sh
git commit -m "scripts: expand tmux layout to 7 panes for MIPS-Linux guest"
```

---

## Task 13: Update Harness for MIPS

**Files:**
- Modify: `scripts/heterogeneous-soc/run-freertos-harness.sh`

- [ ] **Step 1: Add MIPS ivshmem server to cleanup trap**

In the `cleanup()` function, add MIPS entries after the riscv ones:

```bash
    pkill -f "qemu-system-mips.*run-chimera" 2>/dev/null || true
    pkill -f "ivshmem-server.*mips-freertos" 2>/dev/null || true
    rm -f "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true
```

- [ ] **Step 2: Add MIPS pre-run orphan kill**

After the `rm -f ... IVSHMEM_RISCV_FREERTOS_SOCKET` pre-run line, add:

```bash
rm -f "${IVSHMEM_MIPS_FREERTOS_SOCKET}" 2>/dev/null || true
```

- [ ] **Step 3: Update tmux session comment and add 2 extra panes**

Update the pane layout comment:

```bash
#  pane 0: ARM ivshmem server
#  pane 1: RISCV ivshmem server
#  pane 2: MIPS ivshmem server
#  pane 3: FreeRTOS QEMU   ← UART captured to ${FREERTOS_LOG}
#  pane 4: ARM Linux QEMU
#  pane 5: RISCV Linux QEMU
#  pane 6: MIPS Linux QEMU
```

Replace the 4 split commands:

```bash
tmux new-session -d -s "${SESSION}" -x 220 -y 55
tmux split-window -v -t "${SESSION}:0.0" -l 80%
tmux split-window -v -t "${SESSION}:0.1" -l 45%
tmux split-window -h -t "${SESSION}:0.0"
tmux split-window -h -t "${SESSION}:0.3"
tmux split-window -h -t "${SESSION}:0.1"
tmux split-window -h -t "${SESSION}:0.5"
```

- [ ] **Step 4: Start MIPS ivshmem server in pane 2**

After the RISCV server send-keys, add:

```bash
tmux send-keys -t "${SESSION}:0.2" \
    "\"${IVSHMEM_BIN}\" -F -S \"${IVSHMEM_MIPS_FREERTOS_SOCKET}\" -l ${IVSHMEM_SIZE} -n ${IVSHMEM_VECTORS}" Enter
```

- [ ] **Step 5: Add MIPS socket to the socket-ready poll**

Add `IVSHMEM_MIPS_FREERTOS_SOCKET` to the `for _i in` loop condition:

```bash
for _i in $(seq 1 60); do
    if [[ -S "${IVSHMEM_ARM_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_ARM_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_RISCV_FREERTOS_SOCKET}" ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_RISCV_FREERTOS_SOCKET}" && \
       [[ -S "${IVSHMEM_MIPS_FREERTOS_SOCKET}"  ]] && \
       ss -xl 2>/dev/null | grep -Fq "${IVSHMEM_MIPS_FREERTOS_SOCKET}"; then
        break
    fi
    sleep 0.5
done
```

- [ ] **Step 6: Launch MIPS Linux guest in pane 6**

After the RISCV `run-riscv-phase5.sh` send-keys, add:

```bash
tmux send-keys -t "${SESSION}:0.6" \
    "${PANE_ENV} exec '${CHIMERA_ROOT}/scripts/heterogeneous-soc/run-chimera.sh'" Enter
```

- [ ] **Step 7: Add MIPS auto_login_and_run**

After the RISCV `auto_login_and_run` line, add:

```bash
auto_login_and_run "${SESSION}:0.6" "/mnt/pingpong/freertos-showcase/hello-mips-linux" &
```

- [ ] **Step 8: Commit**

```bash
git add scripts/heterogeneous-soc/run-freertos-harness.sh
git commit -m "harness: add MIPS ivshmem server and MIPS Linux guest pane"
```

---

## Task 14: Build and Smoke Test (Lima VM)

> Run the following inside the Lima VM (`limactl shell qemu-dev`) after installing the mips cross-compiler (`sudo apt-get install gcc-mips-linux-gnu`).

- [ ] **Step 1: Install MIPS cross-compiler in Lima**

```bash
limactl shell qemu-dev -- sudo apt-get install -y gcc-mips-linux-gnu
```

Expected: installs `mips-linux-gnu-gcc`.

- [ ] **Step 2: Rebuild FreeRTOS and hello binaries**

```bash
limactl shell qemu-dev -- bash -c "cd ~/chimera-src && make -C contrib/heterogeneous-soc/freertos-showcase/ clean all"
```

Expected output includes: `hello-mips-linux` built, `freertos-riscv-demo.elf` built.

Verify ELF types:
```bash
limactl shell qemu-dev -- file ~/chimera-src/contrib/heterogeneous-soc/freertos-showcase/hello-mips-linux
```

Expected: `ELF 32-bit MSB executable, MIPS, MIPS32 rel2 version 1 (SYSV), statically linked`

- [ ] **Step 3: Rebuild QEMU (needed for new IVSHMEM2 machine property)**

```bash
BUILD_DIR=$HOME/chimera-build-linux VM_SOURCE_DIR=$HOME/chimera-src \
    limactl shell qemu-dev -- bash -c "cd \$HOME/chimera-build-linux && ninja qemu-system-riscv64"
```

Expected: compiles `hw/riscv/chimera_freertos_demo.c` without errors.

- [ ] **Step 4: Fetch MIPS ISO**

```bash
bash scripts/heterogeneous-soc/fetch-images.sh
```

Expected: downloads `alpine-standard-3.10.0-mips.iso` to `~/iso/`.

> If the download fails, check the URL. Inspect the ISO's boot directory with:
> ```bash
> bsdtar -tf ~/iso/alpine-standard-3.10.0-mips.iso | grep '^boot/'
> ```
> Update `MIPS_KERNEL_BASENAME` and `MIPS_INITRAMFS_BASENAME` in `common.sh` if the filenames differ.

- [ ] **Step 5: Verify MIPS boot assets prep**

```bash
bash scripts/heterogeneous-soc/prepare-mips-boot-assets.sh
```

Expected:
```
MIPS_KERNEL_IMAGE=/Users/yhsung/iso/mips-boot/vmlinuz-vanilla
MIPS_INITRAMFS_IMAGE=/Users/yhsung/iso/mips-boot/initramfs-vanilla
```

- [ ] **Step 6: Smoke test MIPS QEMU boots (headless 30s)**

```bash
timeout 30 qemu-system-mips \
    -machine malta -cpu MIPS32R2-generic -m 256M \
    -kernel ~/iso/mips-boot/vmlinuz-vanilla \
    -initrd ~/iso/mips-boot/initramfs-vanilla \
    -append "console=ttyS0" \
    -nographic 2>&1 | head -30
```

Expected: Linux kernel boot messages on `ttyS0`. If no output, try `-cpu 24Kf` or check kernel console parameter.

- [ ] **Step 7: Run full showcase**

```bash
bash scripts/heterogeneous-soc/run-phase5-tmux.sh
```

Expected: 7-pane tmux session appears. FreeRTOS pane eventually shows:
```
[freertos] received hello from arm-linux
[freertos] received hello from riscv-linux
[freertos] received hello from mips-linux
```

- [ ] **Step 8: Commit any fixups found during testing**

```bash
git add -p
git commit -m "fix: adjust MIPS boot params / kernel filename from smoke test"
```

---

## Self-Review

**Spec coverage check:**
- ✅ MIPS-Linux sends hello to FreeRTOS (Tasks 1, 2, 6)
- ✅ FreeRTOS services MIPS channel and prints received message (Task 6)
- ✅ MIPS shown in bottom-right tmux pane (pane 6, Task 12)
- ✅ `run-chimera.sh` added, similar structure to `run-riscv-phase5.sh` (Task 10)
- ✅ Third ivshmem channel wired through QEMU machine (Tasks 4, 5, 11)
- ✅ Harness updated to cover MIPS (Task 13)

**Backward compatibility:**
- `prepare-demo-guest-overlays.sh` MIPS block is guarded by `if [[ -f "${MIPS_INITRAMFS_IMAGE}" ]]` so existing ARM/RISCV-only runs are unaffected.
- The FreeRTOS machine now requires the third chardev; `run-riscv-freertos-phase5.sh` and the harness are both updated to supply it.

**Known risk:** Alpine 3.10 mips ISO kernel filename may not be `vmlinuz-vanilla`. Task 14 Step 4 includes a bsdtar inspection command to discover the actual names if the defaults fail.
