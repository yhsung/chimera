# CAN Bus Integration Design

**Date:** 2026-06-10
**Status:** Approved

## Goal

Connect ARM-Linux and FreeRTOS guests to a shared CAN bus so that a user on the Lima `qemu-dev` VM can send CAN frames with `can-utils` (`cansend`, `cangen`) and have both guests receive them. FreeRTOS forwards received frames via a dedicated ivshmem channel to ARM-Linux, which appends them to `/var/log/chimera-log/can-bus.log`.

## Architecture

```
Lima VM (Linux)
│
│  vcan0  (virtual CAN interface)
│    │
│    ├─ can-host-socketcan (ARM QEMU process)
│    │       │
│    │   can-bus0 (ARM QEMU internal)
│    │       └── kvaser_pci → can0 in ARM-Linux guest
│    │
│    └─ can-host-socketcan (FreeRTOS QEMU process)
│            │
│        can-bus0 (FreeRTOS QEMU internal)
│            └── xlnx-zynqmp-can @ 0x50000000, SPI 6
│                    │
│                ① UART print
│                ② write to IVSHMEM5 (new CAN channel)
│                            │
│                   ARM-Linux CAN log daemon
│                   → /var/log/chimera-log/can-bus.log
```

**Why vcan0 as the shared medium:** ARM-Linux and FreeRTOS run in separate QEMU processes. Each process has its own internal `can-bus` object. Both processes connect to Lima's `vcan0` via `can-host-socketcan`; the Linux kernel's vcan broadcasts all frames to every listener, achieving the same effect as a shared physical bus.

**Data flow (Lima sends a frame):**
1. `cansend vcan0 123#DEADBEEF` on Lima
2. Both QEMU processes receive the frame via their respective `can-host-socketcan`
3. ARM-Linux: `kvaser_pci` → `can0` → readable by any SocketCAN tool
4. FreeRTOS: `xlnx-zynqmp-can` RX ISR → UART print + IVSHMEM5 write
5. ARM-Linux CAN log daemon reads IVSHMEM5 → appends to `can-bus.log`

## Component Changes

### 1. QEMU Machine Definition

**`include/hw/arm/chimera_r52_freertos_demo.h`**

- Add `CHIMERA_R52_FREERTOS_CAN_MMIO` to the memmap enum
- Add `CHIMERA_R52_FREERTOS_CAN_SPI = 6` to the SPI enum (SPIs 0–5 already used)
- Add `#define CHIMERA_R52_FREERTOS_PROP_CANBUS "canbus"`
- Add `char *canbus_id` field to `ChimeraR52FreeRTOSMachineState`

**`hw/arm/chimera_r52_freertos_demo.c`**

- Add `[CHIMERA_R52_FREERTOS_CAN_MMIO] = { 0x50000000, 0x1000 }` to `chimera_r52_memmap[]`
- In `chimera_r52_machine_init()`: if `canbus_id` is set, resolve the `can-bus` object, instantiate `xlnx.zynqmp-can`, link it to the bus, map to `0x50000000`, connect IRQ to SPI 6
- In `chimera_r52_machine_class_init()`: register `canbus` as an optional string property (same pattern as existing ivshmem props); CAN is opt-in — machine starts without it if the property is absent
- Add `IVSHMEM5` entries for the CAN forwarding channel (memmap + SPI 7), following the same pattern as IVSHMEM4

**`include/hw/arm/chimera_r52_freertos_demo.h` — IVSHMEM5 additions**

- `CHIMERA_R52_FREERTOS_IVSHMEM5_MMIO` / `IVSHMEM5_SHMEM` in memmap enum
- `CHIMERA_R52_FREERTOS_IVSHMEM5_SPI = 7` (SPI 7 will be free after adding CAN on SPI 6)
- `CHIMERA_R52_FREERTOS_PROP_IVSHMEM_CAN "ivshmem-can-freertos"`
- `char *ivshmem_can_freertos` field in machine state
- Update `CHIMERA_R52_FREERTOS_GIC_NUM_IRQ` from 64 to 96 to accommodate SPI 7 (INTID 39)

### 2. Launch Scripts

**`guest-run-r52-freertos-phase5.sh`** — add:
```bash
-object can-bus,id=canbus0 \
-object can-host-socketcan,id=ch0,if=vcan0,canbus=canbus0 \
-chardev socket,id=canft,path="${IVSHMEM_CAN_FREERTOS_SOCKET}" \
```
And extend `-machine` line with `,canbus=canbus0,ivshmem-can-freertos=canft`

**`guest-run-arm-phase5.sh`** — add:
```bash
-object can-bus,id=canbus0 \
-object can-host-socketcan,id=ch0,if=vcan0,canbus=canbus0 \
-device kvaser_pci,canbus=canbus0 \
-chardev socket,id=ivshmem_can,path="${IVSHMEM_CAN_FREERTOS_SOCKET}" \
-device ivshmem-doorbell,chardev=ivshmem_can,vectors="${IVSHMEM_VECTORS}" \
```

**`scripts/heterogeneous-soc/guest-start-ivshmem-server-can-freertos.sh`** — new script, copy of `guest-start-ivshmem-server-stats.sh` with `IVSHMEM_CAN_FREERTOS_DIR`.

