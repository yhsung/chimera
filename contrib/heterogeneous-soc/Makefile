# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Yuehhsin Sung

CC_ARM ?= aarch64-linux-gnu-gcc
CC_RISCV ?= riscv64-linux-gnu-gcc
CFLAGS ?= -O2 -Wall -Wextra -static

.PHONY: all clean

all: ping pong

ping: ping.c ivshmem_proto.h
	$(CC_ARM) $(CFLAGS) -o $@ ping.c

pong: pong.c ivshmem_proto.h
	$(CC_RISCV) $(CFLAGS) -o $@ pong.c

clean:
	rm -f ping pong
