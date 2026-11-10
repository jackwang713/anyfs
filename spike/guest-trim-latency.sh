#!/bin/bash
# guest-trim-latency.sh — 测 UNMAP 生效延迟: 1MB 定点 fstrim 后轮询读回, 画归零时间曲线
# 背景: 167GB 全量 fstrim 后图案区 ~86s 才归零 — 疑似桥对 UNMAP 异步后台处理
# 本实验用 1MB 小批次隔离"固定延迟" vs "按量延迟": 固定延迟→也 ~80s; 按量→应秒级
# 用法: sudo ./guest-trim-latency.sh <分区> <共享名>   例: sudo ./guest-trim-latency.sh disk7s2 KIOXIA
# 注意: 测试期间不要点 anyFS UI 的任何按钮 (避免混入变量)
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2> <共享名>}"
SHARE="${2:?缺少共享名}"
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在"; exit 1; }
PIPE=/tmp/anyfsd-serial
RESULT=.trim-latency-result.txt
SCRIPT=.trim-latency-$$.sh

echo "== 1/4 埋图案 + 定位 =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
sync
LOCATE=$(python3 ./exfat-locate.py "/dev/r$PART" .deep-trim-pattern | tee /dev/stderr)
OFF=$(echo "$LOCATE" | sed -n 's/^LOCATE-OFFSET=//p')
[ -n "$OFF" ] || { echo "FAIL: 定位失败"; rm -f "$VOL/.deep-trim-pattern"; exit 1; }

echo "== 2/4 guest: 删除 + 定点 fstrim 1MB =="
rm -f "$VOL/$RESULT"
cat > "$VOL/$SCRIPT" <<GUESTEOF
M=/mnt/$SHARE
rm -f \$M/.deep-trim-pattern
sync
fstrim -v -o $OFF -l 1048576 \$M >> \$M/$RESULT 2>&1
echo "DEEP:FSTRIM-DONE rc=\$?" >> \$M/$RESULT
rm -f \$M/$SCRIPT
GUESTEOF
printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
for i in $(seq 1 10); do
    sleep 3
    [ -f "$VOL/$RESULT" ] && grep -q "DEEP:FSTRIM-DONE" "$VOL/$RESULT" 2>/dev/null && break
done
grep -v "DEEP:" "$VOL/$RESULT" 2>/dev/null | sed 's/^/  /'

echo "== 3/4 每 5s 轮询读回 (最多 180s) =="
T0=$SECONDS
for i in $(seq 0 36); do
    [ "$i" -gt 0 ] && sleep 5
    OUT=$(./unmap-live "/dev/r$PART" --verify "$OFF")
    Z=$(echo "$OUT" | sed -n 's/.*zero=\([0-9]*\).*/\1/p')
    echo "T+$((SECONDS - T0))s: zero=$Z/1048576"
    [ "$Z" = "1048576" ] && { echo "VERDICT: TRIM-EXECUTED, 生效延迟 $((SECONDS - T0))s"; break; }
    [ "$i" = 36 ] && echo "VERDICT: 180s 未归零"
done

echo "== 4/4 清理 =="
rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