**`scripts/heterogeneous-soc/common.sh`** — add:
```bash
IVSHMEM_CAN_FREERTOS_DIR="${IVSHMEM_CAN_FREERTOS_DIR:-/tmp/ivshmem-can-freertos}"
IVSHMEM_CAN_FREERTOS_SOCKET="${IVSHMEM_CAN_FREERTOS_DIR}/ivshmem_socket"
```

**`guest-run-chimera-showcase.sh`** — add ivshmem-can-freertos server launch and Lima vcan0 setup before QEMU guests start.

### 3. FreeRTOS CAN Driver

**New files:**
- `contrib/heterogeneous-soc/freertos-showcase/can_driver.h`
- `contrib/heterogeneous-soc/freertos-showcase/can_driver.c`

**Register map** (from `hw/net/can/xlnx-zynqmp-can.c`):

| Offset | Name | Usage |
|--------|------|-------|
| 0x00 | SRR | bit1=CEN (controller enable), bit0=SRST |
| 0x04 | MSR | mode (normal/loopback/sleep) |
| 0x18 | SR | status |
| 0x1C | ISR | interrupt status |
| 0x20 | IER | interrupt enable |
| 0x24 | ICR | interrupt clear |
| 0x50 | RXFIFO_ID | received frame CAN ID |
| 0x54 | RXFIFO_DLC | data length code |
| 0x58 | RXFIFO_D1 | data bytes 0–3 |
| 0x5C | RXFIFO_D2 | data bytes 4–7 |

`CAN_ISR_RXOK = (1U << 4)`

**`can_init()`:**
1. `SRR = (1 << 1)` (CEN)
2. `IER |= CAN_ISR_RXOK`
3. Register ISR for GIC SPI 6 (INTID 38), following `freertos_ivshmem_flat.c` IRQ registration pattern

**`can_rx_isr()`:**
1. Verify `ISR & CAN_ISR_RXOK`
2. Read `RXFIFO_ID`, `RXFIFO_DLC`, `RXFIFO_D1`, `RXFIFO_D2`
3. `ICR |= CAN_ISR_RXOK`
4. UART printf: `CAN RX: id=0x%03x dlc=%d data=%02x %02x ...`
5. Pack into `struct can_ivshmem_frame`, write to IVSHMEM5 via `freertos_ivshmem_send` (new helper analogous to `freertos_ivshmem_send_ack`)

**IVSHMEM5 frame format (16 bytes):**
```c
struct can_ivshmem_frame {
    uint32_t magic;    /* 0xCAFECAFE */
    uint32_t id;       /* CAN ID (11-bit or 29-bit) */
    uint8_t  dlc;      /* 0–8 */
    uint8_t  pad[3];
    uint8_t  data[8];
};
```

**`freertos_main.c`:**
- Call `can_init()` in startup sequence (after ivshmem links are initialised)
- Add `can_ivshmem_link` using IVSHMEM5 base addresses

### 4. ARM-Linux CAN Log Daemon

**New file: `contrib/heterogeneous-soc/syslog-arm-linux/can_log.c`**

Single process, two threads:

**Thread 1 — SocketCAN reader:**
- `socket(PF_CAN, SOCK_RAW, CAN_RAW)`, bind to `can0`
- Blocking `read()` of `struct can_frame`
- Appends to log: `[timestamp] CAN/socketcan id=0x%03x dlc=%d data=%02x...`

**Thread 2 — IVSHMEM5 reader:**
- Poll IVSHMEM5 shared memory for `can_ivshmem_frame` with valid magic `0xCAFECAFE`
- Clear magic after reading (acknowledgement)
- Appends to log: `[timestamp] CAN/freertos id=0x%03x dlc=%d data=%02x...`

**Log file:** `/var/log/chimera-log/can-bus.log` (directory already exists)

**`guest-install-syslog-to-guests.sh`:** install `can_log` binary and `chimera-can-log.service` systemd unit to ARM-Linux guest (same pattern as `chimera-syslog.service`).

## ivshmem Channel Map (updated)

| Channel | MMIO | SHMEM | SPI | Purpose |
|---------|------|-------|-----|---------|
| IVSHMEM0 | 0x30000000 | 0x31000000 | 1 | ARM-Linux ↔ FreeRTOS syslog |
| IVSHMEM1 | 0x35000000 | 0x36000000 | 2 | RISCV-Linux ↔ FreeRTOS syslog |
| IVSHMEM2 | 0x3A000000 | 0x3B000000 | 3 | MIPS-Linux ↔ FreeRTOS syslog |
| IVSHMEM3 | 0x3F000000 | 0x40000000 | 4 | Stats FreeRTOS → ARM-Linux |
| IVSHMEM4 | 0x44000000 | 0x45000000 | 5 | Boot log |
| IVSHMEM5 | 0x49000000 | 0x4A000000 (64 KiB) | 7 | CAN frames FreeRTOS → ARM-Linux |

CAN controller: `xlnx-zynqmp-can` @ `0x50000000`, SPI 6 (INTID 38)

## Testing

1. Lima: `sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 up`
2. Start showcase: `guest-run-chimera-showcase.sh`
3. ARM-Linux guest: `ip link set can0 type can bitrate 500000 && ip link set can0 up`
4. Lima: `cansend vcan0 123#DEADBEEF`
5. Verify ARM-Linux `can0` receives frame via `candump can0`
6. Verify FreeRTOS UART prints `CAN RX: id=0x123 dlc=4 data=de ad be ef`
7. Verify ARM-Linux `/var/log/chimera-log/can-bus.log` contains both `CAN/socketcan` and `CAN/freertos` entries
