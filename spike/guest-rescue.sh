#!/bin/bash
# guest-rescue.sh — 用 App 架构(QEMU+Alpine guest)执行 fstrim 抢救
# 流程: 压制自动挂载 → QEMU直通/dev/rdisk2 → guest挂exFAT → fstrim → 关VM
# 用法: sudo ./guest-rescue.sh
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/anyfs/spike/qemu-11.1.2/build/qemu-system-x86_64
PIPE=serial-rescue

rm -f ${PIPE}.in ${PIPE}.out qemu-rescue.log qemu-rescue-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-rescue)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-rescue.log &
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
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-rescue-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy' qemu-rescue-err.log; then
        echo "RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-rescue-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍被抢挂"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

# --- guest 抢救指令序列 ---
{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'echo G-DISCARD=$(cat /sys/block/sda/queue/discard_max_bytes)\n' > ${PIPE}.in
    printf 'modprobe exfat 2>&1; echo G-MODPROBE-RC=$?\n' > ${PIPE}.in
    printf 'mkdir -p /mnt/rescue\n' > ${PIPE}.in
    printf 'mount -t exfat /dev/sda3 /mnt/rescue 2>&1; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    printf 'which fstrim || busybox fstrim --help 2>&1 | head -2\n' > ${PIPE}.in
    printf 'fstrim -v /mnt/rescue 2>&1 || fstrim /mnt/rescue 2>&1; echo G-FSTRIM-RC=$?\n' > ${PIPE}.in
    printf 'sync; umount /mnt/rescue 2>&1; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo RESCUE-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 600); do
    grep -qa 'RESCUE-DONE' qemu-rescue.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 ==="
cat qemu-rescue.log
