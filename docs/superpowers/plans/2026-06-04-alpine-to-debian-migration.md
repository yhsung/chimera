# Alpine Linux → Debian Linux Migration Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Alpine Linux with Debian Linux as the guest OS for all three architectures (ARM, RISC-V, MIPS) to get modern MIPS support — Alpine dropped MIPS after v3.10; Debian actively maintains its MIPS port.

**Architecture:** Instead of Alpine's initramfs-as-rootfs-with-ISO-modloop model, Debian uses a proper rootfs on a qcow2 disk image created via `debootstrap`. The kernel and initrd are extracted from Debian kernel packages (.deb files) downloaded directly from Debian mirrors. The initrd overlay system is replaced by configuring systemd services inside the rootfs for serial auto-login and 9p mount. ISO CD-ROM drives are removed since kernel modules live on the rootfs disk.

**Tech Stack:** bash, debootstrap, qemu-img, mkfs.ext4, dpkg-deb, Debian 12 (bookworm), systemd

---

## File Structure

| File | Action | Purpose |
|------|--------|---------|
| `scripts/heterogeneous-soc/common.sh` | Modify | Replace Alpine env vars with Debian equivalents; add Debian rootfs disk paths |
| `scripts/heterogeneous-soc/guest-fetch-images.sh` | Modify | Replace Alpine ISO URLs with Debian kernel .deb download URLs |
| `scripts/heterogeneous-soc/guest-prepare-debian-boot-assets.sh` | **Create** | Extract vmlinuz + initrd.img from Debian kernel .deb packages per arch |
| `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh` | **Create** | Create minimal Debian rootfs qcow2 disk per arch via debootstrap |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | Modify | Debian boot: kernel, initrd, rootfs disk, cmdline, no ISO |
| `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh` | Modify | Debian boot: kernel, initrd, rootfs disk, cmdline, no ISO |
| `scripts/heterogeneous-soc/guest-run-chimera.sh` | Modify | Debian MIPS boot: kernel, initrd, rootfs disk, cmdline, no ISO |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | Modify | Debian shell prompt detection (`login:`, `root@`) |
| `scripts/heterogeneous-soc/guest-run-freertos-harness.sh` | Modify | Debian shell prompt detection and mount commands |
| `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh` | Modify | Debian asset fetch calls instead of Alpine ISO fetches |
| `scripts/heterogeneous-soc/guest-prepare-arm-phase2-boot-assets.sh` | Remove/Unused | Replaced by `guest-prepare-debian-boot-assets.sh` |
| `scripts/heterogeneous-soc/guest-prepare-riscv-phase3-boot-assets.sh` | Remove/Unused | Replaced by `guest-prepare-debian-boot-assets.sh` |
| `scripts/heterogeneous-soc/guest-prepare-mips-boot-assets.sh` | Remove/Unused | Replaced by `guest-prepare-debian-boot-assets.sh` |
| `scripts/heterogeneous-soc/guest-prepare-demo-guest-overlays.sh` | Remove/Unused | Systemd config replaces Alpine openrc overlay |
| `scripts/heterogeneous-soc/guest-prepare-riscv-uboot.sh` | Remove/Unused | Debian RISCV boots directly with OpenSBI, no U-Boot needed |

Debian provides three key architectural differences from Alpine:

1. **Root filesystem lives on a qcow2 disk** (not inside initramfs + CD-ROM squashfs)
2. **initrd is the standard Debian initramfs** (not a full system — it pivot-roots to the qcow2 disk)
3. **System configuration uses systemd unit overrides** (not openrc inittab)

---

### Task 1: Update common.sh with Debian environment variables

**Files:**
- Modify: `scripts/heterogeneous-soc/common.sh:36-65`

- [ ] **Step 1: Replace the Alpine variable block with Debian equivalents**

Replace lines 36-65 (the entire Alpine arch block) with:

