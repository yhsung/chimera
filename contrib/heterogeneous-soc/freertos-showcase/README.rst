Heterogeneous SoC FreeRTOS Showcase
===================================

This subtree builds the guest-side payloads for the three-guest
ARM/Linux + RISC-V/Linux -> RISC-V/FreeRTOS showcase.

* ``hello_proto.h`` defines the shared-memory protocol.
* ``linux_hello.c`` is compiled twice to produce the ARM/Linux and
  RISC-V/Linux sender binaries.
* ``freertos-riscv-demo.elf`` is the bare-metal FreeRTOS responder.

Build the Linux senders inside the Lima guest after installing the
cross toolchains:

.. code-block:: bash

   cd ~/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
   make hello-arm-linux hello-riscv-linux
