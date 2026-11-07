#!/bin/bash
# guest-ntfs-mkfs.sh — 修正版: 完整启动guest → apk装ntfs-3g-progs → mkfs.ntfs
# → ntfs3挂载(测-o discard) → df验证
# 前置: 分区已 blkdiscard 清零 (上一步已完成)
# 用法: sudo ./guest-ntfs-mkfs.sh
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/anyfs/spike/qemu-11.1.2/build/qemu-system-x86_64
PIPE=serial-mkfs2

rm -f ${PIPE}.in ${PIPE}.out qemu-mkfs2.log qemu-mkfs2-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-mkfs2)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-mkfs2.log &
CATPID=$!

QEMUPID=""
for attempt in 1 2 3 4 5; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    "$QEMU" \
        -machine q35,accel=hvf \
        -cpu host -smp 2 -m 512 \
        -kernel alpine/vmlinuz-virt \
        -initrd alpine/initramfs-virt \
        -append "console=ttyS0" \
        -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-mkfs2-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy' qemu-mkfs2-err.log; then
        echo "RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-mkfs2-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍被抢挂"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'ip link set eth0 up && udhcpc -i eth0 -q; echo G-NET-RC=$?\n' > ${PIPE}.in
    printf 'echo https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main > /etc/apk/repositories\n' > ${PIPE}.in
    printf 'apk add ntfs-3g-progs >/dev/null 2>&1; echo G-APK-RC=$?\n' > ${PIPE}.in
    printf 'mkfs.ntfs -f -L Ti600-NTFS /dev/sda3; echo G-MKFS-RC=$?\n' > ${PIPE}.in
    printf 'modprobe ntfs3; echo G-MODPROBE-RC=$?\n' > ${PIPE}.in
    printf 'mkdir -p /mnt/ntfs\n' > ${PIPE}.in
    printf 'mount -t ntfs3 -o discard /dev/sda3 /mnt/ntfs; echo G-MOUNT-DISCARD-RC=$?\n' > ${PIPE}.in
    printf 'df -h /mnt/ntfs | tail -1\n' > ${PIPE}.in
    printf 'echo hello > /mnt/ntfs/guest-write-test.txt && ls -l /mnt/ntfs/; echo G-WRITE-RC=$?\n' > ${PIPE}.in
    printf 'rm /mnt/ntfs/guest-write-test.txt; sync; umount /mnt/ntfs; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo MKFS2-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 600); do
    grep -qa 'MKFS2-DONE' qemu-mkfs2.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 (关键行) ==="
grep -aE 'G-|MKFS2-DONE|Ti600|error|Error|fail' qemu-mkfs2.log | tail -20
