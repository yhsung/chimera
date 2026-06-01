Heterogeneous SoC Demo Assets
=============================

This directory contains the guest-side payload for the ARM + RISC-V
ivshmem demo described in ``docs/heterogeneous-soc-plan.md``:

* ``ivshmem_proto.h`` defines the shared-memory protocol layout.
* ``ping.c`` is the ARM-side sender.
* ``pong.c`` is the RISC-V-side responder.
* ``Makefile`` cross-compiles static guest binaries.

Build the payload inside the Lima guest after installing the cross
toolchains:

.. code-block:: bash

   cd ~/dev-projects/chimera/contrib/heterogeneous-soc
   make

The helper scripts in ``scripts/heterogeneous-soc/`` handle the host
bring-up steps from the plan: Lima provisioning, image downloads,
ivshmem server startup, QEMU launch commands, and guest-side binary
transfer.
