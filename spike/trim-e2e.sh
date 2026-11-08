#!/bin/bash
# trim-e2e.sh — VM 内发 TRIM, macOS 侧读回验证 (端到端)
# 前提: exFAT 分区有刚删除的 0x5A 图案文件
# 当前 QEMU 11.1.2 未打补丁, 预期 verdict 为 TRIM-SWALLOWED (QEMU 吞掉 discard)
# 用法: sudo ./trim-e2e.sh
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-e2e

# --- 阶段1: 找图案区偏移 (缓存到文件, 只扫一次) ---
OFF=""
[ -f pattern-offset.txt ] && OFF=$(cat pattern-offset.txt)
if [ -z "$OFF" ]; then
    diskutil unmountDisk force /dev/disk2 2>/dev/null || true
    OFF=$(./unmap-live /dev/rdisk2 --scan-only | sed -n 's/.*LIVE-FOUND 图案块 @ 偏移 \([0-9]*\).*/\1/p')
    [ -n "$OFF" ] && echo "$OFF" > pattern-offset.txt
fi
if [ -z "$OFF" ]; then
    echo "E2E-FAIL: 未找到图案区, 先重新埋 0x5A 文件"
    exit 1
fi
echo "E2E-OFFSET=$OFF"

# --- 阶段2: 压制自动挂载的后台循环 ---
rm -f ${PIPE}.in ${PIPE}.out qemu-trim.log qemu-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t trim-e2e)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

# --- 阶段3: 启动 QEMU (被抢挂则重试) ---
cat ${PIPE}.out > qemu-trim.log &
CATPID=$!

QEMUPID=""
for attempt in 1 2 3 4 5; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    "$QEMU" \
        -machine virt,accel=hvf \
        -cpu host -smp 2 -m 512 \
        -kernel alpine/vmlinuz-virt \
        -initrd alpine/initramfs-virt \
        -append "console=ttyAMA0" \
        -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then
        break
    fi
    if grep -q 'Resource busy' qemu-err.log; then
        echo "E2E-RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "E2E-FAIL: QEMU 启动失败:"; cat qemu-err.log
    exit 1
done
if [ -z "$QEMUPID" ]; then
    echo "E2E-FAIL: 重试 5 次仍被抢挂, 请退出柠檬清理等软件后重试"
    exit 1
fi
echo "E2E-QEMU-STARTED (PID $QEMUPID)"

# --- 阶段4: guest 内发 blkdiscard ---
{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'echo G-DISCARD=$(cat /sys/block/sda/queue/discard_max_bytes)\n' > ${PIPE}.in
    printf 'blkdiscard -o %s -l 1048576 /dev/sda 2>&1; echo G-BLKDISCARD-RC=$?\n' "$OFF" > ${PIPE}.in
    printf 'dmesg | grep -iE "discard|unmap|error|critical" | tail -5\n' > ${PIPE}.in
    printf 'echo TRIM-TEST-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 90); do
    grep -qa 'TRIM-TEST-DONE' qemu-trim.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true

# --- 阶段5: macOS 侧读回验证 ---
echo "=== macOS 读回验证 ==="
./unmap-live /dev/rdisk2 --verify "$OFF"
