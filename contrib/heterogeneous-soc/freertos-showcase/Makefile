CC_ARM ?= aarch64-linux-gnu-gcc
CC_RISCV ?= riscv64-linux-gnu-gcc
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
LDFLAGS_BARE ?= -nostdlib -static -Wl,--gc-sections -T linker.ld

HELLO_TARGETS := hello-arm-linux hello-riscv-linux
FREERTOS_SRCS := \
	$(FREERTOS_KERNEL_DIR)/tasks.c \
	$(FREERTOS_KERNEL_DIR)/list.c \
	$(FREERTOS_KERNEL_DIR)/queue.c \
	$(FREERTOS_KERNEL_DIR)/portable/MemMang/heap_4.c \
	$(FREERTOS_PORT_DIR)/port.c \
	$(FREERTOS_PORT_DIR)/portASM.S

.PHONY: all clean

all: $(HELLO_TARGETS) freertos-riscv-demo.elf

hello-arm-linux: linux_hello.c hello_proto.h
	$(CC_ARM) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"arm-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_ARM_LINUX \
	  -o $@ linux_hello.c

hello-riscv-linux: linux_hello.c hello_proto.h
	$(CC_RISCV) $(CFLAGS_LINUX) \
	  -DHSOC_SENDER_LABEL='"riscv-linux"' \
	  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
	  -o $@ linux_hello.c

freertos-riscv-demo.elf: freertos_main.c freertos_ivshmem_flat.c \
		freertos_ivshmem_flat.h freertos_libc.c startup.S linker.ld FreeRTOSConfig.h \
		hello_proto.h $(FREERTOS_SRCS)
	$(CC_BARE) $(CFLAGS_BARE) \
	  -I. \
	  -I$(FREERTOS_KERNEL_DIR)/include \
	  -I$(FREERTOS_PORT_DIR) \
	  -I$(FREERTOS_PORT_CHIP_DIR) \
	  startup.S freertos_main.c freertos_ivshmem_flat.c freertos_libc.c \
	  $(FREERTOS_SRCS) \
	  $(LDFLAGS_BARE) -o $@

clean:
	rm -f $(HELLO_TARGETS) freertos-riscv-demo.elf