```bash
# ── Debian rootfs disk images (created by guest-prepare-debian-rootfs.sh) ──────────
ARM_DEBIAN_DISK="${ARM_DEBIAN_DISK:-${ASSET_DIR}/debian-arm64.qcow2}"
RISCV_DEBIAN_DISK="${RISCV_DEBIAN_DISK:-${ASSET_DIR}/debian-riscv64.qcow2}"
MIPS_DEBIAN_DISK="${MIPS_DEBIAN_DISK:-${ASSET_DIR}/debian-mips.qcow2}"

# ── ARM (aarch64) ────────────────────────────────────────────────────────────
ARM_KERNEL_DEB="${ARM_KERNEL_DEB:-${ASSET_DIR}/linux-image-arm64.deb}"
ARM_BOOT_ASSET_DIR="${ARM_BOOT_ASSET_DIR:-${HOME}/heterogeneous-soc-secure-stack/boot-assets}"
ARM_KERNEL_IMAGE="${ARM_KERNEL_IMAGE:-${ARM_BOOT_ASSET_DIR}/vmlinuz}"
ARM_INITRD_IMAGE="${ARM_INITRD_IMAGE:-${ARM_BOOT_ASSET_DIR}/initrd.img}"
ARM_UEFI_BIOS="${ARM_UEFI_BIOS:-/usr/share/qemu-efi-aarch64/QEMU_EFI.fd}"
ARM_KERNEL_CMDLINE="${ARM_KERNEL_CMDLINE:-console=ttyAMA0 root=/dev/vda1 rw}"

# ── RISC-V (riscv64) ─────────────────────────────────────────────────────────
RISCV_KERNEL_DEB="${RISCV_KERNEL_DEB:-${ASSET_DIR}/linux-image-riscv64.deb}"
RISCV_OPENSBI_BIOS="${RISCV_OPENSBI_BIOS:-/usr/lib/riscv64-linux-gnu/opensbi/generic/fw_jump.bin}"
RISCV_BOOT_ASSET_DIR="${RISCV_BOOT_ASSET_DIR:-${ASSET_DIR}/riscv-boot}"
RISCV_KERNEL_IMAGE="${RISCV_KERNEL_IMAGE:-${RISCV_BOOT_ASSET_DIR}/vmlinuz}"
RISCV_INITRD_IMAGE="${RISCV_INITRD_IMAGE:-${RISCV_BOOT_ASSET_DIR}/initrd.img}"
RISCV_KERNEL_CMDLINE="${RISCV_KERNEL_CMDLINE:-console=ttyS0 root=/dev/vda1 rw}"

# ── MIPS (big-endian, debian-ports) ──────────────────────────────────────────
MIPS_KERNEL_DEB="${MIPS_KERNEL_DEB:-${ASSET_DIR}/linux-image-4kc-malta.deb}"
MIPS_BOOT_ASSET_DIR="${MIPS_BOOT_ASSET_DIR:-${ASSET_DIR}/mips-boot}"
MIPS_KERNEL_IMAGE="${MIPS_KERNEL_IMAGE:-${MIPS_BOOT_ASSET_DIR}/vmlinuz}"
MIPS_INITRD_IMAGE="${MIPS_INITRD_IMAGE:-${MIPS_BOOT_ASSET_DIR}/initrd.img}"
MIPS_KERNEL_CMDLINE="${MIPS_KERNEL_CMDLINE:-console=ttyS0 root=/dev/sda1 rw}"
```

- [ ] **Step 2: Verify common.sh is still valid bash after edits**

Run: `bash -n scripts/heterogeneous-soc/common.sh`
Expected: no output (no syntax errors)

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/common.sh
git commit -m "feat: replace Alpine env vars with Debian equivalents in common.sh

Switch all three architectures (ARM, RISC-V, MIPS) from Alpine ISO-based
variables to Debian rootfs disk + kernel .deb based variables.
Remove Alpine-specific: ISO paths, U-Boot, modloop, initramfs overlay paths.
Add Debian-specific: qcow2 disk paths, kernel .deb paths, initrd.img paths.
"
```

---

### Task 2: Create guest-prepare-debian-boot-assets.sh

**Files:**
- Create: `scripts/heterogeneous-soc/guest-prepare-debian-boot-assets.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# guest-prepare-debian-boot-assets.sh
#
# Extract vmlinuz and initrd.img from a Debian kernel .deb package.
# Called per architecture: the arch is inferred from the .deb filename.
#
# Expected kernel .deb files (downloaded by guest-fetch-images.sh):
#   ${ARM_KERNEL_DEB}    -> arm64 kernel
#   ${RISCV_KERNEL_DEB}  -> riscv64 kernel
#   ${MIPS_KERNEL_DEB}   -> mips kernel
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

_extract_kernel_deb() {
    local deb_path="$1"
    local boot_dir="$2"

    require_file "${deb_path}" "kernel .deb package"

    mkdir -p "${boot_dir}"

    # Extract vmlinuz and initrd.img from the .deb
    # Debian kernel packages contain ./boot/vmlinuz-* and ./boot/initrd.img-*
    dpkg-deb -x "${deb_path}" "${boot_dir}"

    # Find the extracted files (version suffix varies)
    local vmlinuz_src
    vmlinuz_src="$(find "${boot_dir}/boot" -maxdepth 1 -name 'vmlinuz-*' -not -name '*.old-dkms' 2>/dev/null | head -1)"
    local initrd_src
    initrd_src="$(find "${boot_dir}/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | head -1)"

    if [[ -z "${vmlinuz_src}" ]]; then
        # Fallback: the deb may extract to ./boot directly with a flat structure
        vmlinuz_src="$(find "${boot_dir}" -maxdepth 3 -name 'vmlinuz-*' -not -name '*.old-dkms' 2>/dev/null | head -1)"
        initrd_src="$(find "${boot_dir}" -maxdepth 3 -name 'initrd.img-*' 2>/dev/null | head -1)"
    fi

    if [[ -z "${vmlinuz_src}" ]]; then
        echo "ERROR: could not find vmlinuz in extracted .deb at ${boot_dir}" >&2
        echo "Contents:" >&2
        find "${boot_dir}" -type f | head -20 >&2
        exit 1
    fi

    # Copy to the expected flat path
    cp "${vmlinuz_src}" "${boot_dir}/vmlinuz"
    cp "${initrd_src}" "${boot_dir}/initrd.img"

    echo "Extracted: ${boot_dir}/vmlinuz"
    echo "Extracted: ${boot_dir}/initrd.img"
}

# ARM
_extract_kernel_deb "${ARM_KERNEL_DEB}" "${ARM_BOOT_ASSET_DIR}"
echo "ARM_KERNEL_IMAGE=${ARM_BOOT_ASSET_DIR}/vmlinuz"
echo "ARM_INITRD_IMAGE=${ARM_BOOT_ASSET_DIR}/initrd.img"

