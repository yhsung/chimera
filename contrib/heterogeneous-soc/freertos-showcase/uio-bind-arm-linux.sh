#!/bin/sh
# uio-bind-arm-linux.sh
#
# Runs INSIDE the ARM-Linux QEMU guest (invoked from the auto-login bootstrap
# in guest-run-phase5-tmux.sh, NOT on the Lima host). Binds the ARM<->FreeRTOS
# ivshmem-doorbell PCI device (IVSHMEM0/syslog channel) to uio_pci_generic so
# that syslog-arm-linux can receive doorbell interrupts via /dev/uio0.
#
# Safe to run repeatedly. If uio_pci_generic is unavailable or no matching
# device is found, syslog-arm-linux falls back to busy-wait polling.

if modprobe uio_pci_generic 2>/dev/null; then
    echo "uio-bind: uio_pci_generic loaded"
else
    echo "uio-bind: uio_pci_generic unavailable, syslog-arm-linux will use poll fallback"
fi

# Find the syslog ivshmem-doorbell: a virtio-vendor (0x1af4) PCI device whose
# BAR2 does not start with a known non-syslog magic (STATS/BOOTLOG/CAN).
IVSHMEM_BDF=""
for d in /sys/bus/pci/devices/*/; do
    v=$(cat "${d}vendor" 2>/dev/null)
    [ "$v" != "0x1af4" ] && continue

    magic=$(dd if="${d}resource2" bs=4 count=1 2>/dev/null | od -An -tx4 | tr -d ' ')
    # Empty $magic means resource2 was unreadable (not yet mapped, permission
    # denied, etc.) - skip rather than letting it fall through to the default
    # case and be misidentified as the syslog channel.
    case "$magic" in
        ""|53544154|424c5447|cafecafe)
            continue
            ;;
        *)
            IVSHMEM_BDF=$(basename "$d")
            break
            ;;
    esac
done

if [ -n "$IVSHMEM_BDF" ]; then
    echo "uio-bind: binding ${IVSHMEM_BDF} to uio_pci_generic..."
    echo "uio_pci_generic" > "/sys/bus/pci/devices/${IVSHMEM_BDF}/driver_override" 2>/dev/null || true
    echo "${IVSHMEM_BDF}" > "/sys/bus/pci/drivers/uio_pci_generic/bind" 2>/dev/null || true

    # /dev/uio0 is the expected node because this is presumed to be the
    # first (and only) uio_pci_generic binding in the guest's lifecycle.
    if [ -e /dev/uio0 ]; then
        echo "uio-bind: ivshmem-doorbell UIO bound: ${IVSHMEM_BDF} (/dev/uio0 ready)"
    else
        echo "uio-bind: bind attempted on ${IVSHMEM_BDF} but /dev/uio0 not present, using poll fallback"
    fi
else
    echo "uio-bind: no ivshmem-doorbell found, syslog-arm-linux will use poll fallback"
fi
