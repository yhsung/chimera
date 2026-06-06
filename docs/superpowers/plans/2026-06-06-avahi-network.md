# Avahi Network & Discovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add TAP/bridge L2 networking to all three Linux guests (ARM, RISCV, MIPS) and the Lima VM host, with Avahi mDNS so every node resolves `.local` hostnames and browses SSH + Chimera syslog services.

**Architecture:** A Linux bridge `chbr0` (172.16.100.0/24) created at showcase-launch time ties together three TAP devices (`tap-arm`, `tap-riscv`, `tap-mips`) — one per guest. Each guest gets a virtio NIC connected to its TAP. The Lima host holds the bridge address (172.16.100.1) and sits on the same L2 segment. Avahi and networking packages are baked into the Debian rootfs at debootstrap time; existing disk images must be deleted before the first run with this feature.

**Tech Stack:** Bash, QEMU TAP networking (`-netdev tap`), Linux bridge (`ip link`, `ip tuntap`), systemd-networkd (static IP), Avahi daemon, libnss-mdns, Debian debootstrap

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/heterogeneous-soc/guest-setup-network-bridge.sh` | **Create** | Idempotent: creates `chbr0` + 3 tap devices |
| `scripts/heterogeneous-soc/guest-run-arm-phase5.sh` | **Modify** | Add `-netdev tap,ifname=tap-arm` + `-device virtio-net-device` |
| `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh` | **Modify** | Add `-netdev tap,ifname=tap-riscv` + `-device virtio-net-device` |
| `scripts/heterogeneous-soc/guest-run-chimera.sh` | **Modify** | Add `-netdev tap,ifname=tap-mips` + `-device virtio-net-pci` |
| `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh` | **Modify** | Add avahi packages to debootstrap; configure static IP, NSS, avahi services in `_configure_rootfs` |
| `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh` | **Modify** | Add bridge-setup step + stale-image check |
| `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh` | **Modify** | Add bridge-setup step |

---

### Task 1: Bridge setup script

**Files:**
- Create: `scripts/heterogeneous-soc/guest-setup-network-bridge.sh`

- [ ] **Step 1: Verify the script doesn't exist yet**

```bash
ls scripts/heterogeneous-soc/guest-setup-network-bridge.sh 2>/dev/null \
    && echo "EXISTS — check before overwriting" \
    || echo "Not found — safe to create"
```

Expected: `Not found — safe to create`

- [ ] **Step 2: Create the bridge setup script**

```bash
cat > scripts/heterogeneous-soc/guest-setup-network-bridge.sh << 'EOF'
#!/usr/bin/env bash
# guest-setup-network-bridge.sh
#
# Creates bridge chbr0 (172.16.100.0/24) and tap-arm, tap-riscv, tap-mips
# devices inside the Lima VM so all three Linux guests share one L2 segment
# with the Lima host.  Avahi mDNS multicast flows across the bridge.
#
# Idempotent: safe to call on every showcase launch.
# Requires sudo (same privilege level as guest-prepare-debian-rootfs.sh).
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
    die "This script must run on Linux (inside the Lima VM)"
fi

BRIDGE_NAME="${CHIMERA_BRIDGE:-chbr0}"
BRIDGE_IP="${CHIMERA_BRIDGE_IP:-172.16.100.1/24}"

_ok()   { printf '\033[0;32m  ✓ %s\033[0m\n' "$*"; }
_info() { printf '  %s\n' "$*"; }

# Create bridge if it doesn't exist
if ! ip link show "${BRIDGE_NAME}" &>/dev/null; then
    _info "Creating bridge ${BRIDGE_NAME}..."
    sudo ip link add name "${BRIDGE_NAME}" type bridge
fi

# Assign IP if not already present
if ! ip addr show "${BRIDGE_NAME}" 2>/dev/null | grep -q "${BRIDGE_IP%%/*}"; then
    _info "Assigning ${BRIDGE_IP} to ${BRIDGE_NAME}..."
    sudo ip addr add "${BRIDGE_IP}" dev "${BRIDGE_NAME}" || true
fi

sudo ip link set "${BRIDGE_NAME}" up
_ok "Bridge ${BRIDGE_NAME} up (${BRIDGE_IP})"

