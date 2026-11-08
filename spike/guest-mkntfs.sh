#!/bin/bash
# guest-mkntfs.sh — guest 中将 /dev/sda3 格式化为 NTFS 并全量 TRIM
# 流程: 压制自动挂载 → QEMU直通(带用户态网络) → apk装ntfs-3g-progs(清华镜像)
#       → mkfs.ntfs 快速格式化 → ntfs3挂载 → fstrim全盘 → 关VM
# 用法: sudo ./guest-mkntfs.sh
set -e
cd "$(dirname "$0")"

. "$(dirname "$0")/qemu-env.sh"   # QEMU/MACHINE/CONSOLE 按架构自动选择
PIPE=serial-mkntfs

rm -f ${PIPE}.in ${PIPE}.out qemu-mkntfs.log qemu-mkntfs-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-mkntfs)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-mkntfs.log &
CATPID=$!

QEMUPID=""
for attempt in 1 2 3 4 5; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    "$QEMU" \
        -machine "$MACHINE" \
        -cpu host -smp 2 -m 512 \
        -kernel alpine/vmlinuz-virt \
        -initrd alpine/initramfs-virt \
        -append "console=$CONSOLE" \
        -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-mkntfs-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy' qemu-mkntfs-err.log; then
        echo "RETRY 第 $attempt 次启动被抢挂, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-mkntfs-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍被抢挂"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

# --- guest 指令序列 ---
{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    # 网络 (slirp: 10.0.2.x, DHCP 即可)
    printf 'ip link set eth0 up && udhcpc -i eth0 -q 2>&1 | tail -1; echo G-NET-RC=$?\n' > ${PIPE}.in
    # 清华镜像装 ntfs-3g-progs
    printf 'echo https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main > /etc/apk/repositories\n' > ${PIPE}.in
    printf 'apk add ntfs-3g-progs 2>&1 | tail -3; echo G-APK-RC=$?\n' > ${PIPE}.in
    # 快速格式化 sda3 为 NTFS
    printf 'mkfs.ntfs -f -L Ti600-NTFS /dev/sda3 2>&1 | tail -5; echo G-MKFS-RC=$?\n' > ${PIPE}.in
    # ntfs3 挂载 + 全盘 fstrim
    printf 'modprobe ntfs3 2>&1; echo G-MODPROBE-RC=$?\n' > ${PIPE}.in
    printf 'mkdir -p /mnt/ntfs && mount -t ntfs3 /dev/sda3 /mnt/ntfs 2>&1; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    printf 'fstrim -v /mnt/ntfs 2>&1; echo G-FSTRIM-RC=$?\n' > ${PIPE}.in
    printf 'df -h /mnt/ntfs | tail -1\n' > ${PIPE}.in
    printf 'sync; umount /mnt/ntfs 2>&1; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo MKNTFS-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 600); do
    grep -qa 'MKNTFS-DONE' qemu-mkntfs.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 (关键行) ==="
grep -aE 'G-|trimmed|Ti600|MKNTFS-DONE|error|fail' qemu-mkntfs.log | tail -25
