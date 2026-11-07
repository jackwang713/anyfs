#!/bin/bash
# zombie-farm.sh — 僵尸数据诱发器 (幸存者模式)
# 原理: 反复"随机大小文件写满 -> 按比例滞留幸存者 -> 删其余"
#       幸存者滞留使擦除块内"有效页/无效页"混合, GC 被迫搬家,
#       比全删模式(整块无效, GC 免费擦除自愈)致病效率高数倍
# 用法: ./zombie-farm.sh [挂载点] [轮数] [幸存比例%]
#   例: ./zombie-farm.sh /Volumes/Ti600-ExFAT 3 60

set -u
TARGET="${1:-/Volumes/Ti600-ExFAT}"
ROUNDS="${2:-3}"
KEEP_PCT="${3:-40}"          # 每轮幸存比例 %, 加病用 60
DIR="$TARGET/farm"
SEED="$TARGET/.seed.bin"
LOG="$HOME/zombie-farm-$(date +%Y%m%d-%H%M).csv"

if ! mount | grep " on $TARGET " | grep -q exfat; then
    echo "错误: $TARGET 不是已挂载的 exFAT 卷, 拒绝运行"
    exit 1
fi

free_gb() { df -g "$TARGET" | tail -1 | awk '{print $4}'; }
now() { python3 -c 'import time;print(f"{time.time():.2f}")'; }

echo "round,file,size_mb,seconds,mb_per_s,free_gb" > "$LOG"
echo "日志: $LOG"

if [ ! -f "$SEED" ]; then
    echo "生成 1GB 随机种子..."
    dd if=/dev/urandom of="$SEED" bs=1m count=1024 2>/dev/null
fi

for round in $(seq 1 "$ROUNDS"); do
    echo "=== 第 $round/$ROUNDS 轮: 写满 (开始前剩余 $(free_gb)GB) ==="
    mkdir -p "$DIR"
    n=0
    while :; do
        free=$(free_gb)
        [ "$free" -lt 3 ] && break

        r=$((RANDOM % 100))
        if   [ $r -lt 70 ]; then size=$(( RANDOM % 57 + 8 ))
        elif [ $r -lt 95 ]; then size=$(( RANDOM % 385 + 128 ))
        else size=$(( RANDOM % 1024 + 1024 )); fi
        [ "$size" -gt $(( free * 1024 - 2048 )) ] && size=64

        t0=$(now)
        dd if="$SEED" of="$DIR/f${round}_${n}.bin" bs=1m count=$size 2>/dev/null
        t1=$(now)
        read sec mbps <<<$(awk "BEGIN{printf \"%.2f %.1f\", $t1-$t0, $size/($t1-$t0)}")
        echo "$round,$n,$size,$sec,$mbps,$free" >> "$LOG"

        n=$((n+1))
        if [ $((n % 50)) -eq 0 ]; then
            echo "  [$n 个文件] 最新 ${mbps} MB/s, 剩余 ${free}GB"
        fi
    done
    sync

    # 幸存者轮换: 按 KEEP_PCT 比例滞留, 其余删除
    keep=0; del=0
    for f in "$DIR"/*.bin; do
        [ -e "$f" ] || continue
        if [ $((RANDOM % 100)) -lt $KEEP_PCT ]; then
            keep=$((keep+1))
        else
            rm -f "$f"; del=$((del+1))
        fi
    done
    sync
    echo "=== 第 $round 轮结束: 留 $keep 删 $del, 幸存者占地 $(du -sm "$DIR" 2>/dev/null | cut -f1)MB ==="
done

# --- 确诊: 12GB 稳态写入测速 (每 1GB 一个数据点, 看尾部) ---
echo "=== 稳态测速 (12GB) ==="
T="$TARGET/.speedtest.bin"
rm -f "$T"
for i in $(seq 0 11); do
    t0=$(now)
    dd if="$SEED" of="$T" bs=1m count=1024 seek=$((i * 1024)) conv=notrunc 2>/dev/null
    t1=$(now)
    awk "BEGIN{printf \"  chunk %2d: %.1f MB/s\n\", $i, 1024/($t1-$t0)}" | tee -a "$LOG.speed"
done
rm -f "$T"
sync

echo "完成。速度日志: $LOG / 稳态曲线: $LOG.speed"
echo "幸存者仍在 $DIR —— 它们就是维持病情的钉子户, 抢救实验后再清"
