# Heterogeneous SoC Simulation Plan

> **Goal:** Simulate an ARM + RISC-V heterogeneous SoC with security-isolated multi-OS.
> Final deliverable: a userspace `ping` app on ARM sends a message to a `pong` app on
> RISC-V, which replies with a Linux timestamp. Both apps communicate through ivshmem
> shared memory across two separate QEMU instances.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                     Host (macOS → Lima Linux VM)                  │
│                                                                  │
│  ┌────────────────────────┐      ┌────────────────────────────┐  │
│  │   qemu-system-aarch64  │      │   qemu-system-riscv64      │  │
│  │                        │      │                            │  │
│  │   ARM Cluster          │      │   RISC-V Cluster           │  │
│  │   ┌──────────────────┐ │      │ ┌──────────────────────┐   │  │
│  │   │ EL3   TF-A       │ │      │ │ M-mode   OpenSBI     │   │  │
│  │   │ EL2   Hafnium    │ │      │ │ S-mode   Linux       │   │  │
│  │   │ EL1-S OP-TEE     │ │      │ │ U-mode   [pong app]  │   │  │
│  │   │ EL1-N Linux      │ │      │ │                      │   │  │
│  │   │       [ping app] │ │      │ └──────────────────────┘   │  │
│  │   └──────────────────┘ │      │ RISC-V IOMMU               │  │
│  │   SMMUv3  GICv3        │      │ AIA (APLIC + IMSIC)        │  │
│  └──────────┬─────────────┘      └─────────────┬──────────────┘  │
│             │   ivshmem-doorbell (PCI BAR2)     │                 │
│             └──────────────┬────────────────────┘                 │
│                   ┌────────▼───────────┐                          │
│                   │   ivshmem-server   │  64 MB POSIX shm         │
│                   │   Unix socket IPC  │  doorbell vectors × 4    │
│                   └────────────────────┘                          │
│                   ┌────────────────────┐                          │
│                   │   TAP bridge       │  virtio-net (ssh/debug)  │
│                   └────────────────────┘                          │
└──────────────────────────────────────────────────────────────────┘
```

---

## Security Isolation Layers

### ARM — 4 Exception Levels

| Level | Software     | Role                               |
|-------|--------------|------------------------------------|
| EL3   | TF-A         | Secure Monitor, owns TrustZone     |
| EL2   | Hafnium      | Type-1 Hypervisor, VM isolation    |
| EL1-S | OP-TEE       | Trusted OS (Secure World)          |
| EL1-N | Linux 6.x    | Normal World, runs ping app        |

QEMU flags: `-machine virt,secure=on,virtualization=on,gic-version=3,iommu=smmuv3`

Key chimera files:
- `hw/arm/virt.c:4133` — `secure`, `virtualization`, `iommu` machine properties
- `hw/arm/smmuv3.c` — SMMUv3 IOMMU (DMA isolation between VMs)
- `hw/misc/tz-mpc.c`, `hw/misc/tz-ppc.c` — TrustZone memory/peripheral protection
- `target/arm/cpu.h:986,988` — `has_el2`, `has_el3` CPU feature flags

### RISC-V — Functional Linux Bring-up

| Mode    | Software     | Role                            |
|---------|--------------|---------------------------------|
| M-mode  | OpenSBI      | Machine-level SBI firmware      |
| S-mode  | Linux 6.x    | Guest OS for ivshmem and pong   |
| U-mode  | `pong` app   | User-space ivshmem responder    |

QEMU flags: `-machine virt,aclint=on,aia=aplic-imsic -cpu rv64,h=true`

Key chimera file:
- `target/riscv/cpu.c:1196` — `MISA_EXT_INFO(RVH, "h", "Hypervisor")`

---

## Software Stack

| Layer          | ARM             | RISC-V              |
|----------------|-----------------|---------------------|
| Secure Monitor | TF-A            | OpenSBI             |
| Hypervisor     | Hafnium         | —                   |
| Trusted OS     | OP-TEE          | —                   |
| General OS     | Linux 6.x       | Linux 6.x           |
| IPC transport  | ivshmem-doorbell| ivshmem-doorbell    |
| App            | `ping` (sender) | `pong` (responder)  |

---

## Shared Memory Protocol

### Layout (64 MB ivshmem BAR2)

```
┌──────────────────────────────────────────────┐  offset
│  struct shm_channel  arm_to_riscv            │  0x0000
│    uint32_t flag     (0=empty, 1=data ready) │
│    struct shm_msg    msg                     │
├──────────────────────────────────────────────┤  0x1000
│  struct shm_channel  riscv_to_arm            │
│    uint32_t flag                             │
│    struct shm_msg    msg                     │
├──────────────────────────────────────────────┤  0x2000
│  (reserved for future data region)           │
└──────────────────────────────────────────────┘
```

### Message struct

```c
/* ivshmem_proto.h — shared by both apps */
#ifndef IVSHMEM_PROTO_H
#define IVSHMEM_PROTO_H

