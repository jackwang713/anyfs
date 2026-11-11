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
# 用法: sudo ./guest-deep-trim.sh <分区> [--fast] [--local] [--no-ctrl]
#   --fast: 只删不全量 fstrim — 依赖挂载的 -o discard (删除即发小量 UNMAP,
#           秒级归零, 适合快速物理验证); 默认 full 为全量 fstrim (真实养护负载)
#   --local: 无 SMB 隔离模式 — macOS 侧 umount 共享 + guest 杀 smbd, 图案改在
#           guest 内 dd|tr 本地生成 (验证延迟是否与 smbd/SMB 会话相关)
#   --no-ctrl: 跳过对照组 — 对照组会杀 smbd+remount, 恰好"治愈"被测状态
#           (run3 秒归零 vs run1/2 延迟 20s 的唯一差别), 复现延迟时必须关
# 前提: anyFS 已接管该分区; 非 --local 时 SMB 卷已挂载于 /Volumes/<共享名>;
#       Terminal.app (FDA) 里跑
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk2s3> [--fast] [--local] [--no-ctrl]}"
FAST=0; LOCAL=0; NOCTRL=0
for a in "${@:2}"; do
    [ "$a" = "--fast" ] && FAST=1
    [ "$a" = "--local" ] && LOCAL=1
    [ "$a" = "--no-ctrl" ] && NOCTRL=1
done
SHARE=$(anyfsctl share "$PART")
[ -n "$SHARE" ] || { echo "FAIL: 无法从 daemon 解析 $PART 的共享名"; exit 1; }
VOL="/Volumes/$SHARE"
if [ "$LOCAL" = 1 ]; then
    umount "$VOL" 2>/dev/null && echo "已断开 macOS 侧 SMB 挂载 ($VOL)"
else
    [ -d "$VOL" ] || { echo "FAIL: $VOL 不存在 (SMB 挂载了吗?)"; exit 1; }
fi
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

if [ "$LOCAL" = 1 ]; then
    echo "== 1/5 无 SMB 隔离: guest 杀 smbd + 本地 dd 埋 32MB 0x5A =="
    printf 'killall smbd nmbd 2>/dev/null; echo NOSMB-%s\n' "$MARK" > "$PIPE.in"
    wait_marker "NOSMB-$MARK" 15
    printf 'dd if=/dev/zero bs=1M count=32 2>/dev/null | tr "\\000" "\\132" > /mnt/%s/.deep-trim-pattern; sync; echo PLANTED-%s\n' "$SHARE" "$MARK" > "$PIPE.in"
    wait_marker "PLANTED-$MARK" 30
else
    echo "== 1/5 经 SMB 埋图案: 32MB 0x5A =="
    python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.deep-trim-pattern"
    sync
    # guest 侧打点器: diskstats 2s 采样 (inflight/discards完成/sectors), 经 SMB 卷投送
    cat > "$VOL/.ds-watch.sh" <<'EOF'
i=0
while [ $i -lt 150 ]; do
    awk '/ sda /{print "DS", systime(), $12, $15, $17}' /proc/diskstats
    i=$((i+1)); sleep 2
done
EOF
    sync
    # 立即启动, 采样窗口必须盖住 rm 之前 (教训: 删除前才启动会丢基线,
    # guest 记 discard 的时刻 vs QEMU 收到的时刻正是要切分的关键)
    printf '( sh /mnt/%s/.ds-watch.sh & )\n' "$SHARE" > "$PIPE.in"
fi

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
    echo "$TABLE"
    if [ "$LOCAL" = 1 ]; then
        printf 'rm -f /mnt/%s/.deep-trim-pattern\n' "$SHARE" > "$PIPE.in"
    else
        rm -f "$VOL/.deep-trim-pattern"
    fi
    exit 1
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
if [ "$((LEN * BS))" -ge 2097152 ] && [ "$LOCAL" = 0 ] && [ "$NOCTRL" = 0 ]; then
    echo "== 3.5/5 对照组: guest 块层直发 blkdiscard 1MB (绕过文件系统) =="
    # 挂载中 blkdiscard 一律 EBUSY (busybox -f 无效, 两连踩) → 先杀 smbd 释放句柄,
    # umount 后裸发, time 计时回显: 秒回+秒归零 → 传输段无延迟, 延迟锁定在 fs/VFS 层;
    # 若 blkdiscard 本身也卡 ~20s → 延迟在 guest 块层/virtio 传输段
    # (QMP qemu-io 在 QEMU 11 已移除 CommandNotFound, 用不了宿主侧对照)
    # 拆两条注入, 防串口长行截断; umount 失败则放弃对照组, 不误伤后续步骤
    printf 'D=$(awk -v m=/mnt/%s "\$2==m{print \$1}" /proc/mounts); T=$(awk -v m=/mnt/%s "\$2==m{print \$3}" /proc/mounts); echo CTRL-DEV=$D FS=$T; killall smbd nmbd 2>/dev/null; sleep 1; umount /mnt/%s && echo CTRL-UMOUNT-OK-%s\n' \
        "$SHARE" "$SHARE" "$SHARE" "$MARK" > "$PIPE.in"
    if wait_marker "CTRL-UMOUNT-OK-$MARK" 30 2>/dev/null; then
        printf 'time blkdiscard -o %s -l 1048576 $D; echo CTRL-DONE-%s rc=$?; mount -t $T -o discard $D /mnt/%s && echo CTRL-REMOUNT-OK; /opt/usr/sbin/smbd -s /tmp/smb.conf 2>/dev/null\n' \
            "$OFF" "$MARK" "$SHARE" > "$PIPE.in"
        wait_marker "CTRL-DONE-$MARK" 30
        # 把控件输出打进测试日志 (含 time 三段计时)
        anyfsctl console | awk '/CTRL-DEV/{n=NR} {buf[NR]=$0} END{for(i=n;i<=NR;i++) print buf[i]}' | head -12
        sleep 2
        ./unmap-live "/dev/r$PART" --verify "$OFF"
        VOFF=$((OFF + 1048576))   # 第 5 步改看后 1MB (guest 删除路径的窗口)
    else
        echo "对照组放弃: umount 失败 (句柄占用?), 跳过 blkdiscard 直接走删除路径"
    fi