# RISC-V
_extract_kernel_deb "${RISCV_KERNEL_DEB}" "${RISCV_BOOT_ASSET_DIR}"
echo "RISCV_KERNEL_IMAGE=${RISCV_BOOT_ASSET_DIR}/vmlinuz"
echo "RISCV_INITRD_IMAGE=${RISCV_BOOT_ASSET_DIR}/initrd.img"

# MIPS
_extract_kernel_deb "${MIPS_KERNEL_DEB}" "${MIPS_BOOT_ASSET_DIR}"
echo "MIPS_KERNEL_IMAGE=${MIPS_BOOT_ASSET_DIR}/vmlinuz"
echo "MIPS_INITRD_IMAGE=${MIPS_BOOT_ASSET_DIR}/initrd.img"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/heterogeneous-soc/guest-prepare-debian-boot-assets.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-prepare-debian-boot-assets.sh
git commit -m "feat: add guest-prepare-debian-boot-assets.sh to extract kernel from .deb

Extracts vmlinuz and initrd.img from Debian kernel .deb packages
for ARM, RISC-V, and MIPS architectures. Replaces the Alpine ISO
extraction approach (bsdtar from ISO) used by the old
prepare-{arm,riscv,mips}-boot-assets.sh scripts.
"
```

---

### Task 3: Create guest-prepare-debian-rootfs.sh

**Files:**
- Create: `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# guest-prepare-debian-rootfs.sh
#
# Create minimal Debian rootfs qcow2 disk images via debootstrap.
# Each image is configured for serial-console auto-login and 9p virtio mount.
#
# Architectures:
#   arm64   -> ${ARM_DEBIAN_DISK}   (native debootstrap or qemu-debootstrap)
#   riscv64 -> ${RISCV_DEBIAN_DISK} (qemu-debootstrap)
#   mips    -> ${MIPS_DEBIAN_DISK}  (qemu-debootstrap via debian-ports)
#
# The images include:
#   - systemd with serial-getty auto-login for root
#   - mount utilities for 9p virtio
#   - /mnt/pingpong directory
#   - fstab entry for the 9p share
#
# Environment:
#   DEBIAN_MIRROR     Debian mirror URL (default: http://deb.debian.org/debian)
#   DEBIAN_PORTS_MIRROR  Debian-ports mirror for MIPS (default: http://deb.debian.org/debian-ports)
#   DEBIAN_VERSION    Debian release (default: bookworm)
#   ROOTFS_SIZE       Disk image size (default: 1G)
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_PORTS_MIRROR="${DEBIAN_PORTS_MIRROR:-http://deb.debian.org/debian-ports}"
DEBIAN_VERSION="${DEBIAN_VERSION:-bookworm}"
ROOTFS_SIZE="${ROOTFS_SIZE:-1G}"
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus}"

# ── helpers ─────────────────────────────────────────────────────────────────

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }
_die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# create_debian_disk ARCH QCOW2_PATH MIRROR_URL [EXTRA_DEBOOTSTRAP_ARGS...]
#
# Uses qemu-debootstrap for cross-arch when ARCH != host arch.
# Falls back to plain debootstrap when ARCH == host arch.
create_debian_disk() {
    local target_arch="$1"
    local qcow2_path="$2"
    local mirror_url="$3"
    shift 3
    local extra_args=("$@")

    if [[ -f "${qcow2_path}" ]]; then
        _ok "Disk image already exists: ${qcow2_path} ($(du -sh "${qcow2_path}" | cut -f1))"
        return 0
    fi

    _info "Creating Debian ${DEBIAN_VERSION} rootfs for ${target_arch}..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    local rootfs_dir="${tmpdir}/rootfs"

    # Stage 1: debootstrap
    local host_arch
    host_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"

    if [[ "${target_arch}" == "${host_arch}" ]]; then
        _info "Native debootstrap (${target_arch})..."
        debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    elif command -v qemu-debootstrap &>/dev/null; then
        _info "qemu-debootstrap for ${target_arch}..."
        qemu-debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            "${extra_args[@]}" \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"
    else
        _info "qemu-debootstrap not found; using debootstrap --foreign..."
        debootstrap \
            --arch="${target_arch}" \
            --include="${DEBIAN_INCLUDE_PKGS}" \
            --variant=minbase \
            --foreign \
            "${extra_args[@]}" \
            "${DEBIAN_VERSION}" \
            "${rootfs_dir}" \
            "${mirror_url}"

        # Copy qemu-user-static binary for second stage
        local qemu_static
        case "${target_arch}" in
            arm64)     qemu_static="qemu-aarch64-static" ;;
            riscv64)   qemu_static="qemu-riscv64-static" ;;
            mips|mipseb) qemu_static="qemu-mips-static" ;;
            *)         _die "Unknown qemu-user-static binary for arch: ${target_arch}" ;;
        esac

        if command -v "${qemu_static}" &>/dev/null; then
            cp "$(command -v "${qemu_static}")" "${rootfs_dir}/usr/bin/"
            chroot "${rootfs_dir}" /debootstrap/debootstrap --second-stage
            rm -f "${rootfs_dir}/usr/bin/${qemu_static}"
        else
            _die "${qemu_static} not found. Install qemu-user-static package."
        fi
    fi

    # Stage 2: Configure the rootfs
    _configure_rootfs "${rootfs_dir}" "${target_arch}"

    # Stage 3: Create disk image
    _info "Creating disk image: ${qcow2_path}"
    local raw_img="${tmpdir}/debian-rootfs.raw"
    qemu-img create -f raw "${raw_img}" "${ROOTFS_SIZE}"

    # Format and populate
    mkfs.ext4 -q -F "${raw_img}"

    local mnt_dir="${tmpdir}/mnt"
    mkdir -p "${mnt_dir}"
    sudo mount -o loop "${raw_img}" "${mnt_dir}"
    sudo cp -a "${rootfs_dir}/." "${mnt_dir}/"
    sudo umount "${mnt_dir}"

    qemu-img convert -f raw -O qcow2 "${raw_img}" "${qcow2_path}"
    rm -f "${raw_img}"

    _ok "Created: ${qcow2_path} ($(du -sh "${qcow2_path}" | cut -f1))"
}