#include <stdint.h>

#define PING_MAGIC  0x50494E47U   /* "PING" */
#define PONG_MAGIC  0x504F4E47U   /* "PONG" */

struct shm_msg {
    uint32_t magic;
    uint32_t seq;
    int64_t  ts_sec;    /* clock_gettime(CLOCK_REALTIME) */
    int64_t  ts_nsec;
};

struct shm_channel {
    volatile uint32_t flag;  /* writer sets 1; reader clears to 0 */
    uint32_t          _pad;
    struct shm_msg    msg;
};

/* Total layout mapped at BAR2 base */
struct shm_layout {
    struct shm_channel arm_to_riscv;         /* 0x0000 */
    uint8_t            _pad0[0x1000 - sizeof(struct shm_channel)];
    struct shm_channel riscv_to_arm;         /* 0x1000 */
};

#endif /* IVSHMEM_PROTO_H */
```

### Message flow

```
ARM (ping sender)                         RISC-V (pong responder)
─────────────────                         ───────────────────────
clock_gettime(&ts_send)
write arm_to_riscv.msg {PING, seq, ts}
arm_to_riscv.flag = 1  ──────────────────→ poll arm_to_riscv.flag == 1
                                           read ping msg
                                           arm_to_riscv.flag = 0
                                           clock_gettime(&ts_riscv)
                                           write riscv_to_arm.msg {PONG, seq, ts_riscv}
poll riscv_to_arm.flag == 1 ←──────────── riscv_to_arm.flag = 1
clock_gettime(&ts_recv)
read pong msg
riscv_to_arm.flag = 0
print: seq, ts_send, ts_riscv, RTT
```

---

## Application Code

### `ping.c` — ARM side

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include "ivshmem_proto.h"

#define BAR2_SIZE (64 * 1024 * 1024)

static const char *find_ivshmem_resource(void)
{
    /* sysfs path populated at runtime via find_ivshmem.sh */
    static char path[256];
    FILE *f = popen(
        "find /sys/bus/pci/devices -name vendor -exec grep -l 0x1af4 {} \\; "
        "2>/dev/null | head -1 | xargs dirname | xargs -I{} echo {}/resource2",
        "r");
    if (!f || !fgets(path, sizeof(path), f)) return NULL;
    pclose(f);
    path[strcspn(path, "\n")] = 0;
    return path;
}

int main(int argc, char *argv[])
{
    const char *bar2_path = (argc > 1) ? argv[1] : find_ivshmem_resource();
    if (!bar2_path) {
        fprintf(stderr, "Usage: %s /sys/bus/pci/devices/XXXX/resource2\n", argv[0]);
        return 1;
    }

    int fd = open(bar2_path, O_RDWR | O_SYNC);
    if (fd < 0) { perror("open bar2"); return 1; }

    struct shm_layout *shm = mmap(NULL, BAR2_SIZE,
                                  PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) { perror("mmap"); return 1; }

    printf("[ARM] ivshmem BAR2 mapped at %p\n", (void *)shm);
    printf("[ARM] Starting ping loop (Ctrl-C to stop)...\n\n");

    uint32_t seq = 0;
    while (1) {
        /* --- send ping --- */
        struct timespec ts_send;
        clock_gettime(CLOCK_REALTIME, &ts_send);

        shm->arm_to_riscv.msg.magic  = PING_MAGIC;
        shm->arm_to_riscv.msg.seq    = seq;
        shm->arm_to_riscv.msg.ts_sec = ts_send.tv_sec;
        shm->arm_to_riscv.msg.ts_nsec = ts_send.tv_nsec;
        __sync_synchronize();
        shm->arm_to_riscv.flag = 1;

        printf("[ARM] PING #%u  sent       %ld.%09ld\n",
               seq, ts_send.tv_sec, ts_send.tv_nsec);

        /* --- wait for pong --- */
        while (shm->riscv_to_arm.flag != 1)
            __sync_synchronize();

        struct timespec ts_recv;
        clock_gettime(CLOCK_REALTIME, &ts_recv);

        struct shm_msg pong = shm->riscv_to_arm.msg;
        __sync_synchronize();
        shm->riscv_to_arm.flag = 0;

        int64_t rtt_ns = (ts_recv.tv_sec  - ts_send.tv_sec)  * 1000000000LL
                       + (ts_recv.tv_nsec - ts_send.tv_nsec);

        printf("[ARM] PONG #%u  riscv_time %ld.%09ld\n",
               pong.seq, pong.ts_sec, pong.ts_nsec);
        printf("[ARM]           rtt        %lld ns  (%.3f ms)\n\n",
               (long long)rtt_ns, rtt_ns / 1e6);

        seq++;
        sleep(1);
    }

    return 0;
}
```

