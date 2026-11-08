#!/bin/bash
# guest-ntfs-blkdiscard.sh — blkdiscard 整分区清零僵尸 → 重新 mkfs.ntfs
# 用法: sudo ./guest-ntfs-blkdiscard.sh
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-bd

rm -f ${PIPE}.in ${PIPE}.out qemu-bd.log qemu-bd-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-bd)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-bd.log &
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
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-bd-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy' qemu-bd-err.log; then
        echo "RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-bd-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍被抢挂"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'echo G-DISCARD=$(cat /sys/block/sda/queue/discard_max_bytes)\n' > ${PIPE}.in
    printf 'time blkdiscard /dev/sda3 2>&1; echo G-BLKDISCARD-RC=$?\n' > ${PIPE}.in
    printf 'mkfs.ntfs -f -L Ti600-NTFS /dev/sda3 2>&1 | tail -3; echo G-MKFS-RC=$?\n' > ${PIPE}.in
    printf 'modprobe ntfs3; mkdir -p /mnt/ntfs\n' > ${PIPE}.in
    printf 'mount -t ntfs3 -o discard /dev/sda3 /mnt/ntfs 2>&1; echo G-MOUNT-DISCARD-RC=$?\n' > ${PIPE}.in
    printf 'df -h /mnt/ntfs 2>/dev/null | tail -1\n' > ${PIPE}.in
    printf 'sync; umount /mnt/ntfs 2>&1; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo BD-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 900); do
    grep -qa 'BD-DONE' qemu-bd.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 (关键行) ==="
grep -aE 'G-|real|Ti600|BD-DONE|error|fail' qemu-bd.log | tail -20
