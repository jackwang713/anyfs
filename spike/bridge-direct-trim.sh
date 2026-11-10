#!/bin/bash
# bridge-direct-trim.sh — 桥芯片直连金标准 (方案A 的文件系统无关版)
# 场景: trim-live-test.sh 要求 macOS 原生可写的 exFAT 卷, 对 NTFS/ext4 盘不可用.
# 本脚本借 anyFS 完成埋图案+定位, 再释放 VM 让 QEMU 完全离场,
# 最后对宿主分区裸设备直发 DKIOCUNMAP → F_NOCACHE 读回 — 隔离变量: 无 QEMU 补丁层
# 用法: sudo ./bridge-direct-trim.sh <分区>   例: sudo ./bridge-direct-trim.sh disk2s3
#   共享名自动经 anyfsctl share 解析 (大小写敏感, 不能靠猜)
# 前提: anyFS 已接管该分区, SMB 卷已挂载于 /Volumes/<共享名>; Terminal.app (FDA) 里跑
# 副作用: 图案文件残留在卷上 (内容含 1MB 零洞), 下次接管后删除即可
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk2s3>}"
SHARE=$(anyfsctl share "$PART")
[ -n "$SHARE" ] || { echo "FAIL: 无法从 daemon 解析 $PART 的共享名"; exit 1; }
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在 (App 侧 SMB 挂载了吗?)"; exit 1; }
PIPE=/tmp/anyfsd-serial
MARK=$$   # 控制台标记后缀, 防多轮误读陈旧标记
[ -x ./unmap-live ] || clang -O2 -o unmap-live unmap-live.c

# 控制台信号旗 (不用卷内结果文件 — smbfs 目录缓存对带外新建文件刷新不可靠)
wait_marker() {
    for i in $(seq 1 $(( $2 / 2 ))); do
        sleep 2
        anyfsctl console 2>/dev/null | grep -qF "$1" && return 0
    done
    echo "FAIL: 等不到 $1 (${2}s 超时), anyfsctl console 手工查看"; exit 1
}

echo "== 1/6 经 SMB 埋图案: 32MB 0x5A =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.bridge-pattern"
sync

echo "== 2/6 guest 内 filefrag 定位 (FIEMAP) =="
printf 'sync; /opt/usr/sbin/filefrag -e -v /mnt/%s/.bridge-pattern; echo BR:LOCATED-%s\n' \
    "$SHARE" "$MARK" > "$PIPE.in"
wait_marker "BR:LOCATED-$MARK" 30
TABLE=$(anyfsctl console | awk '/filefrag -e -v/{n=NR} {buf[NR]=$0} END{for(i=n+1;i<=NR;i++) print buf[i]}')
BS=$(echo "$TABLE" | sed -n 's/.*blocks of \([0-9]*\) bytes.*/\1/p' | head -1)
set -- $(echo "$TABLE" | awk -v bs="$BS" '/^ *[0-9]+:/ && $2 ~ /\.\./ { p=$4; sub(/\.\.$/,"",p); l=$6; sub(/:$/,"",l); if (l*bs>=1048576) { print p, l; exit } }')
PHYS=${1:-}; LEN=${2:-}
[ -n "$BS" ] && [ -n "$PHYS" ] && [ -n "$LEN" ] && [ "$((LEN * BS))" -ge 1048576 ] 2>/dev/null \
    || { echo "FAIL: filefrag 解析失败:"; echo "$TABLE"; rm -f "$VOL/.bridge-pattern"; exit 1; }
OFF=$((PHYS * BS))
echo "FIEMAP 定位: 物理块 $PHYS × ${BS}B = 分区偏移 $OFF (extent 连续 $((LEN * BS / 1048576))MB)"

echo "== 3/6 预校验: 图案物理在盘 (F_NOCACHE) =="
PRE=$(./unmap-live "/dev/r$PART" --verify "$OFF")
echo "$PRE"
PAT=$(echo "$PRE" | sed -n 's/.*pattern=\([0-9]*\).*/\1/p')
[ "${PAT:-0}" -gt 1038090 ] || { echo "FAIL: 预校验非全图案, 中止"; exit 1; }

echo "== 4/6 释放 anyFS (QEMU 干净离场, 排除补丁层变量) =="
anyfsctl release
for i in $(seq 1 20); do [ ! -S /tmp/anyfsd.qmp ] && break; sleep 1; done
[ -S /tmp/anyfsd.qmp ] && { echo "FAIL: VM 未退出"; exit 1; }
sleep 2   # 等 macOS 把 NTFS 只读挂回

echo "== 5/6 卸掉 macOS 的只读挂载, 独占裸设备 =="
diskutil unmount force "/dev/$PART" >/dev/null 2>&1 || true
sleep 1

echo "== 6/6 宿主直发 DKIOCUNMAP (无 QEMU) → 读回判决 =="
./unmap-live "/dev/r$PART" --unmap "$OFF"
RC=$?

echo "---- 恢复: 分区交还 (重新接管由 App/anyfsctl 决定) ----"
diskutil mount "/dev/$PART" >/dev/null 2>&1 || true
echo "注意: 图案文件 .bridge-pattern 仍在卷上 (1MB 已被 UNMAP 成零洞), 下次接管后记得删除+fstrim"
exit $RC