### `pong.c` — RISC-V side

```c
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include "ivshmem_proto.h"

#define BAR2_SIZE (64 * 1024 * 1024)

int main(int argc, char *argv[])
{
    if (argc < 2) {
        fprintf(stderr, "Usage: %s /sys/bus/pci/devices/XXXX/resource2\n", argv[0]);
        return 1;
    }

    int fd = open(argv[1], O_RDWR | O_SYNC);
    if (fd < 0) { perror("open bar2"); return 1; }

    struct shm_layout *shm = mmap(NULL, BAR2_SIZE,
                                  PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) { perror("mmap"); return 1; }

    printf("[RISC-V] ivshmem BAR2 mapped at %p\n", (void *)shm);
    printf("[RISC-V] Waiting for pings...\n\n");

    while (1) {
        /* --- wait for ping --- */
        while (shm->arm_to_riscv.flag != 1)
            __sync_synchronize();

        struct timespec ts_recv;
        clock_gettime(CLOCK_REALTIME, &ts_recv);

        struct shm_msg ping = shm->arm_to_riscv.msg;
        __sync_synchronize();
        shm->arm_to_riscv.flag = 0;

        printf("[RISC-V] PING #%u  arm_time   %ld.%09ld\n",
               ping.seq, ping.ts_sec, ping.ts_nsec);
        printf("[RISC-V]           recv_time  %ld.%09ld\n",
               ts_recv.tv_sec, ts_recv.tv_nsec);

        /* --- send pong --- */
        shm->riscv_to_arm.msg.magic  = PONG_MAGIC;
        shm->riscv_to_arm.msg.seq    = ping.seq;
        shm->riscv_to_arm.msg.ts_sec = ts_recv.tv_sec;
        shm->riscv_to_arm.msg.ts_nsec = ts_recv.tv_nsec;
        __sync_synchronize();
        shm->riscv_to_arm.flag = 1;

        printf("[RISC-V] PONG #%u  sent\n\n", ping.seq);
    }

    return 0;
}
```

### `Makefile`

```makefile
CC_ARM   = aarch64-linux-gnu-gcc
CC_RISCV = riscv64-linux-gnu-gcc
CFLAGS   = -O2 -Wall -static

all: ping pong

ping: ping.c ivshmem_proto.h
	$(CC_ARM) $(CFLAGS) -o $@ $<

pong: pong.c ivshmem_proto.h
	$(CC_RISCV) $(CFLAGS) -o $@ $<

clean:
	rm -f ping pong
```

### Expected output