fi

# rm 前抓一份基线 (console XPC 只返回末尾 60 行, 收尾再抓时基线早已滚出窗口)
[ "$LOCAL" = 0 ] && CONS_PRE=$(anyfsctl console)
# macOS 侧持有人快照: lsof 能看到进程级持有者 (QuickLook/mdworker 等);
# 若为空但 guest 仍有 FD-HELD → 句柄缓存在 smbfs 客户端内核层 (deferred close)
if [ "$LOCAL" = 0 ]; then
    echo "-- macOS 侧 lsof (删除前) --"
    lsof -- "$VOL/.deep-trim-pattern" 2>/dev/null || echo "(无进程级持有者)"
fi

if [ "$FAST" = 1 ]; then
    echo "== 4/5 guest 删除 (在线 discard, 不全量 fstrim) =="
    T_DEL=$SECONDS
    # DEL-BEGIN/DELETE-DONE 双标记: 测 rm 是否在 guest 内阻塞; 标记带 guest 时钟,
    # 与 DS 打点线对齐; fd 检查带 PID+进程名: 指认谁持有已删文件 (已实锤存在 holder)
    printf 'echo DEL-BEGIN-%s $(date +%%s); rm -f /mnt/%s/.deep-trim-pattern; sync; for f in /proc/[0-9]*/fd/*; do readlink $f 2>/dev/null | grep -q "deep-trim.*deleted" && echo FD-HELD $f $(cat ${f%%/fd/*}/comm); done; echo DEEP:DELETE-DONE-%s $(date +%%s)\n' "$MARK" "$SHARE" "$MARK" > "$PIPE.in"
else
    echo "== 4/5 guest 删除 + 全量 fstrim =="
    T_DEL=$SECONDS
    printf 'echo DEL-BEGIN-%s $(date +%%s); rm -f /mnt/%s/.deep-trim-pattern; sync; fstrim -v /mnt/%s; echo DEEP:FSTRIM-DONE-%s $(date +%%s)\n' "$MARK" "$SHARE" "$SHARE" "$MARK" > "$PIPE.in"
fi

# QMP unmap_ops 打点: UNMAP 离开 QEMU 的时刻 vs NAND 归零的时刻, 切分延迟归属
# 必须按设备名过滤 + python 解析 JSON (教训: sed 抓全行最后一个 unmap_operations
# 会张冠李戴到 bundle/ISO 设备, 永远 +0 — 2026-11-11 实踩, 对照 check-trim.sh)
qmp_ops() {
    ( echo '{"execute":"qmp_capabilities"}'; sleep 0.2; echo '{"execute":"query-blockstats"}'; sleep 0.3 ) \
      | nc -U /tmp/anyfsd.qmp 2>/dev/null | tail -1 | python3 -c '
import json, sys
try:
    j = json.load(sys.stdin)
    print(sum(d["stats"]["unmap_operations"] for d in j["return"] if d["device"].startswith("usbdisk")))
except Exception:
    pass'
}
OPS0=$(qmp_ops); OPS0=${OPS0:-0}

if [ "$FAST" = 1 ]; then
    wait_marker "DEL-BEGIN-$MARK" 15
    echo "  [打点] DEL-BEGIN 到达: 注入后 $((SECONDS - T_DEL))s"
    wait_marker "DEEP:DELETE-DONE-$MARK" 60
    echo "  [打点] DELETE-DONE 到达: 注入后 $((SECONDS - T_DEL))s (rm+sync 在 guest 内的耗时)"
else
    wait_marker "DEL-BEGIN-$MARK" 15
    echo "  [打点] DEL-BEGIN 到达: 注入后 $((SECONDS - T_DEL))s"
    wait_marker "DEEP:FSTRIM-DONE-$MARK" 600
    echo "  [打点] FSTRIM-DONE 到达: 注入后 $((SECONDS - T_DEL))s"
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
# 收尾分析: fd 持有现场 (谁抓着已删文件? 签名="(deleted)") + guest diskstats 时间线
if [ "$LOCAL" = 0 ]; then
    echo "== guest 侧证据 =="
    CONS=$(anyfsctl console)
    FDHELD=$(echo "$CONS" | grep 'FD-HELD' | head -5)
    [ -n "$FDHELD" ] && { echo "!!! 已删文件持有者 (PID 路径 + 进程名):"; echo "$FDHELD"; } || echo "fd 检查: 无进程持有已删文件"
    echo "-- rm 前基线 --"
    echo "$CONS_PRE" | grep '^DS ' | tail -6
    echo "-- rm 后 (对齐: DEL-BEGIN/DELETE-DONE 带 guest 时钟) --"
    echo "$CONS" | grep -E "^DS |DEL-BEGIN-$MARK |DELETE-DONE-$MARK " | tail -35
fi
# 收尾: 回看对照组窗口 (第 3.5 步那个 1MB) 的最终状态
[ "$VOFF" != "$OFF" ] && { echo "对照组窗口最终读回:"; ./unmap-live "/dev/r$PART" --verify "$OFF"; }
