#!/bin/bash
# diag-run.sh — 向运行中的 guest 注入性能诊断脚本 (需 sudo, 串口管道属 root)
# 用法: sudo ./diag-run.sh   然后看宿主侧 /Volumes/ti600-NTFS/diag.txt
printf 'sh /mnt/ti600-NTFS/diag.sh\n' > /tmp/anyfsd-serial.in
echo "已注入, 约 1-2 分钟后查看 /Volumes/ti600-NTFS/diag.txt"
