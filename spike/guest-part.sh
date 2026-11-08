#!/bin/bash
# guest-part.sh — 产品形态验证: -m 128, 零安装, bundle.img 只读挂载, init.sh 全自动
# 用法: sudo ./guest-part.sh [内存MB, 默认128]   (常驻运行)
set -e
cd "$(dirname "$0")"
MEM="${1:-128}"
echo "guest 内存: ${MEM}MB (产品形态: bundle 只读 + 零网络安装)"

. "$(dirname "$0")/qemu-env.sh"   # QEMU/MACHINE/CONSOLE 按架构自动选择
PIPE=serial-part

# 目标分区: 按卷标自动探测 (盘符会随插拔/重启漂移, 不可写死), 可用 PART_DEV=/dev/diskXsY 覆盖
PART_DEV="${PART_DEV:-$(diskutil info Ti600-NTFS 2>/dev/null | awk -F': *' '/Device Node/ {print $2}')}"
[ -n "$PART_DEV" ] || { echo "FAIL: 找不到 Ti600-NTFS 分区"; exit 1; }
RPART="/dev/r${PART_DEV#/dev/}"
echo "目标分区: $PART_DEV"

rm -f ${PIPE}.in ${PIPE}.out qemu-part.log qemu-part-err.log /tmp/anyfs-part.qmp
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-bnd)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmount force "$PART_DEV" >/dev/null 2>&1 || true
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR $CATPID $QEMUPID 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-part.log &
CATPID=$!

QEMUPID=""
for attempt in 1 2 3 4 5; do
    diskutil unmount force "$PART_DEV" >/dev/null 2>&1 || true
    "$QEMU" \
        -machine "$MACHINE" \
        -cpu host -smp 2 -m "$MEM" \
        -kernel alpine/vmlinuz-virt \
        -initrd alpine/initramfs-virt \
        -append "console=$CONSOLE" \
        -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
        -drive file=bundle/bundle.img,format=raw,if=virtio,readonly=on \
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=$RPART,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -netdev vmnet-shared,id=n0 -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -qmp unix:/tmp/anyfs-part.qmp,server,nowait \
        -display none -monitor none 2>qemu-part-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    echo "RETRY 第 $attempt 次启动失败, 重试..."
    QEMUPID=""
    continue
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍失败:"; cat qemu-part-err.log; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    # 等待登录提示符出现 (USB枚举时长因桥而异, 固定sleep不可靠)
    for i in $(seq 1 180); do
        grep -qa 'login:' qemu-part.log 2>/dev/null && break
        sleep 1
    done
    printf '\nroot\n' > ${PIPE}.in
    # 等待 shell 就绪
    for i in $(seq 1 30); do
        grep -qa ':~#' qemu-part.log 2>/dev/null && break
        sleep 1
    done
    printf 'ip link set eth0 up && udhcpc -i eth0 -q\n' > ${PIPE}.in
    printf "ip addr show eth0 | grep 'inet ' | awk '{print \"G-IP=\"\$2}'\n" > ${PIPE}.in
    printf 'mount -t ext2 -o ro /dev/vdb /opt; echo G-BUNDLE-RC=$?\n' > ${PIPE}.in
    printf 'sh /opt/init.sh\n' > ${PIPE}.in
} &

for i in $(seq 1 300); do
    grep -qa 'BRIDGE-READY\|BRIDGE-FAIL' qemu-part.log 2>/dev/null && break
    sleep 1
done
grep -aE 'G-|BRIDGE-' qemu-part.log | tail -12
if grep -qa 'BRIDGE-READY' qemu-part.log; then
    GIP=$(grep -ao 'G-IP=[0-9.]*' qemu-part.log | tail -1 | cut -d= -f2)
    echo "=== BRIDGE-READY: mount_smbfs //GUEST@${GIP}/<共享名> /tmp/ti600-smb ==="
    wait $QEMUPID
else
    echo "FAIL: 未就绪, 日志尾部:"
    tail -20 qemu-part.log
    echo "=== QEMU 保持运行, 可注入调试命令 ==="
    wait $QEMUPID
fi