# Create each TAP device, attach to bridge
for tap in tap-arm tap-riscv tap-mips; do
    if ! ip link show "${tap}" &>/dev/null; then
        _info "Creating TAP device ${tap}..."
        sudo ip tuntap add dev "${tap}" mode tap user "$(id -un)"
    fi
    # Attach to bridge if not already a bridge member
    if ! bridge link show 2>/dev/null | grep -q "\"${tap}\""; then
        sudo ip link set "${tap}" master "${BRIDGE_NAME}"
    fi
    sudo ip link set "${tap}" up
    _ok "${tap} up and attached to ${BRIDGE_NAME}"
done
EOF
chmod +x scripts/heterogeneous-soc/guest-setup-network-bridge.sh
```

- [ ] **Step 3: Verify the script is syntactically valid**

```bash
bash -n scripts/heterogeneous-soc/guest-setup-network-bridge.sh && echo "OK: syntax valid"
```

Expected: `OK: syntax valid`

- [ ] **Step 4: Commit**

```bash
git add scripts/heterogeneous-soc/guest-setup-network-bridge.sh
git commit -m "feat: add guest-setup-network-bridge.sh for chbr0 + TAP devices"
```

---

### Task 2: ARM guest networking

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`

- [ ] **Step 1: Verify the script currently has no -netdev line**

```bash
grep -c "netdev" scripts/heterogeneous-soc/guest-run-arm-phase5.sh \
    && echo "ALREADY HAS netdev — check before editing" \
    || echo "No netdev — safe to add"
```

Expected: `No netdev — safe to add`

- [ ] **Step 2: Insert TAP network device before -nographic**

The current last two lines of the `exec` block are:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Change them to:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-arm,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

Use the Edit tool with `old_string`:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```
and `new_string`:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-arm,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

- [ ] **Step 3: Verify the change**

```bash
grep -A2 "netdev" scripts/heterogeneous-soc/guest-run-arm-phase5.sh
```

Expected:
```
    -netdev tap,id=net0,ifname=tap-arm,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

- [ ] **Step 4: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-arm-phase5.sh && echo "OK: syntax valid"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-arm-phase5.sh
git commit -m "feat: add TAP networking to ARM guest (tap-arm, virtio-net-device)"
```

---

### Task 3: RISCV guest networking

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh`

- [ ] **Step 1: Verify no existing -netdev**

```bash
grep -c "netdev" scripts/heterogeneous-soc/guest-run-riscv-phase5.sh \
    && echo "ALREADY HAS netdev" || echo "No netdev — safe to add"
```

Expected: `No netdev — safe to add`

- [ ] **Step 2: Insert TAP network device before -nographic**

The current last two lines of the `exec` block are:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Change them to:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-riscv,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

- [ ] **Step 3: Verify the change**

```bash
grep -A2 "netdev" scripts/heterogeneous-soc/guest-run-riscv-phase5.sh
```

Expected:
```
    -netdev tap,id=net0,ifname=tap-riscv,script=no,downscript=no \
    -device virtio-net-device,netdev=net0 \
    -nographic
```

- [ ] **Step 4: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-riscv-phase5.sh && echo "OK: syntax valid"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-riscv-phase5.sh
git commit -m "feat: add TAP networking to RISCV guest (tap-riscv, virtio-net-device)"
```

---

### Task 4: MIPS guest networking

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera.sh`

Note: MIPS uses `-machine malta` which has a PCI bus, so use `virtio-net-pci` (not `virtio-net-device`).

- [ ] **Step 1: Verify no existing -netdev**

```bash
grep -c "netdev" scripts/heterogeneous-soc/guest-run-chimera.sh \
    && echo "ALREADY HAS netdev" || echo "No netdev — safe to add"
```

Expected: `No netdev — safe to add`

- [ ] **Step 2: Insert TAP network device before -nographic**

The current last two lines of the `exec` block are:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -nographic
```

Change them to:
```
    -virtfs local,path="${PINGPONG_DIR}",mount_tag="${PINGPONG_SHARE_TAG}",security_model=none,id="${PINGPONG_SHARE_TAG}" \
    -netdev tap,id=net0,ifname=tap-mips,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

- [ ] **Step 3: Verify the change**

```bash
grep -A2 "netdev" scripts/heterogeneous-soc/guest-run-chimera.sh
```

