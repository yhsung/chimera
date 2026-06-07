CC_ARM ?= aarch64-linux-gnu-gcc
CC_RISCV ?= riscv64-linux-gnu-gcc
CC_MIPS ?= mipsel-linux-gnu-gcc
CROSS_COMPILE ?= riscv64-unknown-elf-
CFLAGS_LINUX ?= -O2 -Wall -Wextra -static
FREERTOS_KERNEL_DIR ?= $(HOME)/heterogeneous-soc-freertos/FreeRTOS-Kernel
FREERTOS_PORT_DIR := $(FREERTOS_KERNEL_DIR)/portable/GCC/RISC-V
FREERTOS_PORT_CHIP_DIR := $(FREERTOS_PORT_DIR)/chip_specific_extensions/RISCV_MTIME_CLINT_no_extensions
CC_BARE ?= $(CROSS_COMPILE)gcc
OBJCOPY ?= $(CROSS_COMPILE)objcopy
CFLAGS_BARE ?= -O2 -Wall -Wextra -ffreestanding -fno-omit-frame-pointer \
	-march=rv64gc -mabi=lp64d -mcmodel=medany -msmall-data-limit=0 \
	-ffunction-sections -fdata-sections
LDFLAGS_BARE ?= -nostdlib -static -Wl,--gc-sections -T linker.ld -lgcc

# Build syslog-*-linux only when the Linux-targeting cross-compilers are available.
HAVE_CC_ARM   := $(shell command -v $(CC_ARM) 2>/dev/null)
HAVE_CC_RISCV := $(shell command -v $(CC_RISCV) 2>/dev/null)
HAVE_CC_MIPS  := $(shell command -v $(CC_MIPS) 2>/dev/null)

SYSLOG_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
SYSLOG_TARGETS += syslog-arm-linux linux-arm-stats
endif
ifneq ($(HAVE_CC_RISCV),)
SYSLOG_TARGETS += syslog-riscv-linux
endif
ifneq ($(HAVE_CC_MIPS),)
SYSLOG_TARGETS += syslog-mips-linux
endif

BOOTLOG_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
BOOTLOG_TARGETS += bootlog-arm-linux
endif
ifneq ($(HAVE_CC_RISCV),)
BOOTLOG_TARGETS += bootlog-riscv-linux
endif
ifneq ($(HAVE_CC_MIPS),)
BOOTLOG_TARGETS += bootlog-mips-linux
endif

BOOT_COLLECTOR_TARGETS :=
ifneq ($(HAVE_CC_ARM),)
BOOT_COLLECTOR_TARGETS += boot-collector
endif

FREERTOS_SRCS := \
	$(FREERTOS_KERNEL_DIR)/tasks.c \
	$(FREERTOS_KERNEL_DIR)/list.c \
	$(FREERTOS_KERNEL_DIR)/queue.c \
	$(FREERTOS_KERNEL_DIR)/portable/MemMang/heap_4.c \
	$(FREERTOS_PORT_DIR)/port.c \
	$(FREERTOS_PORT_DIR)/portASM.S

.PHONY: all clean

all: $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-riscv-demo.elf
ifeq ($(HAVE_CC_ARM),)
	$(warning CC_ARM=$(CC_ARM) not found — syslog-arm-linux, linux-arm-stats, bootlog-arm-linux, boot-collector skipped)
endif
ifeq ($(HAVE_CC_RISCV),)
	$(warning CC_RISCV=$(CC_RISCV) not found — syslog-riscv-linux, bootlog-riscv-linux skipped)
endif
ifeq ($(HAVE_CC_MIPS),)
	$(warning CC_MIPS=$(CC_MIPS) not found — syslog-mips-linux, bootlog-mips-linux skipped)
endif

syslog-arm-linux: linux_syslog.c hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"arm-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_ARM_LINUX \
	  -DHSOC_LOG_FILE='"/var/log/chimera-log/chimera-cross-domain.log"' \
	  -o $@ linux_syslog.c

linux-arm-stats: linux_stats.c stats_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) -o $@ linux_stats.c

syslog-riscv-linux: linux_syslog.c hello_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"riscv-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
	  -o $@ linux_syslog.c

syslog-mips-linux: linux_syslog.c hello_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"mips-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_MIPS_LINUX \
	  -o $@ linux_syslog.c

bootlog-arm-linux: bootlog_writer.c bootlog_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_ARM_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"arm-linux"' \
	  -o $@ bootlog_writer.c

bootlog-riscv-linux: bootlog_writer.c bootlog_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_RISCV_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"riscv-linux"' \
	  -o $@ bootlog_writer.c

bootlog-mips-linux: bootlog_writer.c bootlog_proto.h
	$(CC_MIPS) $(CFLAGS_LINUX) \
	  -DHSOC_BOOTLOG_GUEST=HSOC_GUEST_MIPS_LINUX \
	  -DHSOC_BOOTLOG_LABEL='"mips-linux"' \
	  -o $@ bootlog_writer.c

boot-collector: boot_collector.c bootlog_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) -o $@ boot_collector.c

freertos-riscv-demo.elf: freertos_main.c freertos_ivshmem_flat.c boot_log.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h stats_proto.h bootlog_proto.h boot_log.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  -I$(FREERTOS_PORT_CHIP_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c boot_log.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@

clean:
	rm -f $(SYSLOG_TARGETS) $(BOOTLOG_TARGETS) $(BOOT_COLLECTOR_TARGETS) freertos-riscv-demo.elf
