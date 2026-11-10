#!/bin/bash
# guest-trim-delta.sh — 定点 fstrim 失效的定性: QMP 计数器前后对比
# 背景: fstrim -o OFF -l 1M 报"1048576 bytes trimmed"但 180s 目标区不归零;
#       全量 fstrim 86s 归零 (有效)。本实验区分: 定点版是没发出 (delta=0) 还是发错地址 (delta>0)
# 用法: sudo ./guest-trim-delta.sh <分区> <共享名>   测试期间不要点 anyFS UI
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2> <共享名>}"
SHARE="${2:?缺少共享名}"
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在"; exit 1; }
PIPE=/tmp/anyfsd-serial
QMP=/tmp/anyfsd.qmp
RESULT=.trim-delta-result.txt
SCRIPT=.trim-delta-$$.sh

qmp_bytes() {
    ( echo '{"execute":"qmp_capabilities"}'; sleep 0.3; \
      echo '{"execute":"query-blockstats"}'; sleep 0.5 ) | nc -U "$QMP" | tail -1 \
      | python3 -c "import json,sys; s=json.load(sys.stdin)['return'][0]['stats']; print(s['unmap_bytes'], s['unmap_operations'], s['failed_unmap_operations'])"
}

echo "== 1/4 埋图案 + 定位 =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
sync
LOCATE=$(python3 ./exfat-locate.py "/dev/r$PART" .deep-trim-pattern | tee /dev/stderr)
OFF=$(echo "$LOCATE" | sed -n 's/^LOCATE-OFFSET=//p')
[ -n "$OFF" ] || { echo "FAIL: 定位失败"; rm -f "$VOL/.deep-trim-pattern"; exit 1; }

BEFORE=$(qmp_bytes)
echo "== 2/4 QMP 基线: unmap_bytes ops failed = $BEFORE =="

rm -f "$VOL/$RESULT"
cat > "$VOL/$SCRIPT" <<GUESTEOF
M=/mnt/$SHARE
rm -f \$M/.deep-trim-pattern
sync
fstrim -v -o $OFF -l 1048576 \$M >> \$M/$RESULT 2>&1
echo "DEEP:DONE" >> \$M/$RESULT
rm -f \$M/$SCRIPT
GUESTEOF
printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
for i in $(seq 1 10); do
    sleep 3
    [ -f "$VOL/$RESULT" ] && grep -q "DEEP:DONE" "$VOL/$RESULT" 2>/dev/null && break
done
grep -v "DEEP:" "$VOL/$RESULT" | sed 's/^/  /'

AFTER=$(qmp_bytes)
echo "== 3/4 QMP 之后: unmap_bytes ops failed = $AFTER =="
python3 - "$BEFORE" "$AFTER" <<'EOF'
import sys
b = [int(x) for x in sys.argv[1].split()]
a = [int(x) for x in sys.argv[2].split()]
db, do, df = a[0]-b[0], a[1]-b[1], a[2]-b[2]
print(f"DELTA: bytes={db} ops={do} failed={df}")
if do == 0:
    print("结论: 定点 fstrim 的 discard 根本没出 guest (exfat FITRIM 范围路径静默空转)")
elif db < 1048576:
    print(f"结论: 只发出了 {db} 字节 (<1MB), 范围被裁剪/对齐吃掉")
else:
    print("结论: discard 发出了但落在了错误的地址 (目标区不归零), exfat FITRIM 范围计算 bug")
EOF

echo "== 4/4 清理 (全量 fstrim 兜底) =="
rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
