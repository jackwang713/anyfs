#!/bin/bash
# guest-deep-trim.sh — anyFS guest TRIM 深度检测 (金标准, v3 控制台信号旗版)
#
# 分工: guest 只负责 sync/删除/fstrim (经串口注入);
#       定位/预校验/读回判决全部在宿主侧 F_NOCACHE 直读分区设备 —
#       教训: QEMU 在 macOS 无 O_DIRECT (源码降级为 O_DSYNC), guest 内 dd 读回
#       会命中宿主缓冲区里的旧图案 → 假阴性 (2026-11-10 实测踩坑)
# 信号旗: 走控制台回显 + anyfsctl console 轮询 — 不用卷内结果文件
#       (教训: macOS smbfs 目录缓存对 guest 带外新建文件刷新不可靠,
#        ls/[ -f ] 假阴性但 cat 能读到, 2026-11-10 实测踩坑)
# 流程: ① SMB 埋 32MB 图案 ② guest filefrag -e -v 定位 (控制台取表格)
#       ③ guest sync 后宿主预校验图案在介质上
#       ④ guest 删除 [+fstrim] ⑤ 宿主 F_NOCACHE 读回判决: 全零=EXECUTED
# 用法: sudo ./guest-deep-trim.sh <分区> [--fast]
#   --fast: 只删不全量 fstrim — 依赖挂载的 -o discard (删除即发小量 UNMAP,
#           秒级归零, 适合快速物理验证); 默认 full 为全量 fstrim (真实养护负载)
# 前提: anyFS 已接管该分区, SMB 卷已挂载于 /Volumes/<共享名>; Terminal.app (FDA) 里跑
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk2s3> [--fast]}"
FAST=0
[ "${2:-}" = "--fast" ] && FAST=1
SHARE=$(anyfsctl share "$PART")
[ -n "$SHARE" ] || { echo "FAIL: 无法从 daemon 解析 $PART 的共享名"; exit 1; }
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在 (SMB 挂载了吗?)"; exit 1; }
PIPE=/tmp/anyfsd-serial
MARK=$$   # 控制台标记后缀, 防同 VM 会话多轮误读陈旧标记
T0=$SECONDS

# 控制台信号旗: 轮询 anyfsctl console 末尾输出 (daemon 内存 transcript, 无缓存问题)
wait_marker() {  # $1=标记串 $2=超时秒
    for i in $(seq 1 $(( $2 / 2 ))); do
        sleep 2
        anyfsctl console 2>/dev/null | grep -qF "$1" && return 0
    done
    echo "FAIL: 等不到 $1 (${2}s 超时), anyfsctl console 手工查看"; exit 1
}

echo "== 1/5 经 SMB 埋图案: 32MB 0x5A =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
sync

echo "== 2/5 guest 内 filefrag 定位 (FIEMAP, 文件系统无关, 免扫描) =="
# filefrag -e -v 才打印 extent 表 (裸 -v 只有摘要, 实测); physical offset 相对
# 被挂载设备 (= 直通分区), 与宿主 /dev/r分区 寻址直接通用; 需 bundle 有 e2fsprogs-extra
printf 'sync; /opt/usr/sbin/filefrag -e -v /mnt/%s/.deep-trim-pattern; echo DEEP:LOCATED-%s\n' "$SHARE" "$MARK" > "$PIPE.in"
wait_marker "DEEP:LOCATED-$MARK" 30
# 取最后一次 filefrag 输出 (同 VM 会话可能跑过多轮, 控制台有旧表格)
TABLE=$(anyfsctl console | awk '/filefrag -e -v/{n=NR} {buf[NR]=$0} END{for(i=n+1;i<=NR;i++) print buf[i]}')
BS=$(echo "$TABLE" | sed -n 's/.*blocks of \([0-9]*\) bytes.*/\1/p' | head -1)
# extent 行固定列位: idx: lo.. hi: physlo.. physhi: len: [expected:] flags → 取 $4/$6;
# 选第一个 ≥1MB 的连续 extent (文件可能碎成多段, 首段可能不足 1MB)
set -- $(echo "$TABLE" | awk -v bs="$BS" '/^ *[0-9]+:/ && $2 ~ /\.\./ { p=$4; sub(/\.\.$/,"",p); l=$6; sub(/:$/,"",l); if (l*bs>=1048576) { print p, l; exit } }')
PHYS=${1:-}; LEN=${2:-}
if [ -n "$BS" ] && [ -n "$PHYS" ] && [ -n "$LEN" ] && [ "$((LEN * BS))" -ge 1048576 ] 2>/dev/null; then
    OFF=$((PHYS * BS))
    echo "FIEMAP 定位: 物理块 $PHYS × ${BS}B = 分区偏移 $OFF (extent 连续 $((LEN * BS / 1048576))MB)"
