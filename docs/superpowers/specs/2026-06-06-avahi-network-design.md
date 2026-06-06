# Avahi Network & Discovery for Linux Guests

**Date:** 2026-06-06
**Status:** Approved

## Goal

Enable L2 networking across all three Linux guests (ARM, RISCV, MIPS) and the Lima VM host, with Avahi mDNS discovery so every node can resolve the others by `.local` hostname and browse published services.

## Network Topology

```
Lima VM host  172.16.100.1
       |
  chbr0 (Linux bridge, 172.16.100.0/24)
       |
  +----+--------+----------+
  |             |          |
tap-arm      tap-riscv   tap-mips
  |             |          |
ARM guest    RISCV guest  MIPS guest
172.16.100.10  .11         .12
debian-arm64  debian-riscv64  debian-mipsel
```

mDNS multicast (224.0.0.251:5353) flows across the bridge as a flat L2 broadcast domain.

## IP Assignment

| Node            | Hostname          | IP              |
|-----------------|-------------------|-----------------|
| Lima VM host    | —                 | 172.16.100.1    |
| ARM guest       | debian-arm64      | 172.16.100.10   |
| RISCV guest     | debian-riscv64    | 172.16.100.11   |
| MIPS guest      | debian-mipsel     | 172.16.100.12   |

## Avahi Services Published per Guest

| Service type            | Port | Notes                           |
|-------------------------|------|---------------------------------|
| `_ssh._tcp`             | 22   | SSH on each guest               |
| `_chimera-syslog._tcp`  | 0    | txt-record `arch=<arch>`        |

## File Changes

### New: `scripts/heterogeneous-soc/guest-setup-network-bridge.sh`

Idempotent script run inside the Lima VM before any guest launches. Creates:
- Bridge `chbr0` with address 172.16.100.1/24
- TAP devices `tap-arm`, `tap-riscv`, `tap-mips` owned by the current user, attached to `chbr0`

Requires `sudo` (same privilege level already used by `guest-prepare-debian-rootfs.sh` and `guest-install-syslog-to-guests.sh`). Re-running is safe — all `ip` commands use `|| true` guards.

### Modified: `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`

Add to QEMU command line:
```
-netdev tap,id=net0,ifname=tap-arm,script=no,downscript=no
-device virtio-net-device,netdev=net0
```

### Modified: `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh`

Add to QEMU command line:
```
-netdev tap,id=net0,ifname=tap-riscv,script=no,downscript=no
-device virtio-net-device,netdev=net0
```

### Modified: `scripts/heterogeneous-soc/guest-run-chimera.sh`

Add to QEMU command line (malta uses PCI, not MMIO):
```
-netdev tap,id=net0,ifname=tap-mips,script=no,downscript=no
-device virtio-net-pci,netdev=net0
```

### Modified: `scripts/heterogeneous-soc/guest-prepare-debian-rootfs.sh`

**`DEBIAN_INCLUDE_PKGS`** — extend with:
```
avahi-daemon,libnss-mdns,iproute2,openssh-server
```

**`_configure_rootfs ROOTFS_DIR ARCH`** — add per-arch configuration:

1. Write `/etc/systemd/network/10-eth.network` with static IP (172.16.100.10/11/12 depending on arch):
   ```ini
   [Match]
   Name=e*

   [Network]
   Address=172.16.100.XX/24
   ```

2. Patch `/etc/nsswitch.conf` to enable mdns:
   ```
   hosts: files mdns4_minimal [NOTFOUND=return] dns
   ```

3. Write `/etc/avahi/services/ssh.service`:
   ```xml
   <?xml version="1.0" standalone='no'?>
   <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
   <service-group>
     <name replace-wildcards="yes">SSH on %h</name>
     <service>
       <type>_ssh._tcp</type>
       <port>22</port>
     </service>
   </service-group>
   ```

4. Write `/etc/avahi/services/chimera-syslog.service` with arch-specific txt-record:
   ```xml
   <?xml version="1.0" standalone='no'?>
   <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
   <service-group>
     <name replace-wildcards="yes">Chimera syslog on %h</name>
     <service>
       <type>_chimera-syslog._tcp</type>
       <port>0</port>
       <txt-record>arch=ARCH</txt-record>
     </service>
   </service-group>
   ```
   (`arch64`, `riscv64`, `mipsel` respectively)

5. Enable services via symlinks:
   ```
   /etc/systemd/system/multi-user.target.wants/avahi-daemon.service
   /etc/systemd/system/multi-user.target.wants/systemd-networkd.service
   ```

### Modified: `scripts/heterogeneous-soc/guest-run-chimera-showcase.sh`

Add a new step between the "Cleaning up stale processes" block and Step 1:

```bash
_step "Setting up network bridge"
_exec bash "${SCRIPT_DIR}/guest-setup-network-bridge.sh"
_ok "Bridge chbr0 and tap devices ready"
```

Also add a stale-image check: inspect `${ARM_DEBIAN_DISK}` via `qemu-nbd` for the presence of `/usr/sbin/avahi-daemon`; if missing, print a clear message instructing the user to delete the disk images and rerun.

### Modified: `scripts/heterogeneous-soc/guest-run-phase5-tmux.sh`

Same bridge-setup step added before the tmux session is created.

## Rebuild Requirement

Adding `avahi-daemon` to `DEBIAN_INCLUDE_PKGS` requires rebuilding all three disk images. `create_debian_disk` skips existing images, so users must delete the stale qcow2 files:

```bash
rm -f ~/iso/debian-arm64.qcow2 ~/iso/debian-riscv64.qcow2 ~/iso/debian-mips.qcow2
```

The showcase script will detect pre-Avahi images and print this instruction rather than silently booting guests without network.

## Error Handling

- Bridge setup failures (e.g., permission denied) are fatal — the showcase exits before launching guests.
- If a TAP device is already attached to the bridge from a prior run, the `ip tuntap add` command fails silently (`|| true`) and the existing device is reused.
- The MIPS guest uses `virtio-net-pci` (PCI bus) while ARM/RISCV use `virtio-net-device` (MMIO); this is consistent with how the existing disk (`-drive if=virtio`) is handled per machine type.

## Testing Approach

After implementation, validate end-to-end with:

1. From Lima host: `avahi-browse -at` — all three guests appear
2. From ARM guest: `ping -c1 debian-riscv64.local` — resolves and responds
3. From RISCV guest: `avahi-browse -rt _chimera-syslog._tcp` — ARM and MIPS entries visible
4. From MIPS guest: `ping -c1 debian-arm64.local` — resolves and responds