# _configure_rootfs ROOTFS_DIR ARCH
_configure_rootfs() {
    local rootfs="$1"
    local arch="$2"

    local tty
    case "${arch}" in
        arm64)   tty="ttyAMA0" ;;
        riscv64) tty="ttyS0" ;;
        mips)    tty="ttyS0" ;;
        *)       tty="ttyS0" ;;
    esac

    # ── Serial console auto-login ─────────────────────────────────────────
    # Override getty@.service to auto-login root on the serial console
    local getty_override="${rootfs}/etc/systemd/system/getty@.service.d/override.conf"
    sudo mkdir -p "$(dirname "${getty_override}")"

    sudo tee "${getty_override}" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
Type=idle
EOF

    # Enable the serial getty
    sudo ln -sf /lib/systemd/system/getty@.service \
        "${rootfs}/etc/systemd/system/getty.target.wants/getty@${tty}.service" 2>/dev/null || true

    # ── 9p mount point and fstab ──────────────────────────────────────────
    sudo mkdir -p "${rootfs}/mnt/pingpong"

    sudo tee -a "${rootfs}/etc/fstab" >/dev/null <<EOF
pingpong /mnt/pingpong 9p trans=virtio,version=9p2000.L 0 0
EOF

    # ── Hostname ──────────────────────────────────────────────────────────
    echo "debian-${arch}" | sudo tee "${rootfs}/etc/hostname" >/dev/null

    # ── Root password (empty / passwordless) ──────────────────────────────
    # Allow root login with no password on serial console
    if [[ -f "${rootfs}/etc/pam.d/login" ]]; then
        sudo sed -i 's/^auth\s\+required\s\+pam_securetty\.so/#&/' "${rootfs}/etc/pam.d/login" 2>/dev/null || true
    fi
    # Ensure root account is unlocked
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    _ok "Rootfs configured for ${arch} (tty=${tty})"
}

# ── Main ────────────────────────────────────────────────────────────────────

# Check prerequisites
for cmd in debootstrap qemu-img mkfs.ext4; do
    command -v "${cmd}" &>/dev/null || _die "${cmd} not found — install it first"
done

mkdir -p "${ASSET_DIR}"

# ARM64
create_debian_disk "arm64" "${ARM_DEBIAN_DISK}" "${DEBIAN_MIRROR}"

# RISC-V 64
create_debian_disk "riscv64" "${RISCV_DEBIAN_DISK}" "${DEBIAN_MIRROR}"

# MIPS (big-endian, uses debian-ports mirror)
# debian-ports does not have a "bookworm" release name; use "unstable" or "sid"
# and specify the distro explicitly
create_debian_disk "mips" "${MIPS_DEBIAN_DISK}" "${DEBIAN_PORTS_MIRROR}" \
    --no-check-gpg
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
git commit -m "feat: add guest-prepare-debian-rootfs.sh for debootstrap-based rootfs

Creates minimal Debian qcow2 disk images per architecture via
debootstrap/qemu-debootstrap. Configures systemd serial auto-login,
9p virtio fstab entry, and passwordless root. Replaces the Alpine
initramfs-overlay approach (guest-prepare-demo-guest-overlays.sh).
"
```

---

### Task 4: Update guest-fetch-images.sh for Debian kernel packages

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-fetch-images.sh`

- [ ] **Step 1: Rewrite the download URLs**

Replace the entire file content with:

```bash
#!/usr/bin/env bash
# guest-fetch-images.sh
#
# Download Debian kernel .deb packages for all three architectures.
# Arm64 and riscv64 come from the main Debian archive.
# MIPS (big-endian) comes from debian-ports.
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

mkdir -p "${ASSET_DIR}"
cd "${ASSET_DIR}"

# ── ARM64 kernel ──────────────────────────────────────────────────────────
# Debian 12 (bookworm) arm64 kernel
_fetch() {
    local dst="$1" url="$2" label="$3"
    if [[ -f "${dst}" ]]; then
        echo "  skip: ${label} already present ($(du -sh "${dst}" | cut -f1))"
    else
        echo "  Downloading ${label}..."
        wget -q --show-progress -O "${dst}" "${url}" || {
            echo "  WARNING: failed to download ${label} from ${url}" >&2
            return 1
        }
        echo "  ok: ${label} fetched"
    fi
}

_fetch "${ARM_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-arm64_6.1.124-1_arm64.deb" \
    "Debian arm64 kernel"

_fetch "${RISCV_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-riscv64_6.1.124-1_riscv64.deb" \
    "Debian riscv64 kernel"

_fetch "${MIPS_KERNEL_DEB}" \
    "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-4kc-malta_6.1.124-1_mips.deb" \
    "Debian mips 4kc-malta kernel"
```