else
    echo "FAIL: filefrag 解析失败 (bundle 缺 e2fsprogs-extra? 重烧 bundle), 控制台原始输出:"
    echo "$TABLE"; rm -f "$VOL/.deep-trim-pattern"; exit 1
fi

echo "== 3/5 guest sync 落盘 → 宿主 F_NOCACHE 预校验 =="
printf 'sync; echo DEEP:SYNCED-%s\n' "$MARK" > "$PIPE.in"
wait_marker "DEEP:SYNCED-$MARK" 30
PRE=$(./unmap-live "/dev/r$PART" --verify "$OFF")
echo "$PRE"
PAT=$(echo "$PRE" | sed -n 's/.*pattern=\([0-9]*\).*/\1/p')
[ "${PAT:-0}" -gt 1038090 ] || { echo "FAIL: 预校验非全图案 (介质上没有?), 中止"; exit 1; }
echo "预校验通过: 图案物理在盘 ($((SECONDS - T0))s)"

# 对照组: 同 VM 内经 QMP 让 QEMU 直发单条 1MB discard (qemu-io, 铠侠矩阵"即时"同款路径)
# 回答"路径慢还是量大才慢": 单条若即时归零 → 桥按批量销账, 与路径无关
# (extent 需 ≥2MB: 前 1MB 给对照组, 后 1MB 留给第 5 步看 guest 删除路径)
VOFF=$OFF
if [ "$((LEN * BS))" -ge 2097152 ]; then
    echo "== 3.5/5 对照组: QMP 单条 1MB discard (绕过 guest 文件系统) =="
    ( echo '{"execute":"qmp_capabilities"}'; sleep 0.3
      echo "{\"execute\":\"qemu-io\",\"arguments\":{\"device\":\"usbdisk0\",\"command\":\"discard $OFF 1048576\"}}"
      sleep 1 ) | nc -U /tmp/anyfsd.qmp >/dev/null
    sleep 2
    ./unmap-live "/dev/r$PART" --verify "$OFF"
    VOFF=$((OFF + 1048576))   # 第 5 步改看后 1MB (guest 删除路径的窗口)
fi

if [ "$FAST" = 1 ]; then
    echo "== 4/5 guest 删除 (在线 discard, 不全量 fstrim) =="
    printf 'rm -f /mnt/%s/.deep-trim-pattern; sync; echo DEEP:DELETE-DONE-%s\n' "$SHARE" "$MARK" > "$PIPE.in"
else
    echo "== 4/5 guest 删除 + 全量 fstrim =="
    printf 'rm -f /mnt/%s/.deep-trim-pattern; sync; fstrim -v /mnt/%s; echo DEEP:FSTRIM-DONE-%s\n' "$SHARE" "$SHARE" "$MARK" > "$PIPE.in"
fi

# QMP unmap_ops 打点: UNMAP 离开 QEMU 的时刻 vs NAND 归零的时刻, 切分延迟归属
qmp_ops() {
    ( echo '{"execute":"qmp_capabilities"}'; sleep 0.2; echo '{"execute":"query-blockstats"}'; sleep 0.3 ) \
      | nc -U /tmp/anyfsd.qmp 2>/dev/null | tail -1 \
      | sed -n 's/.*"unmap_operations": \([0-9]*\).*/\1/p' | head -1
}
OPS0=$(qmp_ops); OPS0=${OPS0:-0}

if [ "$FAST" = 1 ]; then
    wait_marker "DEEP:DELETE-DONE-$MARK" 60
else
    wait_marker "DEEP:FSTRIM-DONE-$MARK" 600
fi

echo "== 5/5 宿主 F_NOCACHE 读回判决 + QMP 打点 =="
# fast 模式预期秒级归零, 加密轮询 (2s); full 模式按异步销账量级 (10s)
if [ "$FAST" = 1 ]; then STEP=2; N=90; else STEP=10; N=60; fi
for i in $(seq 0 $N); do
    [ "$i" -gt 0 ] && sleep $STEP
    OUT=$(./unmap-live "/dev/r$PART" --verify "$VOFF")
    Z=$(echo "$OUT" | sed -n 's/.*zero=\([0-9]*\).*/\1/p')
    OPS=$(qmp_ops); OPS=${OPS:-$OPS0}
    echo "T+$((i * STEP))s: zero=$Z/1048576 unmap_ops=+$((OPS - OPS0))"
    [ "$Z" = "1048576" ] && { echo "VERDICT: TRIM-EXECUTED (归零时延 $((i * STEP))s)"; break; }
    [ "$i" = "$N" ] && echo "VERDICT: TRIM-SWALLOWED? ($((N * STEP))s 仍未归零)"
done
echo "---- 总耗时 $((SECONDS - T0))s ----"
