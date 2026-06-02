ARM + RISC-V heterogeneous SoC demo
-----------------------------------

This repository now includes a runnable scaffold for the
heterogeneous SoC plan described in ``docs/heterogeneous-soc-plan.md``.
The demo uses two QEMU instances connected through
``ivshmem-doorbell``:

* ARM guest: Linux running ``contrib/heterogeneous-soc/ping``
* RISC-V guest: Linux running ``contrib/heterogeneous-soc/pong``

The shared-memory protocol definition lives in
``contrib/heterogeneous-soc/ivshmem_proto.h`` and matches the 64 MiB
BAR2 layout from the plan.

Quick start
~~~~~~~~~~~

The helper scripts under ``scripts/heterogeneous-soc/`` are organized
by plan phase:

* Phase 1 host setup:

  * ``install-lima-host.sh``
  * ``install-lima-guest.sh``
  * ``build-ivshmem-tools.sh``
  * ``fetch-images.sh``
  * ``start-ivshmem-server.sh``
  * ``run-arm-phase1.sh``
  * ``run-riscv-phase1.sh``

* Phase 2 ARM security stack:

  * ``prepare-arm-phase2-boot-assets.sh``
  * ``run-arm-phase2.sh``

* Phase 3 RISC-V virtualization:

  * ``run-riscv-phase3.sh``

* Phase 4 cross-cluster ping/pong:

  * ``copy-pingpong.sh``
  * ``run-ping.sh``
  * ``run-pong.sh``
  * ``find_ivshmem_bar2.py``

Example flow inside the Lima guest:

.. code-block:: bash

   cd ~/dev-projects/chimera
   scripts/heterogeneous-soc/install-lima-guest.sh
   scripts/heterogeneous-soc/build-ivshmem-tools.sh
   scripts/heterogeneous-soc/build-pingpong.sh
   scripts/heterogeneous-soc/fetch-images.sh
   scripts/heterogeneous-soc/start-ivshmem-server.sh

Then launch the ARM and RISC-V guests in separate terminals with
``run-arm-phase1.sh`` and ``run-riscv-phase1.sh``. Once both guests are
reachable, build and copy the demo binaries:

.. code-block:: bash

   make -C contrib/heterogeneous-soc
   scripts/heterogeneous-soc/copy-pingpong.sh

Inside each guest, ``run-ping.sh`` and ``run-pong.sh`` will auto-detect
the ivshmem BAR2 path by scanning ``/sys/bus/pci/devices`` for the
``0x1af4`` vendor ID.

Verification checklist
~~~~~~~~~~~~~~~~~~~~~~

* ``lspci -v | grep -A6 1af4`` shows the ivshmem PCI function in both guests.
* ``python3 scripts/heterogeneous-soc/find_ivshmem_bar2.py`` prints a
  ``resource2`` path in both guests.
* ``/usr/local/bin/pong`` starts on RISC-V and waits for messages.
* ``/usr/local/bin/ping`` on ARM prints the round-trip time for each
  reply received from the RISC-V guest.

Runtime notes
~~~~~~~~~~~~~

The current Lima-validated bring-up differs from the original plan in a
few important ways:

* The AArch64 guest needs explicit UEFI firmware
  (``/usr/share/qemu-efi-aarch64/QEMU_EFI.fd``) for the Alpine virt ISO
  to boot cleanly on the serial console.
* Alpine's current RISC-V release flow uses a standard ISO plus a
  matching U-Boot bundle, not the older raw ``alpine-virt-*.img`` path
  from the original draft plan.
* The Lima mount of the macOS home directory is read-only inside the VM,
  so the helper scripts mirror the source tree into ``~/chimera-src``
  before building QEMU tools or the guest demo payload.
* On the tested Alpine kernels, direct ``dd`` reads from the ivshmem
  ``resource2`` sysfs file returned ``EIO`` even though the BAR was
  present and mmap access worked. The phase 4 ``ping``/``pong`` apps
  provide the stronger end-to-end validation path.
* The Phase 2 TF-A/Hafnium/OP-TEE stack now builds successfully in the
  Lima guest. The current launcher prefers a direct ``-kernel`` /
  ``-initrd`` boot flow extracted from the Alpine ISO, which matches the
  TF-A QEMU platform documentation better than treating the installer ISO
  as a raw block image.
* Building the TF-A-documented ``ArmVirtQemuKernel`` EDK2 payload inside
  Lima requires ``acpica-tools`` so that ``iasl`` is available.
* ``build-arm-secure-stack.sh`` now prefers a locally built
  ``~/edk2/Build/ArmVirtQemuKernel-AArch64/DEBUG_GCCNOLTO/FV/QEMU_EFI.fd``
  as ``BL33`` when it exists, and falls back to
  ``/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`` otherwise.
* The Phase 2 build now defaults to the cleaner SPMD plus secure
  partition packaging flow for QEMU: Hafnium is passed as ``BL32`` and
  OP-TEE is packaged through ``SP_LAYOUT_FILE`` instead of also being
  packed into ``BL32_EXTRA1`` and ``BL32_EXTRA2``. Set
  ``INCLUDE_OPTEE_BL32_EXTRAS=1`` to restore the older mixed packaging
  for debugging.
* ``build-arm-secure-stack.sh`` also accepts ``TFA_DEBUG=1`` and
  ``TFA_LOG_LEVEL=50`` to produce a TF-A debug build under
  ``build-tfa/qemu/debug``.
* The latest Lima smoke boots now need semihosting enabled from the
  TF-A build directory so that ``op-tee.pkg`` is reachable when BL2
  falls back from FIP to semihosting for ``SP_PKG1``. With that runtime
  path, the debug boot reaches BL31, accepts the SPM core manifest, and
  logs ``SPM Core init start.`` Enabling ``QEMU_USE_GIC_DRIVER=QEMU_GICV3``
  in the TF-A build, matching OP-TEE's GICv3 configuration, and booting
  QEMU with ``gic-version=3`` pushes the same Lima smoke boot into live
  Hafnium output, including ``Initializing Hafnium (SPMC)`` and its
  early memory-layout logs.
* For the current Lima/QEMU runtime, the Phase 2 launcher now defaults
  to ``PHASE2_QEMU_CPU=max,sme=off,sve=off``. That avoids later EL2
  faults in Hafnium's host timer and SIMD restore paths while keeping
  the ``max`` CPU model needed for S-EL2 bring-up. With the same
  runtime override plus the current host-timer workaround, the secure
  stack now reaches ``SPM Core init end.`` and BL31 starts its exit to
  the normal world.
* Rebuilding the secure stack against the local ``ArmVirtQemuKernel``
  ``QEMU_EFI.fd`` moves the same Lima runtime path farther again: the
  post-handoff serial console now shows live EDK2 output, reaches
  ``Booting 'Linux virt'``, and continues into Alpine/OpenRC startup.
