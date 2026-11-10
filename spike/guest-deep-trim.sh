#!/bin/bash
# guest-deep-trim.sh — anyFS guest TRIM 深度检测 (金标准, 分工修正版 v2)
#
# 分工: guest 只负责 sync/删除/fstrim (经串口注入);
#       定位/预校验/读回判决全部在宿主侧 F_NOCACHE 直读分区设备 —
#       教训: QEMU 在 macOS 无 O_DIRECT (源码降级为 O_DSYNC), guest 内 dd 读回
#       会命中宿主缓冲区里的旧图案 → 假阴性 (2026-11-10 实测踩坑)
# 流程: ① SMB 埋 32MB 图案 ② 宿主定位偏移 ③ guest sync 后宿主预校验图案在介质上
#       ④ guest 删除+fstrim ⑤ 宿主 F_NOCACHE 读回判决: 全零=EXECUTED 图案在=SWALLOWED
# 用法: sudo ./guest-deep-trim.sh <分区> <共享名>   例: sudo ./guest-deep-trim.sh disk7s2 KIOXIA
# 前提: anyFS 已接管该分区, App 侧 SMB 卷已挂载; Terminal.app (FDA) 里跑
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2> <共享名>}"
SHARE="${2:?缺少共享名}"
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在 (App 侧 SMB 挂载了吗?)"; exit 1; }
PIPE=/tmp/anyfsd-serial
RESULT=.deep-trim-result.txt
SCRIPT=.deep-trim-$$.sh
T0=$SECONDS

wait_marker() {  # $1=标记串 $2=超时秒
    for i in $(seq 1 $(( $2 / 3 ))); do
        sleep 3
        [ -f "$VOL/$RESULT" ] && grep -q "$1" "$VOL/$RESULT" 2>/dev/null && return 0
    done
    echo "FAIL: 等不到 $1 (${2}s 超时), 手工查看 $VOL/$RESULT"; exit 1
}

echo "== 1/5 经 SMB 埋图案: 32MB 0x5A =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
sync

echo "== 2/5 宿主侧定位 (只读解析 exFAT 元数据; 非 exFAT 回退扫描) =="
LOCATE=$(python3 ./exfat-locate.py "/dev/r$PART" .deep-trim-pattern 2>&1 | tee /dev/stderr)
OFF=$(echo "$LOCATE" | sed -n 's/^LOCATE-OFFSET=//p')
if [ -z "$OFF" ]; then
    # 回退: 整盘扫描 (unmap-live 扫最大 MS Basic Data 分区, NTFS 同 GUID 也覆盖).
    # 扫描返回整盘绝对偏移, 分区直通设备需减去分区起点 (LIVE-PART 行有 LBA 起点)
    PARENT=$(echo "$PART" | sed -E 's/s[0-9]+$//')
    echo "(非 exFAT, 回退扫描 $PARENT, 大分区需数分钟)"
    SCAN=$(./unmap-live "/dev/r$PARENT" --scan-only | tee /dev/stderr)
    ABS=$(echo "$SCAN" | sed -n 's/^LIVE-FOUND 图案块 @ 偏移 \([0-9]*\).*/\1/p')
    PLBA=$(echo "$SCAN" | sed -n 's/^LIVE-PART exFAT 分区: LBA \([0-9]*\)-.*/\1/p')
    [ -n "$ABS" ] && [ -n "$PLBA" ] && OFF=$((ABS - PLBA * 512))
fi
[ -n "$OFF" ] || { echo "FAIL: 定位失败"; rm -f "$VOL/.deep-trim-pattern"; exit 1; }

echo "== 3/5 guest sync 落盘 → 宿主 F_NOCACHE 预校验 =="
rm -f "$VOL/$RESULT"
printf 'sync; echo DEEP:SYNCED > /mnt/%s/%s\n' "$SHARE" "$RESULT" > "$PIPE.in"
wait_marker "DEEP:SYNCED" 30
PRE=$(./unmap-live "/dev/r$PART" --verify "$OFF")
echo "$PRE"
PAT=$(echo "$PRE" | sed -n 's/.*pattern=\([0-9]*\).*/\1/p')
[ "${PAT:-0}" -gt 1038090 ] || { echo "FAIL: 预校验非全图案 (介质上没有?), 中止"; exit 1; }
echo "预校验通过: 图案物理在盘 ($((SECONDS - T0))s)"

echo "== 4/5 guest 删除 + fstrim =="
cat > "$VOL/$SCRIPT" <<GUESTEOF
M=/mnt/$SHARE
rm -f \$M/.deep-trim-pattern
sync
fstrim -v \$M >> \$M/$RESULT 2>&1
echo "DEEP:FSTRIM-DONE rc=\$?" >> \$M/$RESULT
rm -f \$M/$SCRIPT
GUESTEOF
rm -f "$VOL/$RESULT"
T1=$SECONDS
printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
wait_marker "DEEP:FSTRIM-DONE" 600
echo "fstrim 完成 (耗时 $((SECONDS - T1))s):"
grep -v "DEEP:" "$VOL/$RESULT" | sed 's/^/  /'

echo "== 5/5 宿主 F_NOCACHE 读回 (每 10s 轮询, 测归零时延曲线) =="
for i in $(seq 0 60); do
    [ "$i" -gt 0 ] && sleep 10
    OUT=$(./unmap-live "/dev/r$PART" --verify "$OFF")
    Z=$(echo "$OUT" | sed -n 's/.*zero=\([0-9]*\).*/\1/p')
    echo "T+$((i * 10))s: zero=$Z/1048576"
    [ "$Z" = "1048576" ] && { echo "VERDICT: TRIM-EXECUTED (归零时延 $((i * 10))s)"; break; }
    [ "$i" = 60 ] && echo "VERDICT: TRIM-SWALLOWED? (600s 仍未归零)"
done
echo "---- 总耗时 $((SECONDS - T0))s ----"

rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