Expected:
```
    -netdev tap,id=net0,ifname=tap-mips,script=no,downscript=no \
    -device virtio-net-pci,netdev=net0 \
    -nographic
```

- [ ] **Step 4: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-chimera.sh && echo "OK: syntax valid"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera.sh
git commit -m "feat: add TAP networking to MIPS guest (tap-mips, virtio-net-pci)"
```

---

### Task 5: Rootfs packages + static IP + NSS config

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh`

This task adds avahi packages to the debootstrap include list and adds per-arch static IP + NSS configuration into `_configure_rootfs`. Task 6 adds the Avahi XML service files to the same function.

- [ ] **Step 1: Confirm current DEBIAN_INCLUDE_PKGS value**

```bash
grep "DEBIAN_INCLUDE_PKGS" scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

Expected:
```
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus,initramfs-tools,kmod,linux-base}"
```

- [ ] **Step 2: Extend DEBIAN_INCLUDE_PKGS with networking and Avahi packages**

Change:
```
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus,initramfs-tools,kmod,linux-base}"
```

To:
```
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus,initramfs-tools,kmod,linux-base,avahi-daemon,libnss-mdns,iproute2,openssh-server}"
```

- [ ] **Step 3: Verify the substitution**

```bash
grep "DEBIAN_INCLUDE_PKGS" scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

Expected:
```
DEBIAN_INCLUDE_PKGS="${DEBIAN_INCLUDE_PKGS:-systemd,systemd-resolved,udev,dbus,initramfs-tools,kmod,linux-base,avahi-daemon,libnss-mdns,iproute2,openssh-server}"
```

- [ ] **Step 4: Find the insertion point inside _configure_rootfs**

The function ends with this block (just before `_ok "Rootfs configured for ${arch}..."`):
```bash
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    _ok "Rootfs configured for ${arch} (tty=${tty})"
```

You will insert the network/NSS configuration between the shadow fix and the final `_ok` line.

- [ ] **Step 5: Insert static IP + NSS configuration into _configure_rootfs**

After the shadow fix block (ending `fi`) and before the `_ok "Rootfs configured"` line, insert:

```bash
    # ── Network: static IP via systemd-networkd ──────────────────────────────
    local guest_ip
    case "${arch}" in
        arm64)   guest_ip="172.16.100.10" ;;
        riscv64) guest_ip="172.16.100.11" ;;
        mipsel)  guest_ip="172.16.100.12" ;;
        *)       guest_ip="172.16.100.99" ;;
    esac

    sudo mkdir -p "${rootfs}/etc/systemd/network"
    sudo tee "${rootfs}/etc/systemd/network/10-eth.network" >/dev/null <<EOF
[Match]
Name=e*

[Network]
Address=${guest_ip}/24
EOF

    # ── NSS: .local mDNS resolution via libnss-mdns ──────────────────────────
    if [[ -f "${rootfs}/etc/nsswitch.conf" ]]; then
        sudo sed -i \
            's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' \
            "${rootfs}/etc/nsswitch.conf"
    else
        sudo tee "${rootfs}/etc/nsswitch.conf" >/dev/null <<'NSSEOF'
passwd:         files
group:          files
hosts:          files mdns4_minimal [NOTFOUND=return] dns
networks:       files
protocols:      db files
services:       db files
NSSEOF
    fi

    # ── Enable systemd-networkd ───────────────────────────────────────────────
    sudo mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        2>/dev/null || true
```

Use the Edit tool. The `old_string` is:
```
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    _ok "Rootfs configured for ${arch} (tty=${tty})"
```

