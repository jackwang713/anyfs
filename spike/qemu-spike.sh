#!/bin/bash
# QEMU spike: virtio-scsi 直通 /dev/rdisk2
# 验证: 1) 盘容量识别 2) discard 能力宣告 3) 顺序读速度
# 全程只读。用法: sudo ./qemu-spike.sh
set -e
cd "$(dirname "$0")"

QEMU=/opt/local/bin/qemu-system-x86_64
PIPE=serial

diskutil unmountDisk /dev/disk2 2>/dev/null || true

rm -f ${PIPE}.in ${PIPE}.out qemu-serial.log qemu.pid
mkfifo ${PIPE}.in ${PIPE}.out

cat ${PIPE}.out > qemu-serial.log &

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
    -display none -monitor none \
    -pidfile qemu.pid &
QEMUPID=$!

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'echo SPIKE-SECTORS=$(cat /sys/block/sda/size)\n' > ${PIPE}.in
    printf 'echo SPIKE-DISCARD=$(cat /sys/block/sda/queue/discard_max_bytes)\n' > ${PIPE}.in
    printf 'echo SPIKE-GRAN=$(cat /sys/block/sda/queue/discard_granularity)\n' > ${PIPE}.in
    printf 'echo SPIKE-PROV=$(cat /sys/block/sda/device/provisioning_mode)\n' > ${PIPE}.in
    printf 'fdisk -l /dev/sda | head -8\n' > ${PIPE}.in
    sleep 1
    printf 'echo SPIKE-SPEED-START\n' > ${PIPE}.in
    printf 'dd if=/dev/sda of=/dev/null bs=1M count=4096\n' > ${PIPE}.in
    printf 'echo SPIKE-ALL-DONE\n' > ${PIPE}.in
} &

echo "QEMU 已启动 (PID $QEMUPID)"
echo "串口日志实时写入 qemu-serial.log, 可用 tail -f qemu-serial.log 观察"
echo "看到 SPIKE-ALL-DONE 后执行: sudo kill $QEMUPID"
wait $QEMUPID || true
