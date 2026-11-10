#!/bin/bash
# guest-deep-trim.sh — anyFS guest TRIM 深度检测 (金标准, 分工修正版 v2)
#
# 分工: guest 只负责 sync/删除/fstrim (经串口注入);
#       定位/预校验/读回判决全部在宿主侧 F_NOCACHE 直读分区设备 —
#       教训: QEMU 在 macOS 无 O_DIRECT (源码降级为 O_DSYNC), guest 内 dd 读回
#       会命中宿主缓冲区里的旧图案 → 假阴性 (2026-11-10 实测踩坑)
# 流程: ① SMB 埋 32MB 图案 ② 宿主定位偏移 ③ guest sync 后宿主预校验图案在介质上
#       ④ guest 删除+fstrim ⑤ 宿主 F_NOCACHE 读回判决: 全零=EXECUTED 图案在=SWALLOWED
# 用法: sudo ./guest-deep-trim.sh <分区> <共享名> [--fast]
#   --fast: 只删不全量 fstrim — 依赖挂载的 -o discard (删除即发小量 UNMAP,
#           秒级归零, 适合快速物理验证); 默认 full 为全量 fstrim (真实养护负载)
# 前提: anyFS 已接管该分区, App 侧 SMB 卷已挂载; Terminal.app (FDA) 里跑
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2> <共享名> [--fast]}"
SHARE="${2:?缺少共享名}"
FAST=0
[ "${3:-}" = "--fast" ] && FAST=1
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

echo "== 2/5 guest 内 filefrag 定位 (FIEMAP, 文件系统无关, 免扫描) =="
# filefrag 的 physical offset 相对被挂载设备 (= 直通分区) — 与宿主 /dev/r分区 寻址直接通用
# 需要 bundle 里有 filefrag (Alpine 在 e2fsprogs-extra 包, 装到 /opt/usr/sbin/);
# bundle 二进制不在 guest PATH 里, 必须用绝对路径 (init.sh 起 smbd 同理);
# 结果经卷内结果文件回传 (串口 fifo 宿主不可读)
rm -f "$VOL/$RESULT"
printf 'sync; /opt/usr/sbin/filefrag -v /mnt/%s/.deep-trim-pattern > /mnt/%s/%s 2>&1; echo DEEP:LOCATED >> /mnt/%s/%s; sync\n' \
    "$SHARE" "$SHARE" "$RESULT" "$SHARE" "$RESULT" > "$PIPE.in"
wait_marker "DEEP:LOCATED" 30
BS=$(sed -n 's/.*blocks of \([0-9]*\) bytes.*/\1/p' "$VOL/$RESULT" | head -1)
# extent 行固定列位: idx: lo.. hi: physlo.. physhi: len: [expected:] flags → 取 $4/$6
set -- $(awk '/^ *[0-9]+:/ && $2 ~ /\.\./ { p=$4; sub(/\.\.$/,"",p); l=$6; sub(/:$/,"",l); print p, l; exit }' "$VOL/$RESULT")
PHYS=${1:-}; LEN=${2:-}
if [ -n "$BS" ] && [ -n "$PHYS" ] && [ -n "$LEN" ] && [ "$((LEN * BS))" -ge 1048576 ] 2>/dev/null; then
    OFF=$((PHYS * BS))
    echo "FIEMAP 定位: 物理块 $PHYS × ${BS}B = 分区偏移 $OFF (extent 连续 $((LEN * BS / 1048576))MB)"
else
    echo "FAIL: filefrag 解析失败 (bundle 缺 e2fsprogs-extra? 重烧 bundle):"; cat "$VOL/$RESULT"
    rm -f "$VOL/.deep-trim-pattern" "$VOL/$RESULT"; exit 1
fi
rm -f "$VOL/$RESULT"

echo "== 3/5 guest sync 落盘 → 宿主 F_NOCACHE 预校验 =="
rm -f "$VOL/$RESULT"
printf 'sync; echo DEEP:SYNCED > /mnt/%s/%s\n' "$SHARE" "$RESULT" > "$PIPE.in"
wait_marker "DEEP:SYNCED" 30
PRE=$(./unmap-live "/dev/r$PART" --verify "$OFF")
echo "$PRE"
PAT=$(echo "$PRE" | sed -n 's/.*pattern=\([0-9]*\).*/\1/p')
[ "${PAT:-0}" -gt 1038090 ] || { echo "FAIL: 预校验非全图案 (介质上没有?), 中止"; exit 1; }
echo "预校验通过: 图案物理在盘 ($((SECONDS - T0))s)"

if [ "$FAST" = 1 ]; then
    echo "== 4/5 guest 删除 (在线 discard, 不全量 fstrim) =="
    TRIMCMD=": # fast 模式: 靠挂载的 -o discard 在线修剪"
else
    echo "== 4/5 guest 删除 + fstrim =="
    TRIMCMD="fstrim -v \$M >> \$M/$RESULT 2>&1"
fi
cat > "$VOL/$SCRIPT" <<GUESTEOF
M=/mnt/$SHARE
rm -f \$M/.deep-trim-pattern
sync
$TRIMCMD
echo "DEEP:FSTRIM-DONE rc=\$?" >> \$M/$RESULT
rm -f \$M/$SCRIPT
GUESTEOF
rm -f "$VOL/$RESULT"
T1=$SECONDS
printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
wait_marker "DEEP:FSTRIM-DONE" 600
echo "fstrim 完成 (耗时 $((SECONDS - T1))s):"
grep -v "DEEP:" "$VOL/$RESULT" | sed 's/^/  /'

echo "== 5/5 宿主 F_NOCACHE 读回判决 =="
# fast 模式预期秒级归零, 加密轮询 (2s); full 模式按异步销账量级 (10s)
if [ "$FAST" = 1 ]; then STEP=2; N=90; else STEP=10; N=60; fi
for i in $(seq 0 $N); do
    [ "$i" -gt 0 ] && sleep $STEP
    OUT=$(./unmap-live "/dev/r$PART" --verify "$OFF")
    Z=$(echo "$OUT" | sed -n 's/.*zero=\([0-9]*\).*/\1/p')
    echo "T+$((i * STEP))s: zero=$Z/1048576"
    [ "$Z" = "1048576" ] && { echo "VERDICT: TRIM-EXECUTED (归零时延 $((i * STEP))s)"; break; }
    [ "$i" = "$N" ] && echo "VERDICT: TRIM-SWALLOWED? ($((N * STEP))s 仍未归零)"
done
echo "---- 总耗时 $((SECONDS - T0))s ----"

rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
