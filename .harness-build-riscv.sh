#!/bin/sh
set -e
cd /Users/yhsung/dev-projects/chimera/contrib/heterogeneous-soc/freertos-showcase
riscv64-linux-gnu-gcc -O2 -Wall -Wextra -static \
  '-DHSOC_SENDER_LABEL="riscv-linux"' \
  -DHSOC_SENDER_ID=HSOC_SENDER_RISCV_LINUX \
  -o /home/yhsung.guest/hello-riscv-linux linux_hello.c
echo "BUILD_OK"
file /home/yhsung.guest/hello-riscv-linux
