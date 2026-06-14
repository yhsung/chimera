# Heterogeneous SoC Simulation Plan

> **Historical / superseded.** This plan describes the original ARM-Linux ↔ RISC-V-Linux
> ivshmem ping-pong design. The current chimera-2 demo replaces it with a
> Cortex-R52 FreeRTOS bare-metal guest that fans out to ARM-Linux and MIPS-Linux
> Linux senders over a single HELLO/ACK wire protocol — see
> [chimera-2 README §Wire Protocol](https://github.com/yhsung/chimera-2#wire-protocol)
> and `hw/arm/chimera_r52_freertos_demo.c`. The ARM Security Stack notes, the
> meson.build gating note, and the upstream-QEMU file-locations table below
> remain accurate; the rest is preserved only for historical reference.
>
> **Goal (historical):** Simulate an ARM + RISC-V heterogeneous SoC with security-isolated multi-OS.
> Final deliverable: a userspace `ping` app on ARM sends a message to a `pong` app on
> RISC-V, which replies with a Linux timestamp. Both apps communicate through ivshmem
> shared memory across two separate QEMU instances.

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                     Host (macOS → Lima Linux VM)                  │
│                                                                  │
│  ┌────────────────────────┐                                       │
│  │   qemu-system-aarch64  │                                       │
│  │                        │                                       │
│  │   ARM Cluster          │                                       │
│  │   ┌──────────────────┐ │                                       │
│  │   │ EL3   TF-A       │ │                                       │
│  │   │ EL2   Hafnium    │ │                                       │
│  │   │ EL1-S OP-TEE     │ │                                       │
│  │   │ EL1-N Linux      │ │                                       │
│  │   │       [ping app] │ │                                       │
│  │   └──────────────────┘ │                                       │
│  │   SMMUv3  GICv3        │                                       │
│  └──────────┬─────────────┘                                       │
│             │   ivshmem-doorbell (PCI BAR2)                       │
│             ▼                                                     │
│   ┌────────────────────┐                                          │
│   │   ivshmem-server   │  64 MB POSIX shm                         │
│   │   Unix socket IPC  │  doorbell vectors × 4                    │
│   └────────────────────┘                                          │
│   ┌────────────────────┐                                          │
│   │   TAP bridge       │  virtio-net (ssh/debug)                  │
│   └────────────────────┘                                          │
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

---

## Software Stack

*(The RISC-V column of this table is removed along with the original ARM-Linux ↔ RISC-V-Linux ping-pong design it describes. See the historical note at the top of this file.)*

---

## Shared Memory Protocol

*(Removed. This section described the original ARM-Linux ↔ RISC-V-Linux
ping-pong shared-memory protocol (`arm_to_riscv` / `riscv_to_arm` channels,
PING/PONG magics, `ping.c` and `pong.c` source, the `Makefile`, and the
expected terminal output). The current chimera-2 demo uses a different
HELLO/ACK wire protocol and a Cortex-R52 FreeRTOS bare-metal guest; see
the historical note at the top of this file.)*

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
  gcc-aarch64-linux-gnu \
  opensbi pciutils
```

#### 1.3 Build ivshmem-server from chimera source

```bash
# inside Lima — chimera is auto-mounted under ~/dev-projects/chimera via Lima's $HOME mount
cd ~/dev-projects/chimera
mkdir -p build-linux && cd build-linux
../configure --target-list=aarch64-softmmu --enable-debug
ninja ivshmem-server ivshmem-client
```

#### 1.4 Download minimal guest images

```bash
mkdir -p ~/iso && cd ~/iso

# ARM64 Alpine (~35 MB live CD)
wget https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-virt-3.21.0-aarch64.iso
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

#### 1.7 Verify ivshmem inside the ARM guest

```bash
# In the ARM guest (Alpine login: root / no password)
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
- The ARM guest shows `vendor=0x1af4 device=0x1110` in `lspci`
- The ARM guest exposes a BAR2 `resource2` path for the ivshmem device
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

### Phase 3 — (removed)

*(Removed. The original Phase 3 described RISC-V/Linux functional bring-up
using `qemu-system-riscv64`; that guest is no longer part of the chimera-2
demo. See the historical note at the top of this file.)*

---

### Phase 4 — (removed)

*(Removed. The original Phase 4 described the ARM-Linux `ping` ↔ RISC-V-Linux
`pong` cross-cluster application, including the `arm_to_riscv` /
`riscv_to_arm` shared-memory protocol, `ping.c` / `pong.c` source, and
`Makefile`. The current chimera-2 demo uses a different HELLO/ACK wire
protocol and a Cortex-R52 FreeRTOS bare-metal guest; see the historical
note at the top of this file.)*

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

### Phase 5 — (removed)

*(Removed. The original Phase 5 described an ARM-Linux + RISC-V-Linux
to RISC-V-FreeRTOS hello/ack design; the RISC-V-Linux channel has been
removed (IVSHMEM1) in the current chimera-2 demo, and the FreeRTOS
guest runs on a Cortex-R52 (not RISC-V). See the historical note at the
top of this file.)*


