#!/bin/bash
# guest-trim-bisect.sh — 定位"大批量 UNMAP 被吞"的阈值: fstrim -o/-l 定点 vs 压小 discard_max_bytes
# 背景: 全量 fstrim (块层合并到 1GiB/条) 被桥静默吞; 宿主侧 1MB DKIOCUNMAP 却成功
# 实验A: 定点 fstrim -o OFF -l 1M → 小请求是否存活
# 实验B: echo 32M > discard_max_bytes 后全量 fstrim → 压小请求尺寸能否救活
# 安全性: FITRIM 只修剪空闲簇, 永远不碰已分配数据 (blkdiscard 已被弃用: busybox 版挂载中 O_EXCL 拒开)
# 用法: sudo ./guest-trim-bisect.sh <分区> <共享名>   例: sudo ./guest-trim-bisect.sh disk7s2 KIOXIA
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2> <共享名>}"
SHARE="${2:?缺少共享名}"
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在"; exit 1; }
PIPE=/tmp/anyfsd-serial
RESULT=.trim-bisect-result.txt
SCRIPT=.trim-bisect-$$.sh

echo "== 1/3 埋图案 32MB + 定位 =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
sync
LOCATE=$(python3 ./exfat-locate.py "/dev/r$PART" .deep-trim-pattern | tee /dev/stderr)
OFF=$(echo "$LOCATE" | sed -n 's/^LOCATE-OFFSET=//p')
RUNLEN=$(echo "$LOCATE" | sed -n 's/^LOCATE-RUNLEN=//p')
[ -n "$OFF" ] || { echo "FAIL: 定位失败"; rm -f "$VOL/.deep-trim-pattern"; exit 1; }
# 实验B 读回点: 连续段尾 1MB (必须在实验A已修剪的 1MB 之外, 否则假阳性); 段 <3MB 则跳过判决
if [ "${RUNLEN:-0}" -ge 3145728 ]; then
    PT2SKIP=$(( (OFF + RUNLEN - 1048576) / 512 )); EXPB=1
else
    PT2SKIP=0; EXPB=0
    echo "注意: 最长连续段 ${RUNLEN}B < 3MB, 实验B 只做不发判决"
fi

echo "== 2/3 生成 guest 实验脚本并注入 =="
rm -f "$VOL/$RESULT"
cat > "$VOL/$SCRIPT" <<GUESTEOF
#!/bin/sh
M=/mnt/$SHARE
exec > "\$M/$RESULT" 2>&1
DEV=\$(mount | grep " on \$M " | cut -d' ' -f1)
B=\$(basename \$DEV)
SKIP=$((OFF / 512))
echo "DEEP:SYS dev=\$DEV discard_max_bytes=\$(cat /sys/block/\$B/queue/discard_max_bytes) provisioning=\$(cat /sys/block/\$B/device/scsi_disk/*/provisioning_mode 2>/dev/null)"

readback() {  # \$1=skip(扇区) → 打印非零字节数 (先清缓存防假读)
    echo 3 > /proc/sys/vm/drop_caches
    dd if=\$DEV bs=512 skip=\$1 count=2048 iflag=direct 2>/dev/null | tr -d '\\000' | wc -c
}

echo "DEEP:PRECHECK non-0x5A=\$(dd if=\$DEV bs=512 skip=\$SKIP count=2048 iflag=direct 2>/dev/null | tr -d '\\132' | wc -c)"

# 实验A: 删除后定点 fstrim 1MB (小请求, 对标宿主侧成功案例)
rm -f \$M/.deep-trim-pattern
sync
fstrim -v -o $OFF -l 1048576 \$M 2>&1 | sed 's/^/DEEP:FSTRIM-1M /'
NZ=\$(readback \$SKIP)
[ "\$NZ" -eq 0 ] && echo "DEEP:VERDICT-1M TRIM-EXECUTED" || echo "DEEP:VERDICT-1M TRIM-SWALLOWED (非零 \$NZ)"

# 实验B: discard_max_bytes 1GiB→32MB, 全量 fstrim; 读回连续段尾 1MB (实验A 范围之外)
echo 33554432 > /sys/block/\$B/queue/discard_max_bytes
echo "DEEP:SYS discard_max_bytes 已压到 \$(cat /sys/block/\$B/queue/discard_max_bytes)"
fstrim -v \$M 2>&1 | sed 's/^/DEEP:FSTRIM-FULL /'
if [ "$EXPB" = "1" ]; then
    NZ=\$(readback $PT2SKIP)
    [ "\$NZ" -eq 0 ] && echo "DEEP:VERDICT-CAPPED TRIM-EXECUTED" || echo "DEEP:VERDICT-CAPPED TRIM-SWALLOWED (非零 \$NZ)"
else
    echo "DEEP:VERDICT-CAPPED SKIP (连续段不足 3MB, 无独立判决点)"
fi

rm -f "\$M/$SCRIPT"
GUESTEOF

printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
echo "已注入, 等待结果 (全量 fstrim 拆分后命令数暴增, 可能要几分钟)..."

echo "== 3/3 回收结果 =="
for i in $(seq 1 40); do
    sleep 15
    [ -f "$VOL/$RESULT" ] && grep -q "DEEP:VERDICT-CAPPED" "$VOL/$RESULT" 2>/dev/null && break
    printf '.'
done
echo
[ -f "$VOL/$RESULT" ] && cat "$VOL/$RESULT" || echo "FAIL: 超时, 手工查看 $VOL/$RESULT"
rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
