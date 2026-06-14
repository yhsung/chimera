#!/usr/bin/env python3
#
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung
#

import argparse
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Locate the BAR2 resource for the first ivshmem PCI device."
    )
    parser.add_argument(
        "--sysfs-root",
        default="/sys/bus/pci/devices",
        help="PCI devices sysfs root (default: %(default)s)",
    )
    parser.add_argument(
        "--vendor-id",
        default="0x1af4",
        help="PCI vendor ID to match (default: %(default)s)",
    )
    parser.add_argument(
        "--resource-index",
        type=int,
        default=2,
        help="BAR resource index to print (default: %(default)s)",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    sysfs_root = Path(args.sysfs_root)

    if not sysfs_root.is_dir():
        print(f"Sysfs root does not exist: {sysfs_root}", file=sys.stderr)
        return 1

    for device_dir in sorted(sysfs_root.iterdir()):
        vendor_file = device_dir / "vendor"
        if not vendor_file.is_file():
            continue

        vendor_id = vendor_file.read_text(encoding="utf-8").strip()
        if vendor_id != args.vendor_id:
            continue

        resource_path = device_dir / f"resource{args.resource_index}"
        if not resource_path.exists():
            print(
                f"Matched {device_dir.name} but {resource_path.name} is missing",
                file=sys.stderr,
            )
            return 1

        print(resource_path)
        return 0

    print(
        f"No PCI device found under {sysfs_root} with vendor {args.vendor_id}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