The `new_string` is:
```
    if [[ -f "${rootfs}/etc/shadow" ]]; then
        sudo sed -i 's/^root:[^:]*:/root::/' "${rootfs}/etc/shadow"
    fi

    # ── Network: static IP via systemd-networkd ──────────────────────────────
    local guest_ip
    case "${arch}" in
        arm64)   guest_ip="172.16.100.10" ;;
        riscv64) guest_ip="172.16.100.11" ;;
        mipsel)  guest_ip="172.16.100.12" ;;
        *)       guest_ip="172.16.100.99" ;;
    esac

    sudo mkdir -p "${rootfs}/etc/systemd/network"
    sudo tee "${rootfs}/etc/systemd/network/10-eth.network" >/dev/null <<EOF
[Match]
Name=e*

[Network]
Address=${guest_ip}/24
EOF

    # ── NSS: .local mDNS resolution via libnss-mdns ──────────────────────────
    if [[ -f "${rootfs}/etc/nsswitch.conf" ]]; then
        sudo sed -i \
            's/^hosts:.*/hosts: files mdns4_minimal [NOTFOUND=return] dns/' \
            "${rootfs}/etc/nsswitch.conf"
    else
        sudo tee "${rootfs}/etc/nsswitch.conf" >/dev/null <<'NSSEOF'
passwd:         files
group:          files
hosts:          files mdns4_minimal [NOTFOUND=return] dns
networks:       files
protocols:      db files
services:       db files
NSSEOF
    fi

    # ── Enable systemd-networkd ───────────────────────────────────────────────
    sudo mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        2>/dev/null || true

    _ok "Rootfs configured for ${arch} (tty=${tty})"
```

- [ ] **Step 6: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh && echo "OK: syntax valid"
```

- [ ] **Step 7: Verify the static IP case statement is present**

```bash
grep -A6 "guest_ip" scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

Expected output includes lines like:
```
    case "${arch}" in
        arm64)   guest_ip="172.16.100.10" ;;
        riscv64) guest_ip="172.16.100.11" ;;
        mipsel)  guest_ip="172.16.100.12" ;;
```

- [ ] **Step 8: Commit**

```bash
git add scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
git commit -m "feat: add avahi/iproute2/openssh to rootfs, configure static IP and NSS"
```

---

### Task 6: Avahi service definitions + daemon enablement

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh` (continue in `_configure_rootfs`)

- [ ] **Step 1: Find the current state of _configure_rootfs after Task 5**

Confirm the `systemd-networkd` enable block was added:
```bash
grep "systemd-networkd.service" scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

Expected: a line containing `multi-user.target.wants/systemd-networkd.service`

- [ ] **Step 2: Insert Avahi service files + avahi-daemon enablement**

The insertion point is the same `_ok "Rootfs configured..."` line. Insert just before it (after the `systemd-networkd` symlink block).

Use the Edit tool. `old_string`:
```
    # ── Enable systemd-networkd ───────────────────────────────────────────────
    sudo mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        2>/dev/null || true

    _ok "Rootfs configured for ${arch} (tty=${tty})"
```

`new_string`:
```
    # ── Enable systemd-networkd ───────────────────────────────────────────────
    sudo mkdir -p "${rootfs}/etc/systemd/system/multi-user.target.wants"
    sudo ln -sf /lib/systemd/system/systemd-networkd.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
        2>/dev/null || true

    # ── Avahi service definitions ─────────────────────────────────────────────
    local avahi_arch
    case "${arch}" in
        arm64)   avahi_arch="arm64" ;;
        riscv64) avahi_arch="riscv64" ;;
        mipsel)  avahi_arch="mipsel" ;;
        *)       avahi_arch="unknown" ;;
    esac

    sudo mkdir -p "${rootfs}/etc/avahi/services"

    sudo tee "${rootfs}/etc/avahi/services/ssh.service" >/dev/null <<'XMLEOF'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">SSH on %h</name>
  <service>
    <type>_ssh._tcp</type>
    <port>22</port>
  </service>
</service-group>
XMLEOF

    sudo tee "${rootfs}/etc/avahi/services/chimera-syslog.service" >/dev/null <<XMLEOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Chimera syslog on %h</name>
  <service>
    <type>_chimera-syslog._tcp</type>
    <port>0</port>
    <txt-record>arch=${avahi_arch}</txt-record>
  </service>
</service-group>
XMLEOF

    # ── Enable avahi-daemon ───────────────────────────────────────────────────
    sudo ln -sf /lib/systemd/system/avahi-daemon.service \
        "${rootfs}/etc/systemd/system/multi-user.target.wants/avahi-daemon.service" \
        2>/dev/null || true

    _ok "Rootfs configured for ${arch} (tty=${tty})"
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh && echo "OK: syntax valid"
```

- [ ] **Step 4: Verify Avahi service files are present in the script**

```bash
grep "_chimera-syslog\|avahi-daemon.service\|avahi_arch" \
    scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
```

Expected: lines containing `_chimera-syslog._tcp`, `avahi-daemon.service`, and the `avahi_arch` case statement.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh
git commit -m "feat: write avahi SSH + chimera-syslog service files and enable avahi-daemon in rootfs"
```

---

### Task 7: Showcase integration — bridge step + stale-image check

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`