**ARM terminal:**
```
[ARM] ivshmem BAR2 mapped at 0x7f8a000000
[ARM] Starting ping loop (Ctrl-C to stop)...

[ARM] PING #0  sent       1720000000.123456789
[ARM] PONG #0  riscv_time 1720000000.124098123
[ARM]           rtt        841334 ns  (0.841 ms)

[ARM] PING #1  sent       1720000001.125000000
[ARM] PONG #1  riscv_time 1720000001.125712456
[ARM]           rtt        712456 ns  (0.712 ms)
```

**RISC-V terminal:**
```
[RISC-V] ivshmem BAR2 mapped at 0x7fa0000000
[RISC-V] Waiting for pings...

[RISC-V] PING #0  arm_time   1720000000.123456789
[RISC-V]           recv_time  1720000000.124098123
[RISC-V] PONG #0  sent

[RISC-V] PING #1  arm_time   1720000001.125000000
[RISC-V]           recv_time  1720000001.125712456
[RISC-V] PONG #1  sent
```

---

## macOS Constraint

`ivshmem` requires `eventfd` (Linux syscall, not on macOS):

```
# meson.build:3241
have_ivshmem = config_host_data.get('CONFIG_EVENTFD')
```

Homebrew QEMU on macOS does not include the ivshmem device. All phases run
**inside a Lima Linux VM** on the Mac.

---

## Phases

---

### Phase 1 — Basic ivshmem Connectivity  ← *start here*

**Goal:** Two QEMU instances (ARM + RISC-V) each enumerate the ivshmem PCI device,
and a byte written by one guest is immediately readable by the other.

**Steps:**

#### 1.1 Install Lima and create Linux VM

```bash
# on macOS
brew install lima
limactl start --name=qemu-dev --vm-type=vz \
  --cpus=4 --memory=8 --disk=40 \
  template://ubuntu-lts
limactl shell qemu-dev
```

#### 1.2 Install QEMU + cross-compilers inside Lima

```bash
sudo apt update && sudo apt install -y \
  qemu-system-arm qemu-system-misc \
  gcc-aarch64-linux-gnu gcc-riscv64-linux-gnu \
  opensbi pciutils
```

#### 1.3 Build ivshmem-server from chimera source

```bash
# inside Lima — chimera is auto-mounted under ~/dev-projects/chimera via Lima's $HOME mount
cd ~/dev-projects/chimera
mkdir -p build-linux && cd build-linux
../configure --target-list=aarch64-softmmu,riscv64-softmmu --enable-debug
ninja ivshmem-server ivshmem-client
```

#### 1.4 Download minimal guest images

```bash
mkdir -p ~/iso && cd ~/iso

# ARM64 Alpine (~35 MB live CD)
wget https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-virt-3.21.0-aarch64.iso

# RISC-V64 Alpine (disk image)
wget https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/riscv64/alpine-virt-3.21.0-riscv64.img
```

#### 1.5 Start ivshmem-server

```bash
mkdir -p /tmp/ivshmem
~/dev-projects/chimera/build-linux/ivshmem-server \
  -S /tmp/ivshmem/sock \
  -l $((64 * 1024 * 1024)) \
  -n 4 \
  -v &
```

#### 1.6 Start ARM QEMU (Terminal B)

```bash
qemu-system-aarch64 \
  -machine virt,gic-version=3 \
  -cpu cortex-a57 -m 512M -smp 2 \
  -chardev socket,id=ivshmem,path=/tmp/ivshmem/sock \
  -device ivshmem-doorbell,chardev=ivshmem,vectors=4 \
  -drive file=~/iso/alpine-virt-3.21.0-aarch64.iso,media=cdrom -boot d \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-device,netdev=net0 \
  -nographic
```

#### 1.7 Start RISC-V QEMU (Terminal C)

```bash
qemu-system-riscv64 \
  -machine virt,aclint=on \
  -cpu rv64 -m 512M -smp 2 \
  -chardev socket,id=ivshmem,path=/tmp/ivshmem/sock \
  -device ivshmem-doorbell,chardev=ivshmem,vectors=4 \
  -drive file=~/iso/alpine-virt-3.21.0-riscv64.img,format=raw \
  -bios /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin \
  -netdev user,id=net0,hostfwd=tcp::2223-:22 \
  -device virtio-net-device,netdev=net0 \
  -nographic
```

#### 1.8 Verify ivshmem inside each guest

