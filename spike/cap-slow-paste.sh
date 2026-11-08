#!/bin/bash
# cap-slow-paste.sh — 慢速粘贴进行中运行, 抓写入者/写块大小/吞吐 (需 sudo)
# 用法: sudo ./cap-slow-paste.sh [秒数, 默认15]
SECS="${1:-15}"

# 1. 找写入者: lsof 查该卷上打开文件的进程
WRITER=$(lsof -nP 2>/dev/null | grep 'ti600-NTFS' | grep -v grep | awk '{print $1, $2}' | sort -u | head -5)
echo "=== 打开 ti600-NTFS 文件的进程 ==="
echo "$WRITER"
WPID=$(echo "$WRITER" | head -1 | awk '{print $2}')
[ -z "$WPID" ] && { echo "没找到写入者 (粘贴已结束?)"; exit 1; }

# 2. 对该进程采样文件系统调用
OUT=/tmp/paste-cap.txt
echo "采样 PID=$WPID ${SECS}s (保持粘贴进行中)..."
fs_usage -w -f filesys "$WPID" > "$OUT" 2>/dev/null &
FPID=$!
sleep "$SECS"
kill $FPID 2>/dev/null; sleep 1

echo "=== 写块大小分布 ==="
grep -io 'write[^ ]* *F=[0-9]* *B=0x[0-9a-f]*' "$OUT" | grep -o 'B=0x[0-9a-f]*' | sort | uniq -c | sort -rn | head -8

echo "=== 写吞吐估算 ==="
TOTAL=$(grep -io 'write[^ ]* *F=[0-9]* *B=0x[0-9a-f]*' "$OUT" | grep -o 'B=0x[0-9a-f]*' | sed 's/B=//' | awk '{s+=strtonum($1)} END {print s+0}')
awk -v b="$TOTAL" -v t="$SECS" 'BEGIN {printf "%.1f MB/s\n", b/1048576/t}'

echo "=== 该进程 read/write 次数比 ==="
echo "read: $(grep -c 'read' "$OUT")  write: $(grep -c 'write' "$OUT")"

echo "=== QEMU CPU 对照 ==="
ps -eo pcpu,args | grep [q]emu-system | awk '{print $1"%"}'
