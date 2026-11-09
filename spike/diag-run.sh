#!/bin/bash
# diag-run.sh — 向运行中的 guest 注入性能诊断脚本 (需 sudo, 串口管道属 root)
# 用法: sudo ./diag-run.sh [guest内挂载点, 默认 /mnt/ext4]
M="${1:-/mnt/ext4}"
printf 'sh %s/diag.sh\n' "$M" > /tmp/anyfsd-serial.in
echo "已注入, 约 1 分钟后查看卷内 diag.txt"
