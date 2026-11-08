#!/bin/bash
# guest-write-test.sh — guest 在 NTFS 分区写一个验证文件, 供 macOS 只读检查
# 用法: sudo ./guest-write-test.sh
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-wt

rm -f ${PIPE}.in ${PIPE}.out qemu-wt.log qemu-wt-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-wt)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-wt.log &
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
        -display none -monitor none 2>qemu-wt-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy' qemu-wt-err.log; then
        echo "RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-wt-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍被抢挂"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'modprobe ntfs3; mkdir -p /mnt/ntfs\n' > ${PIPE}.in
    printf 'mount -t ntfs3 -o discard /dev/sda3 /mnt/ntfs; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo "Hello from Alpine guest! 此文件由 Linux guest 通过 ntfs3 写入. $(date)" > /mnt/ntfs/hello-from-guest.txt\n' > ${PIPE}.in
    printf 'sync; ls -l /mnt/ntfs/; cat /mnt/ntfs/hello-from-guest.txt\n' > ${PIPE}.in
    printf 'umount /mnt/ntfs; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo WT-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 120); do
    grep -qa 'WT-DONE' qemu-wt.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 ==="
grep -aE 'G-|hello|WT-DONE|total|rw' qemu-wt.log | tail -10