- [ ] **Step 1: Add bridge-setup step (before Step 1 in the script)**

The current text at lines 83–94 is:
```bash
_info "Cleaning up stale processes from prior runs..."
_exec pkill -f "qemu-system-riscv64.*freertos-riscv-demo" 2>/dev/null || true
_exec pkill -f "qemu-system-aarch64.*arm-phase5"           2>/dev/null || true
_exec pkill -f "qemu-system-riscv64.*riscv-phase5"         2>/dev/null || true
_exec pkill -f "qemu-system-mipsel.*run-chimera"           2>/dev/null || true
_exec pkill -x "ivshmem-server"                            2>/dev/null || true
sleep 0.3
_ok "stale processes cleaned"

# ── Step 1: apt prerequisites ─────────────────────────────────────────────────
```

Use Edit to change `_ok "stale processes cleaned"` ... `# ── Step 1:` to insert the bridge step between them.

`old_string`:
```
_ok "stale processes cleaned"

# ── Step 1: apt prerequisites ─────────────────────────────────────────────────
```

`new_string`:
```
_ok "stale processes cleaned"

# ── Step 0.5: Network bridge ──────────────────────────────────────────────────

_step "Setting up network bridge"
_exec bash "${SCRIPT_DIR}/guest-setup-network-bridge.sh"
_ok "Bridge chbr0 and TAP devices ready"

# ── Step 1: apt prerequisites ─────────────────────────────────────────────────
```

- [ ] **Step 2: Add stale-image detection function + check after Step 6 rootfs build**

The current Step 6 block is:
```bash
_step "Debian rootfs images"
_exec bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"
_ok "Debian rootfs disks ready"
```

`old_string`:
```
_step "Debian rootfs images"
_exec bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"
_ok "Debian rootfs disks ready"
```

`new_string`:
```
_step "Debian rootfs images"
_exec bash "${SCRIPT_DIR}/guest-prepare-debian-rootfs.sh"

# Detect disk images built before Avahi support was added.
_avahi_present_in_image() {
    local disk="$1"
    [[ -f "${disk}" ]] || return 0   # not yet built — will be created fresh
    local nbd_dev="/dev/nbd0" mnt result=0
    mnt="$(mktemp -d)"
    sudo modprobe nbd max_part=0 2>/dev/null || true
    if ! sudo qemu-nbd --connect="${nbd_dev}" "${disk}" 2>/dev/null; then
        rmdir "${mnt}"; return 0     # can't mount → allow through
    fi
    sleep 0.3
    if ! sudo mount "${nbd_dev}" "${mnt}" 2>/dev/null; then
        sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
        rmdir "${mnt}"; return 0
    fi
    [[ -f "${mnt}/usr/sbin/avahi-daemon" ]] || result=1
    sudo umount "${mnt}" 2>/dev/null || true
    sudo qemu-nbd --disconnect "${nbd_dev}" 2>/dev/null || true
    rmdir "${mnt}" 2>/dev/null || true
    return "${result}"
}

if ! _avahi_present_in_image "${ARM_DEBIAN_DISK}"; then
    die "Disk images predate Avahi support. Delete them to trigger a rebuild:
  rm -f '${ARM_DEBIAN_DISK}' '${RISCV_DEBIAN_DISK}' '${MIPS_DEBIAN_DISK}'
Then re-run this script."
fi
_ok "Debian rootfs disks ready"
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-chimera-showcase.sh && echo "OK: syntax valid"
```

- [ ] **Step 4: Verify both insertions**

```bash
grep -n "guest-setup-network-bridge\|_avahi_present_in_image\|predate Avahi" \
    scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Expected: three matching lines with appropriate line numbers.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
git commit -m "feat: add bridge-setup step and stale-image Avahi check to showcase launcher"
```

---

### Task 8: Phase5 tmux bridge step

**Files:**
- Modify: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`

- [ ] **Step 1: Find insertion point**

The bridge setup must run before guests are launched. The right place is after the stale QEMU process cleanup block (line 76: `sleep 0.5`) and before "Start ivshmem servers". The current text is:

```bash
sleep 0.5   # let the processes exit and release disk locks before QEMU restarts