```bash
# In both guests (Alpine login: root / no password)
apk add pciutils

lspci -v | grep -A6 "1af4"
# Expected: vendor=1af4 device=1110, BAR2 = shared memory region

# Find BAR2 resource path
ls /sys/bus/pci/devices/*/vendor | xargs grep -l 0x1af4 | xargs dirname
# e.g. /sys/bus/pci/devices/0000:00:02.0

# On the tested Alpine kernels, raw dd reads from resource2 may return EIO
# even when BAR2 exists and mmap access works. The stronger shared-memory
# validation path is the later ping/pong mmap test in Phase 4.
```

**Success criteria:**
- Both guests show `vendor=0x1af4 device=0x1110` in `lspci`
- Both guests expose a BAR2 `resource2` path for the ivshmem device
- Phase 4 later proves functional shared-memory exchange using guest mmap

---

### Phase 2 — ARM Security Stack

**Goal:** ARM guest boots with full TrustZone stack active (TF-A → Hafnium → Linux).

#### QEMU flags

```bash
qemu-system-aarch64 \
  -machine virt,secure=on,virtualization=on,gic-version=3,iommu=smmuv3 \
  -cpu cortex-a76 -m 2G -smp 4 \
  -bios bl1.bin \
  -drive if=pflash,file=fip.bin \   # TF-A FIP: BL2 + BL31 + Hafnium (BL32)
  -drive file=linux.img,format=raw \
  -chardev socket,id=ivshmem,path=/tmp/ivshmem/sock \
  -device ivshmem-doorbell,chardev=ivshmem,vectors=4 \
  -nographic
```

#### Build order

1. **TF-A** (`trusted-firmware-a`) for `qemu_armv8a` platform → `bl1.bin` + FIP
2. **Hafnium** (Secure Partition Manager) → included in FIP as BL32
3. **OP-TEE** (optional Trusted OS) → Secure Partition image
4. **Linux** as Normal World payload

#### Verification

```bash
# Representative serial evidence:
# NOTICE:  BL31: ...
# INFO: Initializing Hafnium (SPMC)
# I/TC: OP-TEE version: ...
# Welcome to Alpine Linux 3.21
# localhost login:

# Optional guest-side check after login:
uname -a
```

---

### Phase 3 — RISC-V Functional Bring-up

**Goal:** RISC-V guest boots Linux in a debuggable configuration suitable for
ivshmem testing, `pong` bring-up, and guest software debugging. KVM-backed
acceleration is optional; functional bring-up under emulation is sufficient.

#### QEMU flags

```bash
qemu-system-riscv64 \
  -machine virt,aclint=on,aia=aplic-imsic \
  -cpu rv64,h=true,v=true \
  -m 2G -smp 4 \
  -bios opensbi-riscv64-generic-fw_dynamic.bin \
  -drive file=linux-riscv64.img,format=raw \
  -chardev socket,id=ivshmem,path=/tmp/ivshmem/sock \
  -device ivshmem-doorbell,chardev=ivshmem,vectors=4 \
  -nographic
```

#### Verification

```bash
# In Linux guest:
cat /proc/cpuinfo | grep isa
# If the current runtime exposes the H extension, the ISA string should include 'h'.

lspci -v | grep -A6 1af4
# Expected: ivshmem PCI device visible with vendor=1af4 device=1110.

# Guest should reach one of:
# - a normal Linux login prompt, or
# - a direct debug shell such as rdinit=/bin/sh

# If KVM is available on a future host, the stronger optional checks are:
ls /dev/kvm
dmesg | grep -i "kvm\|hypervisor"
```

---

### Phase 4 — Ping-Pong Application (Cross-Cluster IPC)

**Goal:** `ping` on ARM sends a message through ivshmem; `pong` on RISC-V
replies with a Linux `clock_gettime` timestamp; ARM prints the RTT.

#### 4.1 Create source tree (on Lima host)

```bash
mkdir -p ~/pingpong
# Copy ping.c, pong.c, ivshmem_proto.h, Makefile into ~/pingpong/
```

#### 4.2 Cross-compile

