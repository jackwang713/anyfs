#!/bin/bash
# guest-bundle.sh — 产品形态验证: -m 128, 零安装, bundle.img 只读挂载, init.sh 全自动
# 用法: sudo ./guest-bundle.sh [内存MB, 默认128]   (常驻运行)
set -e
cd "$(dirname "$0")"
MEM="${1:-128}"
echo "guest 内存: ${MEM}MB (产品形态: bundle 只读 + 零网络安装)"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-bnd

rm -f ${PIPE}.in ${PIPE}.out qemu-bnd.log qemu-bnd-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-bnd)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR $CATPID $QEMUPID 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-bnd.log &
CATPID=$!

QEMUPID=""
for attempt in 1 2 3 4 5; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    "$QEMU" \
        -machine virt,accel=hvf \
        -cpu host -smp 2 -m "$MEM" \
        -kernel alpine/vmlinuz-virt \
        -initrd alpine/initramfs-virt \
        -append "console=ttyAMA0" \
        -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
        -drive file=bundle/bundle.img,format=raw,if=virtio,readonly=on \
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -netdev vmnet-shared,id=n0 -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-bnd-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    echo "RETRY 第 $attempt 次启动失败, 重试..."
    QEMUPID=""
    continue
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍失败:"; cat qemu-bnd-err.log; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    # 等待登录提示符出现 (USB枚举时长因桥而异, 固定sleep不可靠)
    for i in $(seq 1 180); do
        grep -qa 'login:' qemu-bnd.log 2>/dev/null && break
        sleep 1
    done
    printf '\nroot\n' > ${PIPE}.in
    # 等待 shell 就绪
    for i in $(seq 1 30); do
        grep -qa ':~#' qemu-bnd.log 2>/dev/null && break
        sleep 1
    done
    printf 'ip link set eth0 up && udhcpc -i eth0 -q\n' > ${PIPE}.in
    printf "ip addr show eth0 | grep 'inet ' | awk '{print \"G-IP=\"\$2}'\n" > ${PIPE}.in
    printf 'mount -t ext2 -o ro /dev/vdb /opt; echo G-BUNDLE-RC=$?\n' > ${PIPE}.in
    printf 'sh /opt/init.sh\n' > ${PIPE}.in
} &

for i in $(seq 1 300); do
    grep -qa 'BRIDGE-READY\|BRIDGE-FAIL' qemu-bnd.log 2>/dev/null && break
    sleep 1
done
grep -aE 'G-|BRIDGE-' qemu-bnd.log | tail -12
if grep -qa 'BRIDGE-READY' qemu-bnd.log; then
    GIP=$(grep -ao 'G-IP=[0-9.]*' qemu-bnd.log | tail -1 | cut -d= -f2)
    echo "=== BRIDGE-READY: mount_smbfs //GUEST@${GIP}/<共享名> /tmp/ti600-smb ==="
    wait $QEMUPID
else
    echo "FAIL: 未就绪, 日志尾部:"
    tail -20 qemu-bnd.log
    echo "=== QEMU 保持运行, 可注入调试命令 ==="
    wait $QEMUPID
fi
