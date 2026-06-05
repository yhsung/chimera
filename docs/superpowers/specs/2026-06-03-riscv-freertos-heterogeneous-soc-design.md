# RISC-V FreeRTOS Heterogeneous SoC Showcase Design

## Goal

Add a new three-guest heterogeneous SoC showcase to this repository where:

- ARM/Linux sends `hello from arm-linux` with its timestamp to a RISC-V FreeRTOS guest
- RISC-V/Linux sends `hello from riscv-linux` with its timestamp to the same RISC-V FreeRTOS guest
- The RISC-V FreeRTOS guest logs both messages and replies to each sender with its own timestamp

The existing two-guest ARM/Linux ↔ RISC-V/Linux `ping`/`pong` showcase must remain available and unchanged as a separate mode.

## Scope

This design covers:

- the QEMU-side machine and device wiring needed for the new FreeRTOS guest
- the guest payload layout for the new Linux sender and FreeRTOS responder
- the script and documentation changes required to boot and demonstrate the new mode
- the protocol and verification model for the new three-guest showcase

This design does not cover:

- replacing the existing two-guest showcase
- a generalized multi-endpoint fabric for arbitrary guest topologies
- interrupt-first guest software on FreeRTOS in the first version
- production-grade recovery or retransmission semantics

## Approved Product Decisions

- The new FreeRTOS node is a separate third guest, not an extra hart inside the existing RISC-V Linux guest.
- The existing two-guest ARM/Linux ↔ RISC-V/Linux demo remains available.
- The new three-guest showcase uses two dedicated links:
  - ARM/Linux ↔ RISC-V/FreeRTOS
  - RISC-V/Linux ↔ RISC-V/FreeRTOS
- The FreeRTOS guest sends acknowledgments back to both Linux guests.
- The first version uses simple polling in guest software for correctness and easier bring-up.

## Architecture

### Existing mode

The current repository already supports a two-guest demo:

- ARM/Linux guest using PCI `ivshmem-doorbell`
- RISC-V/Linux guest using PCI `ivshmem-doorbell`
- one host-side ivshmem server
- one shared-memory region
- one userspace `ping`/`pong` protocol in `contrib/heterogeneous-soc/`

That mode remains the default reference for the current documentation and must continue working without behavior changes.

### New mode

The new mode adds a second showcase with three guests:

- ARM/Linux sender
- RISC-V/Linux sender
- RISC-V/FreeRTOS responder

The two Linux guests continue to use PCI `ivshmem-doorbell`, because that path is already proven in this repository.

The FreeRTOS guest uses two `ivshmem-flat` sysbus devices with fixed MMIO and shared-memory mappings. This is the right fit for an RTOS guest because:

- `ivshmem-flat` is intended for non-PCI and RTOS-style guests
- its register model matches the ivshmem spec closely
- it can communicate with the traditional PCI ivshmem device through the same ivshmem server protocol

The new showcase therefore has two separate host-side ivshmem links rather than one shared mailbox fabric.

## QEMU Machine Design

### Chosen approach

Add a small demo-specific RISC-V machine for the FreeRTOS guest instead of extending generic `hw/riscv/virt.c`.

Proposed machine artifacts:

- `hw/riscv/chimera_freertos_demo.c`
- `include/hw/riscv/chimera_freertos_demo.h`

Proposed machine name:

- `chimera-riscv-freertos-demo`

### Why a dedicated machine

A dedicated machine keeps the showcase-specific wiring local to one board model and avoids teaching the generic RISC-V `virt` machine about two special-purpose `ivshmem-flat` endpoints that only exist for this demo.

That keeps the change small in blast radius:

- existing Linux `virt` flows stay untouched
- `ivshmem-flat` remains wired only where it is needed
- the FreeRTOS guest gets stable MMIO and IRQ assignments controlled by the board

### FreeRTOS guest hardware model

The new machine should provide:

- 1 RISC-V hart
- 1 serial console for `-nographic` bring-up
- the minimum interrupt and timer blocks needed by the selected RISC-V FreeRTOS port
- 2 `ivshmem-flat` devices

Each `ivshmem-flat` device needs:

- one MMIO register window
- one MMIO shared-memory window
- one IRQ line connected into the guest interrupt controller
- its own ivshmem server chardev binding