# Start ivshmem servers; wait for all four sockets before launching guests.
```

- [ ] **Step 2: Insert bridge setup call**

`old_string`:
```
sleep 0.5   # let the processes exit and release disk locks before QEMU restarts

# Start ivshmem servers; wait for all four sockets before launching guests.
```

`new_string`:
```
sleep 0.5   # let the processes exit and release disk locks before QEMU restarts

# Set up network bridge and TAP devices for Avahi L2 networking.
bash "${SCRIPT_DIR}/guest-setup-network-bridge.sh"

# Start ivshmem servers; wait for all four sockets before launching guests.
```

- [ ] **Step 3: Verify script syntax**

```bash
bash -n scripts/heterogeneous-soc/guest-run-phase5-tmux.sh && echo "OK: syntax valid"
```

- [ ] **Step 4: Verify the insertion**

```bash
grep -n "guest-setup-network-bridge" scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
```

Expected: one line with the correct path.

- [ ] **Step 5: Commit**

```bash
git add scripts/heterogeneous-soc/guest-run-phase5-tmux.sh
git commit -m "feat: add bridge-setup step to phase5 tmux launcher"
```

---

### Task 9: End-to-end validation

This task runs inside the Lima VM after all code changes are committed and a fresh rootfs is built.

**Prerequisites:**
- All previous tasks committed
- Run inside Lima VM (`limactl shell qemu-dev`)
- Delete old disk images to force rebuild:
  ```bash
  rm -f ~/iso/debian-arm64.qcow2 ~/iso/debian-riscv64.qcow2 ~/iso/debian-mips.qcow2
  ```

- [ ] **Step 1: Build bridge and verify on Lima host**

```bash
bash ~/chimera-src/scripts/heterogeneous-soc/guest-setup-network-bridge.sh
ip addr show chbr0
```

Expected: `chbr0` shows `172.16.100.1/24` and `state UP`.

```bash
for tap in tap-arm tap-riscv tap-mips; do ip link show "$tap"; done
```

Expected: all three TAP devices show `master chbr0 state UP`.

- [ ] **Step 2: Launch the full showcase**

```bash
SKIP_BUILD=1 bash ~/chimera-src/scripts/heterogeneous-soc/guest-run-chimera-showcase.sh
```

Wait for all three Debian guests to reach their login prompts.

- [ ] **Step 3: Verify ARM guest has Avahi + IP from the Lima host**

From a separate Lima shell:
```bash
avahi-browse -at 2>/dev/null | grep "debian-arm64\|debian-riscv64\|debian-mipsel"
```

Expected: all three guest hostnames appear in the Avahi browse output.

- [ ] **Step 4: Verify cross-guest mDNS resolution**

In the ARM guest tmux pane (pane 5 of the `freertos-showcase` session):
```
ping -c1 debian-riscv64.local
```

Expected: `1 packets transmitted, 1 received, 0% packet loss`

- [ ] **Step 5: Verify Chimera syslog service is browseable**

From Lima host:
```bash
avahi-browse -rt _chimera-syslog._tcp
```

Expected: three entries, each with a `arch=` txt-record (`arm64`, `riscv64`, `mipsel`).

- [ ] **Step 6: Verify stale-image check triggers correctly**

On Lima host (don't rebuild — test with an image that lacks avahi):

The check only fires if `/usr/sbin/avahi-daemon` is absent in the ARM disk image. After a fresh build this passes. To test the failure path manually:

```bash
# Simulate a pre-Avahi image by removing avahi binary from a test copy
cp ~/iso/debian-arm64.qcow2 /tmp/test-stale.qcow2
sudo qemu-nbd --connect=/dev/nbd0 /tmp/test-stale.qcow2
mnt=$(mktemp -d); sudo mount /dev/nbd0 "$mnt"
sudo rm -f "$mnt/usr/sbin/avahi-daemon"
sudo umount "$mnt"; sudo qemu-nbd --disconnect /dev/nbd0; rmdir "$mnt"

ARM_DEBIAN_DISK=/tmp/test-stale.qcow2 \
    bash -c 'source scripts/heterogeneous-soc/guest-run-chimera-showcase.sh' 2>&1 | grep "predate"
```

Expected output contains: `Disk images predate Avahi support`

```bash
rm /tmp/test-stale.qcow2
```