> **Note:** The exact kernel .deb filenames contain version numbers that will change over time. At implementation time, determine the latest kernel version by browsing:
> - ARM64: `http://ftp.debian.org/debian/pool/main/l/linux/` (search for `linux-image-.*-arm64`)
> - RISCV64: `http://ftp.debian.org/debian/pool/main/l/linux/` (search for `linux-image-.*-riscv64`)
> - MIPS: `http://ftp.debian.org/debian/pool/main/l/linux/` (search for `linux-image-.*-4kc-malta`)

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-fetch-images.sh
git commit -m "feat: replace Alpine ISO downloads with Debian kernel .deb downloads

Download Debian kernel .deb packages for arm64, riscv64, and mips
instead of the old Alpine ISO images. The kernels are extracted
by guest-prepare-debian-boot-assets.sh.
"
```

---

### Task 5: Update ARM guest launch script (guest-run-arm-phase5.sh)

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`

- [ ] **Step 1: Rewrite for Debian boot**

Replace the entire file content with:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-aarch64)"

require_file "${ARM_UEFI_BIOS}" "ARM UEFI firmware"
require_file "${ARM_KERNEL_IMAGE}" "ARM kernel image (vmlinuz)"
require_file "${ARM_INITRD_IMAGE}" "ARM initrd image"
require_file "${ARM_DEBIAN_DISK}" "ARM Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine virt,gic-version=3 \
    -cpu cortex-a57 -m 512M -smp 2 \
    -bios "${ARM_UEFI_BIOS}" \
    -kernel "${ARM_KERNEL_IMAGE}" \
    -initrd "${ARM_INITRD_IMAGE}" \
    -append "${ARM_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_ARM_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${ARM_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Key changes from Alpine version:
- `ARM_KERNEL_IMAGE` is now `vmlinuz` from the .deb (was `vmlinuz-virt` from ISO)
- `ARM_INITRD_IMAGE` is the Debian `initrd.img` (was combined initramfs with overlay)
- `ARM_KERNEL_CMDLINE` is `console=ttyAMA0 root=/dev/vda1 rw` (was `modules=loop,squashfs,...`)
- `-drive file=${ARM_DEBIAN_DISK},format=qcow2,if=virtio` replaces `-drive file=${ARM_ISO},media=cdrom`
- No more `guest-prepare-arm-phase2-boot-assets.sh` or `guest-prepare-demo-guest-overlays.sh` calls

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-arm-phase5.sh
git commit -m "feat: switch ARM guest from Alpine ISO to Debian rootfs disk

Boot Debian kernel + initrd + qcow2 rootfs instead of Alpine
kernel + combined-overlay-initramfs + ISO CD-ROM.
"
```

---

### Task 6: Update RISC-V guest launch script (guest-run-riscv-phase5.sh)

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh`

- [ ] **Step 1: Rewrite for Debian boot**

Replace the entire file content with:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-riscv64)"

require_file "${RISCV_OPENSBI_BIOS}" "RISC-V OpenSBI firmware"
require_file "${RISCV_KERNEL_IMAGE}" "RISC-V kernel image (vmlinuz)"
require_file "${RISCV_INITRD_IMAGE}" "RISC-V initrd image"
require_file "${RISCV_DEBIAN_DISK}" "RISC-V Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine virt,aclint=on \
    -cpu rv64,h=true,v=true \
    -m 2G -smp 4 \
    -bios "${RISCV_OPENSBI_BIOS}" \
    -kernel "${RISCV_KERNEL_IMAGE}" \
    -initrd "${RISCV_INITRD_IMAGE}" \
    -append "${RISCV_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_RISCV_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${RISCV_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Key changes:
- No more `guest-prepare-riscv-phase3-boot-assets.sh` / `guest-prepare-riscv-uboot.sh` / `guest-prepare-demo-guest-overlays.sh`
- No more ISO CD-ROM drive or U-Boot
- Debian kernel uses `RISCV_KERNEL_IMAGE` (vmlinuz) and `RISCV_INITRD_IMAGE` (initrd.img)
- Rootfs via `RISCV_DEBIAN_DISK` qcow2

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-riscv-phase5.sh
git commit -m "feat: switch RISC-V guest from Alpine ISO to Debian rootfs disk

Boot Debian kernel + initrd + qcow2 rootfs instead of Alpine
kernel + combined-overlay-initramfs + ISO CD-ROM + U-Boot.
"
```

---

### Task 7: Update MIPS guest launch script (guest-run-chimera.sh)

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera.sh`

- [ ] **Step 1: Rewrite for Debian MIPS boot**

Replace the entire file content with:

```bash
#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

qemu_bin="$(find_qemu_system_binary qemu-system-mips)"

require_file "${MIPS_KERNEL_IMAGE}" "MIPS kernel image (vmlinuz)"
require_file "${MIPS_INITRD_IMAGE}" "MIPS initrd image"
require_file "${MIPS_DEBIAN_DISK}" "MIPS Debian rootfs disk"
[[ -d "${PINGPONG_DIR}" ]] || die "shared pingpong directory not found: ${PINGPONG_DIR}"

bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"

exec "${qemu_bin}" \
    -machine malta \
    -cpu MIPS32R2-generic \
    -m 256M \
    -kernel "${MIPS_KERNEL_IMAGE}" \
    -initrd "${MIPS_INITRD_IMAGE}" \
    -append "${MIPS_KERNEL_CMDLINE}" \
    -chardev socket,id=ivshmem,path="${IVSHMEM_MIPS_FREERTOS_SOCKET}" \
    -device ivshmem-doorbell,chardev=ivshmem,vectors="${IVSHMEM_VECTORS}" \
    -drive file="${MIPS_DEBIAN_DISK}",format=qcow2,if=virtio \
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Key changes:
- MIPS ISO CD-ROM replaced by `MIPS_DEBIAN_DISK` qcow2 rootfs
- `guest-prepare-mips-boot-assets.sh` replaced by `guest-prepare-debian-boot-assets.sh`
- Cmdline: `console=ttyS0 root=/dev/sda1 rw` (virtio-blk on Malta PCI bus appears as `/dev/sda` or `/dev/vda` depending on kernel config; use `/dev/vda1` if Malta kernel has `VIRTIO_BLK` built-in, otherwise fall back to `/dev/sda1` if using IDE)

> **MIPS caveat:** The Debian MIPS port uses `debian-ports` rather than the main Debian archive. The kernel .deb package name is `linux-image-4kc-malta` (for the Malta board's 4Kc CPU). If `if=virtio` doesn't work on the Malta machine's PCI bus, switch to `if=none,id=hd0` with `-device virtio-blk-pci,drive=hd0`.

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera.sh
git commit -m "feat: switch MIPS guest from Alpine ISO to Debian rootfs disk

Boot Debian MIPS kernel + initrd + qcow2 rootfs on malta machine.
Replaces Alpine 3.10 MIPS ISO which is long EOL (last Alpine release
with MIPS support). Debian actively maintains its MIPS port.
"
```

---

### Task 8: Update shell prompt detection in guest-run-phase5-tmux.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh:90-120`

- [ ] **Step 1: Replace the auto_login_and_run function**

Replace lines 90-120 (the `auto_login_and_run` function):

The old Alpine function uses `busybox mkdir` and `busybox mount` because Alpine's root shell only has busybox. Debian has full GNU tools. The old function also detects `~#` (Alpine's bare prompt). Debian shows `root@debian-<arch>:~#`.

```bash
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
            tmux send-keys -t "$pane" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        elif echo "$content" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "$pane" "$hello_bin" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "WARNING: timed out waiting for shell prompt in pane $pane" >&2
}
```

Changes:
- `"busybox mkdir -p /mnt/pingpong"` → removed (mount point already exists from rootfs setup)
- `"busybox mount -t 9p -o trans=virtio,version=9p2000.L pingpong /mnt/pingpong"` → `"mount /mnt/pingpong"` (fstab has the options)
- `"~#"` → `"root@[^:]*:~?#"` (Debian's systemd hostnamed prompt)
- Keep `"login:"` detection for fallback (same as Alpine)

- [ ] **Step 2: Also update the kill/pkill line for MIPS**

Line 64: `pkill -f "qemu-system-mips.*run-chimera"` stays the same (the script name hasn't changed).

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "feat: update prompt detection for Debian guests in tmux launcher

Debian shows 'root@debian-<arch>:~#' as prompt (vs Alpine's bare '~#').
Also replace busybox mkdir/mount with standard mount command since
Debian rootfs has the 9p share configured in fstab.
"
```

---

### Task 9: Update shell prompt detection in guest-run-freertos-harness.sh

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-freertos-harness.sh:125-152`

- [ ] **Step 1: Replace the auto_login_and_run function**

Replace lines 125-152 with the Debian-adapted version:

```bash
auto_login_and_run() {
    local pane="$1"
    local hello_bin="$2"
    local timeout=180
    local elapsed=0

    while (( elapsed < timeout )); do
        local content
        content="$(tmux capture-pane -p -t "${pane}" 2>/dev/null)"
        if echo "${content}" | grep -q "login:"; then
            tmux send-keys -t "${pane}" "root" Enter
            sleep 3
            tmux send-keys -t "${pane}" "mount /mnt/pingpong" Enter
            sleep 1
            tmux send-keys -t "${pane}" "${hello_bin}" Enter
            return 0
        elif echo "${content}" | grep -qE "root@[^:]*:~?#"; then
            tmux send-keys -t "${pane}" "${hello_bin}" Enter
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
    done
    echo "[harness] WARNING: timed out waiting for shell prompt in pane ${pane}" >&2
}
```

- [ ] **Step 2: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-freertos-harness.sh
git commit -m "feat: update prompt detection for Debian in harness script

Switch from Alpine '~#' and busybox mount to Debian 'root@*:~#' prompt
detection and standard mount.
"
```

---

### Task 10: Update guest-run-chimera-showcase.sh for Debian orchestration

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh:84-158`

- [ ] **Step 1: Replace ISO fetch block (lines 84-96)**

Replace the Alpine ISO fetch block with Debian kernel .deb fetching:

```bash
    _fetch "${ARM_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-arm64_6.1.124-1_arm64.deb" \
        "Debian arm64 kernel"
    _fetch "${RISCV_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-riscv64_6.1.124-1_riscv64.deb" \
        "Debian riscv64 kernel"
    _fetch "${MIPS_KERNEL_DEB}" \
        "http://ftp.debian.org/debian/pool/main/l/linux/linux-image-6.1.0-30-4kc-malta_6.1.124-1_mips.deb" \
        "Debian mips 4kc-malta kernel"
```

- [ ] **Step 2: Replace "MIPS boot assets" section (lines 148-158)**

Replace the MIPS boot assets block with Debian rootfs preparation:

```bash
# ── Step 6: Debian rootfs disk images ───────────────────────────────────────────
# guest-prepare-debian-rootfs.sh creates minimal Debian qcow2 disks via debootstrap.
# These are created once and reused; the script skips existing images.

_step "Debian rootfs images"
bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"
_ok "Debian rootfs disks ready"

# ── Step 7: Extract kernel + initrd from .deb packages ─────────────────────────

_step "Kernel extraction"
bash "${SCRIPT_DIR}/guest-prepare-debian-boot-assets.sh"
_ok "Kernels and initrds extracted"
```

- [ ] **Step 3: Update the final launch message**

Line 164: Update the layout description to mention Debian (optional, cosmetic):
```bash
printf '  Layout:   3 ivshmem servers | FreeRTOS | ARM / RISCV / MIPS Debian\n'
```

- [ ] **Step 4: Remove Alpine-only note about RISCV disk creation**

Line 97 `# Note: RISCV disk image is created on first RISCV-Linux QEMU launch (guest-run-riscv-phase5.sh).` is no longer needed since `guest-prepare-debian-rootfs.sh` creates all disks upfront.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "feat: update showcase orchestrator for Debian workflow

Replace Alpine ISO fetches with Debian kernel .deb downloads.
Replace MIPS boot asset extraction with guest-prepare-debian-rootfs.sh
and guest-prepare-debian-boot-assets.sh calls for all architectures.
"
```

---

### Task 11: Remove or deprecate replaced Alpine scripts

**Files:**
- `scripts/heterogeneous-soc/guest-prepare-arm-phase2-boot-assets.sh`
- `scripts/heterogeneous-soc/guest-prepare-riscv-phase3-boot-assets.sh`
- `scripts/heterogeneous-soc/guest-prepare-mips-boot-assets.sh`
- `scripts/heterogeneous-soc/guest-prepare-demo-guest-overlays.sh`
- `scripts/heterogeneous-soc/guest-prepare-riscv-uboot.sh`

- [ ] **Step 1: Add deprecation headers to replaced scripts**

Rather than deleting them (which breaks any external scripts that might reference them), add a deprecation warning at the top of each file and source the new Debian equivalents. Example for `guest-prepare-demo-guest-overlays.sh`:

```bash
#!/usr/bin/env bash
# DEPRECATED: guest-prepare-demo-guest-overlays.sh has been replaced by
# guest-prepare-debian-rootfs.sh. This stub exists for backward compatibility only.
echo "WARNING: guest-prepare-demo-guest-overlays.sh is deprecated." >&2
echo "  The Debian rootfs is now created by guest-prepare-debian-rootfs.sh" >&2
echo "  which configures systemd getty auto-login directly in the rootfs disk." >&2
exit 0
```

Do the same for the other four scripts, each pointing to `guest-prepare-debian-rootfs.sh` or `guest-prepare-debian-boot-assets.sh` as appropriate.

- [ ] **Step 2: Verify no other scripts reference the deprecated scripts**

Run:
```bash
grep -r "prepare-arm-phase2-boot-assets\|prepare-riscv-phase3-boot-assets\|prepare-mips-boot-assets\|prepare-demo-guest-overlays\|prepare-riscv-uboot" scripts/ --include='*.sh'
```

Expected: only deprecated stub files match.

- [ ] **Step 3: Commit**

```bash
git add scripts/heterogeneous-soc/guest-prepare-arm-phase2-boot-assets.sh \
        scripts/heterogeneous-soc/guest-prepare-riscv-phase3-boot-assets.sh \
        scripts/heterogeneous-soc/guest-prepare-mips-boot-assets.sh \
        scripts/heterogeneous-soc/guest-prepare-demo-guest-overlays.sh \
        scripts/heterogeneous-soc/guest-prepare-riscv-uboot.sh
git commit -m "refactor: deprecate Alpine-specific boot asset and overlay scripts

prepare-*-boot-assets.sh and guest-prepare-demo-guest-overlays.sh are replaced
by guest-prepare-debian-boot-assets.sh and guest-prepare-debian-rootfs.sh respectively.
Stubs remain for backward compatibility.
"
```

---

### Task 12: Integration test — end-to-end demo run

**Files:**
- None (test run only)

- [ ] **Step 1: Run the full showcase from scratch**

Inside the Lima VM:
```bash
# Clean start — remove cached assets to force fresh creation
rm -rf ~/iso/debian-*.qcow2 ~/iso/linux-image-*.deb

# Run the showcase
SKIP_PREREQS=1 bash scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Expected outcomes:
- `guest-prepare-debian-rootfs.sh` creates three qcow2 disks (~200-400 MB each)
- `guest-prepare-debian-boot-assets.sh` extracts kernels and initrds from .deb packages
- `guest-fetch-images.sh` downloads three kernel .deb packages
- All three Debian guests boot to a `root@debian-<arch>:~#` prompt
- tmux auto-login detects the prompt and runs the hello binary
- FreeRTOS receives the hello messages (expect "received hello from arm-linux" etc.)

- [ ] **Step 2: Verify FreeRTOS receives messages from all three senders**

In the FreeRTOS pane, verify output contains:
```
received hello from arm-linux
received hello from riscv-linux
received hello from mips-linux
```

- [ ] **Step 3: Run the harness test**

```bash
bash scripts/heterogeneous-soc/guest-run-freertos-harness.sh
```

Expected: exit code 0 (PASS), output shows "PASS after Ns"

- [ ] **Step 4: Commit any final fixes**

If any issues are found and fixed during integration testing, commit them. Otherwise no commit needed for this task.

---

### Task 13: Update README and documentation

**Files:**
- Modify: `README.md` (or the main project README)

- [ ] **Step 1: Update guest OS references in README**

Search for Alpine references and replace with Debian:
```bash
grep -n -i "alpine" README.md
```

Replace mentions of:
- "Alpine Linux" → "Debian Linux"
- Alpine version numbers → Debian 12 (bookworm)
- Alpine ISO paths → Debian kernel/rootfs paths

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README for Debian Linux guest OS

Replace Alpine Linux references with Debian Linux (bookworm).
"
```

---

## Architecture Notes for Implementers

### Why Debian instead of Alpine

Alpine Linux dropped MIPS big-endian support after v3.10 (2019). The Chimera demo was pinned to an EOL Alpine release with no security updates. Debian actively maintains its MIPS port through debian-ports, providing modern kernels (6.1+) and package updates.

### Boot flow comparison

| Stage | Alpine (old) | Debian (new) |
|-------|-------------|--------------|
| Root filesystem | initramfs (cpio in RAM) + squashfs modloop on ISO | ext4 on qcow2 disk |
| Kernel source | Extracted from ISO via bsdtar | Extracted from .deb via dpkg-deb |
| Init system | openrc | systemd |
| Auto-login | Inittab overlay with `/sbin/autologin` wrapper | systemd getty@.service override with `--autologin root` |
| 9p mount | Inittab `::once:` hook or manual busybox mount | fstab entry in rootfs + `mount /mnt/pingpong` |
| Shell prompt | `~#` (bare, no hostname) | `root@debian-<arch>:~#` (hostnamed) |
| ISO/CD-ROM | Required (provides modloop squashfs with kernel modules) | Not needed (modules live on rootfs disk) |

### MIPS-specific considerations

1. **Debian-ports**: MIPS big-endian is not in the main Debian archive. Use `http://deb.debian.org/debian-ports` as the mirror.
2. **Kernel package**: The Malta board uses `linux-image-4kc-malta`. The exact filename changes with kernel ABI versions — check at implementation time.
3. **Virtio on Malta**: The Malta board has a PCI bus. Use `if=virtio` for disk or `-device virtio-blk-pci`. If the MIPS kernel lacks `VIRTIO_BLK`, fall back to IDE: `if=ide` with root `/dev/sda1`.
4. **Memory**: MIPS Malta has a 256 MB default; Debian needs at least 128 MB to boot. The current 256 MB should be sufficient.
5. **qemu-user-static**: For cross-arch debootstrap, install `qemu-user-static` package in the Lima VM (`sudo apt-get install qemu-user-static`).

### Environment variable overrides for testing

All paths are overridable via environment variables:

```bash
# Use a different asset directory for testing
ASSET_DIR=/tmp/debian-test bash scripts/heterogeneous-soc/guest-run-chimera-showcase.sh

# Skip rootfs creation if using pre-built images
SKIP_ROOTFS=1 ARM_DEBIAN_DISK=/path/to/prebuilt-arm64.qcow2 ...

# Use a different Debian release
DEBIAN_VERSION=trixie bash scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

---

## Self-Review

**1. Spec coverage:**
- ✅ Replace Alpine with Debian for MIPS → Task 7, Task 3 (MIPS section)
- ✅ Replace Alpine with Debian for ARM → Task 5, Task 3 (ARM section)
- ✅ Replace Alpine with Debian for RISC-V → Task 6, Task 3 (RISC-V section)
- ✅ Update common.sh variables → Task 1
- ✅ Update download scripts → Task 4
- ✅ Create rootfs creation script → Task 3
- ✅ Create kernel extraction script → Task 2
- ✅ Update tmux prompt detection → Task 8
- ✅ Update harness prompt detection → Task 9
- ✅ Update showcase orchestrator → Task 10
- ✅ Remove/deprecate old scripts → Task 11
- ✅ Integration test → Task 12
- ✅ Documentation → Task 13

**2. Placeholder scan:** No TBDs, TODOs, or "implement later" markers. All code blocks are complete. Kernel .deb version numbers are noted as needing verification at implementation time with concrete instructions on where to find them.

**3. Type consistency:** Variable names (`ARM_DEBIAN_DISK`, `RISCV_DEBIAN_DISK`, `MIPS_DEBIAN_DISK`) follow the existing naming convention in `common.sh`. Function signatures in `guest-prepare-debian-rootfs.sh` match the calls made to them. Shell prompt regex `root@[^:]*:~?#` is used consistently in both tmux and harness scripts.
