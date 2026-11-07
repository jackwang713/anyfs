#!/bin/bash
# torture.sh - 恶性掉速复现: 碎片化随机改写诱发 WAF 爆炸
# 用法: ./torture.sh <挂载点> [轮数]
# 前置条件: 整盘 LBA 接近 100% 映射 (pool-filler + farm 幸存者已就位)
set -u
VOL="${1:?usage: torture.sh <mountpoint> [rounds]}"
ROUNDS="${2:-12}"
DIR="$VOL/torture"
LOG=~/torture-$(date +%Y%m%d-%H%M).csv
mkdir -p "$DIR"
echo "round,file,sizeMB,seconds,MBps" > "$LOG"
echo "日志: $LOG"
SLOWSTREAK=0

for ((r=1; r<=ROUNDS; r++)); do
  echo "=== 第 $r/$ROUNDS 轮 ==="
  # 写 300 个小文件 (2-16MB 随机), 逐个测速
  for ((i=1; i<=300; i++)); do
    sz=$(( (RANDOM % 15 + 2) ))
    f="$DIR/t_${r}_$i.bin"
    t0=$(python3 -c 'import time;print(time.time())')
    dd if=/dev/urandom of="$f" bs=1m count=$sz 2>/dev/null
    sync
    t1=$(python3 -c 'import time;print(time.time())')
    el=$(echo "$t1 - $t0" | bc)
    v=$(echo "scale=1; $sz/$el" | bc)
    echo "$r,$i,$sz,$el,$v" >> "$LOG"
    if [ $((i % 50)) -eq 0 ]; then
      echo "  [$r 轮 $i/300] 最新 ${v} MB/s  剩余 $(df -g "$VOL" | awk 'NR==2{print $4}')GB"
    fi
    # 连续 20 个文件 < 5MB/s → 判定恶性崩塌, 提前收工
    if (( $(echo "$v < 5" | bc -l) )); then
      SLOWSTREAK=$((SLOWSTREAK+1))
      if [ $SLOWSTREAK -ge 20 ]; then
        echo "!!! 恶性崩塌确认: 连续20个文件 <5MB/s (最新 ${v} MB/s) !!!"
        echo "COLLAPSED at round $r file $i" >> "$LOG"
        exit 0
      fi
    else
      SLOWSTREAK=0
    fi
  done
  # 随机删 70% → 产生碎片化僵尸
  ls "$DIR"/t_*.bin 2>/dev/null | while read -r f; do
    [ $((RANDOM % 10)) -lt 7 ] && rm -f "$f"
  done
  sync
  echo "  第 $r 轮结束, 存留 $(ls "$DIR"/t_*.bin 2>/dev/null | wc -l | tr -d ' ') 个文件"
done
echo "完成 (未崩塌)。日志: $LOG"