Each link remains logically independent:

- link A serves ARM/Linux ↔ RISC-V/FreeRTOS
- link B serves RISC-V/Linux ↔ RISC-V/FreeRTOS

## Guest Payload Design

### Existing payloads

Keep the existing files as-is for the two-guest mode:

- `contrib/heterogeneous-soc/ivshmem_proto.h`
- `contrib/heterogeneous-soc/ping.c`
- `contrib/heterogeneous-soc/pong.c`
- `contrib/heterogeneous-soc/Makefile`

### New payloads

Add a new dedicated payload subtree for the FreeRTOS showcase:

- `contrib/heterogeneous-soc/freertos-showcase/`

Proposed contents:

- `hello_proto.h`
- `linux_hello.c`
- `freertos_main.c`
- `freertos_ivshmem_flat.h`
- `freertos_ivshmem_flat.c`
- `FreeRTOSConfig.h`
- `Makefile`
- `README.rst`

### Linux sender design

`linux_hello.c` is shared by both Linux sender builds.

Differences between ARM/Linux and RISC-V/Linux are injected through build flags or runtime arguments:

- sender label
- output binary name

Expected binaries:

- `hello-arm-linux`
- `hello-riscv-linux`

Behavior:

- map the PCI BAR2 shared-memory region
- write `HELLO` to the request channel
- wait for an `ACK` in the response channel
- print the outbound payload and the returned FreeRTOS timestamp

### FreeRTOS responder design

`freertos_main.c` boots the FreeRTOS application and services both links.

The first version should use one simple application task that:

- checks link A for new requests
- checks link B for new requests
- logs valid `HELLO` messages
- stamps the FreeRTOS reply timestamp
- writes back `ACK` messages on the same link

`freertos_ivshmem_flat.c` provides the small device-facing layer for:

- reading `ivshmem-flat` MMIO registers
- accessing the shared-memory region
- optionally issuing doorbells
- isolating MMIO offsets and volatile memory handling from the application code

## Protocol Design

The new showcase gets a new protocol definition rather than reusing the current `ping`/`pong` header.

### Message model

Each dedicated link has the same shared-memory layout:

- request channel: Linux sender → FreeRTOS
- response channel: FreeRTOS → Linux sender

Each message contains:

- `magic`
- `version`
- `msg_type`
- `seq`
- `sender_id`
- `ts_sec`
- `ts_nsec`
- fixed-size text payload

Proposed message types:

- `HELLO`
- `ACK`

Proposed sender identities:

- `ARM_LINUX`
- `RISCV_LINUX`
- `RISCV_FREERTOS`

### Shared-memory semantics

Each link keeps the same simple structure as the current demo:

- one flag per direction
- one payload struct per direction
- sender writes payload, applies a memory barrier, sets flag
- receiver polls flag, copies payload, clears flag, and responds

This keeps the logic familiar and makes the protocol easy to debug from console logs.

### Runtime sequence

For the ARM/Linux link:

1. ARM/Linux writes `HELLO(seq=n, sender=ARM_LINUX, text="hello from arm-linux")`
2. FreeRTOS polls the request flag
3. FreeRTOS logs the inbound message
4. FreeRTOS writes `ACK(seq=n, sender=RISCV_FREERTOS, ts=freertos_time)`
5. ARM/Linux reads the `ACK` and prints the returned timestamp

For the RISC-V/Linux link:

1. RISC-V/Linux writes `HELLO(seq=n, sender=RISCV_LINUX, text="hello from riscv-linux")`
2. FreeRTOS polls the request flag
3. FreeRTOS logs the inbound message
4. FreeRTOS writes `ACK(seq=n, sender=RISCV_FREERTOS, ts=freertos_time)`
5. RISC-V/Linux reads the `ACK` and prints the returned timestamp

The links are independent and can progress even if the other link is idle or misconfigured.

## Script And Demo Flow Design

### Existing scripts

The current scripts under `scripts/heterogeneous-soc/` stay in place for the existing two-guest flow.

### New scripts

Add a new Phase 5 style launch path for the FreeRTOS showcase.

Proposed scripts:

- `scripts/heterogeneous-soc/guest-start-ivshmem-server-arm-freertos.sh`
- `scripts/heterogeneous-soc/guest-start-ivshmem-server-riscv-freertos.sh`
- `scripts/heterogeneous-soc/guest-run-arm-phase5.sh`
- `scripts/heterogeneous-soc/guest-run-riscv-phase5.sh`
- `scripts/heterogeneous-soc/guest-run-riscv-freertos-phase5.sh`
- `scripts/heterogeneous-soc/guest-run-hello-arm.sh`
- `scripts/heterogeneous-soc/guest-run-hello-riscv.sh`

Optional integration:

- extend `scripts/heterogeneous-soc/host-ghostty-demo.sh` with a mode switch for `phase4-linux-linux` and `phase5-linux-freertos`

### Host-side link model

The new mode needs two separate ivshmem servers, one per dedicated link.

That means:

- two sockets
- two shared-memory backing regions
- one Linux PCI endpoint and one FreeRTOS flat endpoint connected to each server

This is intentionally different from the current single-server two-guest path.

## Documentation Design

Update the heterogeneous SoC documentation to describe two supported showcase modes.

Primary documentation updates:

- `docs/system/devices/heterogeneous-soc.rst`
- `contrib/heterogeneous-soc/README.rst`
- `docs/heterogeneous-soc-plan.md`

Documentation goals:

- preserve the current two-guest walkthrough
- add the new three-guest showcase as a new phase or alternate mode
- explain why Linux uses PCI ivshmem while FreeRTOS uses `ivshmem-flat`
- document the extra FreeRTOS toolchain and firmware build inputs

## Error Handling

The first version should prefer explicit failure over hidden retry loops.

### Linux sender failures

- if BAR2 cannot be found, print a clear error and exit
- if message validation fails, print the invalid fields and exit
- if `ACK` is not received before timeout, print the peer name and sequence number and exit by default

### FreeRTOS failures

- if one link receives an invalid `magic` or `version`, log the failure for that link and continue servicing the other link
- if one link is missing or silent, keep the other link alive
- if shared-memory state is malformed, prefer a visible log and channel-local recovery rather than silently resetting both links

## Verification Strategy

The new mode is complete when all of the following are true in one run.

### FreeRTOS guest bring-up

- the new QEMU machine boots to the FreeRTOS application banner on the serial console
- both `ivshmem-flat` endpoints are initialized and logged by the firmware

### Linux sender bring-up

- ARM/Linux prints that it sent `hello from arm-linux`
- RISC-V/Linux prints that it sent `hello from riscv-linux`

### End-to-end exchange

- ARM/Linux receives an `ACK` with a FreeRTOS timestamp
- RISC-V/Linux receives an `ACK` with a FreeRTOS timestamp
- FreeRTOS logs both inbound hellos and both outbound acknowledgments

### Regression protection

- rerun the current two-guest ARM/Linux ↔ RISC-V/Linux `ping`/`pong` flow
- confirm its scripts and documentation still work

### Optional host-side checks

- add a small protocol-layout test that asserts struct sizes and offsets for the new header
- add a log-based smoke test script that greps serial output for the expected `HELLO` and `ACK` lines

## Risks And Mitigations

### Risk: `ivshmem-flat` cannot be instantiated from the command line

Mitigation:

- wire it inside the new demo-specific machine rather than relying on user-creatable device plumbing

### Risk: generic `hw/riscv/virt.c` grows showcase-specific behavior

Mitigation:

- keep the FreeRTOS guest on its own machine

### Risk: two links create script complexity

Mitigation:

- keep the naming explicit and link-local
- avoid a generalized topology layer in the first version

### Risk: FreeRTOS interrupt-driven bring-up slows delivery

Mitigation:

- use polling first
- keep the board IRQ wiring in place so interrupt-driven handling can be added later without changing the guest-visible topology

## Recommended Implementation Order

1. Add the new RISC-V FreeRTOS demo machine with two wired `ivshmem-flat` endpoints.
2. Add the new protocol and Linux sender payloads.
3. Add the FreeRTOS responder firmware and its tiny `ivshmem-flat` driver layer.
4. Add the Phase 5 scripts for the two dedicated host-side links.
5. Update docs and verify the new mode without breaking the existing two-guest flow.