```bash
cd ~/pingpong
make all
# Produces: ping (aarch64 ELF), pong (riscv64 ELF)
file ping pong
# ping: ELF 64-bit LSB executable, ARM aarch64, statically linked
# pong: ELF 64-bit LSB executable, UCB RISC-V, statically linked
```

#### 4.3 Transfer binaries into guests

```bash
# Transfer via SSH (hostfwd ports set in Phase 1)
scp -P 2222 ping  root@localhost:/usr/local/bin/  # ARM guest
scp -P 2223 pong  root@localhost:/usr/local/bin/  # RISC-V guest
```

#### 4.4 Find BAR2 path in each guest

```bash
# Run in each guest:
BAR2=$(find /sys/bus/pci/devices -name vendor \
  -exec grep -l 0x1af4 {} \; 2>/dev/null | head -1 | xargs dirname)/resource2
echo $BAR2
# e.g. /sys/bus/pci/devices/0000:00:02.0/resource2
```

#### 4.5 Run

```bash
# RISC-V guest (start first — waits for pings):
pong $BAR2

# ARM guest (start sender):
ping $BAR2
```

#### Expected output

```
# ARM terminal
[ARM] PING #0  sent       1720000000.123456789
[ARM] PONG #0  riscv_time 1720000000.124098123
[ARM]           rtt        841334 ns  (0.841 ms)

# RISC-V terminal
[RISC-V] PING #0  arm_time   1720000000.123456789
[RISC-V]           recv_time  1720000000.124098123
[RISC-V] PONG #0  sent
```

**Success criteria:**
- RISC-V receives pings and logs ARM's send timestamp
- ARM receives pong with RISC-V's `clock_gettime` timestamp
- RTT < 5 ms in QEMU emulation (< 1 ms on KVM-accelerated)

---

## File Locations (chimera source)

| Topic                  | Path                             |
|------------------------|----------------------------------|
| ARM virt machine       | `hw/arm/virt.c`                  |
| TrustZone MPC / PPC    | `hw/misc/tz-mpc.c`, `tz-ppc.c`  |
| ARM SSE subsystem      | `hw/arm/armsse.c`                |
| SMMUv3 IOMMU           | `hw/arm/smmuv3.c`                |
| GICv3 interrupt ctrl   | `hw/intc/arm_gicv3*.c`           |
| RISC-V virt machine    | `hw/riscv/`                      |
| RISC-V IOMMU           | `hw/riscv/riscv-iommu.c`         |
| ivshmem PCI device     | `hw/misc/ivshmem-pci.c`          |
| ivshmem flat (sysbus)  | `hw/misc/ivshmem-flat.c`         |
| ivshmem server source  | `contrib/ivshmem-server/`        |
| ivshmem build gate     | `meson.build:3241`               |
| ARM EL2/EL3 flags      | `target/arm/cpu.h:986,988`       |
| RISC-V H-extension     | `target/riscv/cpu.c:1196`        |

---

### Phase 5 — ARM/Linux + RISC-V/Linux to RISC-V/FreeRTOS

**Goal:** Both Linux guests send timestamped hello messages to a
dedicated RISC-V FreeRTOS guest over two separate ivshmem links, and
the FreeRTOS guest acknowledges each request with its own timestamp.

**Payloads:**
- `contrib/heterogeneous-soc/freertos-showcase/hello-arm-linux`
- `contrib/heterogeneous-soc/freertos-showcase/hello-riscv-linux`
- `contrib/heterogeneous-soc/freertos-showcase/freertos-riscv-demo.elf`

**Host flow:**
- Start `scripts/heterogeneous-soc/start-ivshmem-server-arm-freertos.sh`
- Start `scripts/heterogeneous-soc/start-ivshmem-server-riscv-freertos.sh`
- Build payloads with `scripts/heterogeneous-soc/build-freertos-showcase.sh`
- Launch the guests with `run-arm-phase5.sh`,
  `run-riscv-phase5.sh`, and `run-riscv-freertos-phase5.sh`

**Success criteria:**
- ARM/Linux prints `hello from arm-linux` and receives an ACK
- RISC-V/Linux prints `hello from riscv-linux` and receives an ACK
- FreeRTOS logs both inbound hellos during the same run
