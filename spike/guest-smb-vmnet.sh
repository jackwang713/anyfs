#!/bin/bash
# guest-smb-vmnet.sh — guest 起 Samba, vmnet-shared 内核态网络 (高速版)
# 用法: sudo ./guest-smb-vmnet.sh [内存MB, 默认512]   (常驻运行)
# guest 通过 macOS vmnet DHCP 获取 192.168.64.x 地址, macOS 直接挂载该 IP
set -e
cd "$(dirname "$0")"
MEM="${1:-512}"
echo "guest 内存: ${MEM}MB"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-vms

rm -f ${PIPE}.in ${PIPE}.out qemu-vms.log qemu-vms-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-vms)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR $CATPID $QEMUPID 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-vms.log &
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
        -device virtio-scsi-pci,id=scsi0 \
        -drive file=/dev/rdisk2,format=raw,if=none,id=usbdisk,discard=unmap \
        -device scsi-hd,bus=scsi0.0,drive=usbdisk,discard_granularity=512 \
        -netdev vmnet-shared,id=n0 -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-vms-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    echo "RETRY 第 $attempt 次启动失败, 重试..."
    QEMUPID=""
    continue
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍失败:"; cat qemu-vms-err.log; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'ip link set eth0 up && udhcpc -i eth0 -q; echo G-NET-RC=$?\n' > ${PIPE}.in
    printf "ip addr show eth0 | grep 'inet ' | awk '{print \"G-IP=\"\$2}'\n" > ${PIPE}.in
    printf 'echo https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main > /etc/apk/repositories\n' > ${PIPE}.in
    printf 'apk add samba ntfs-3g-progs >/dev/null 2>&1; echo G-APK-RC=$?\n' > ${PIPE}.in
    printf 'modprobe ntfs3; mkdir -p /mnt/ntfs\n' > ${PIPE}.in
    printf 'ntfsfix -d /dev/sda3 >/dev/null 2>&1; echo G-NTFSFIX-RC=$?\n' > ${PIPE}.in
    printf 'mount -t ntfs3 -o discard /dev/sda3 /mnt/ntfs; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    printf '{ echo "[global]"; echo "  workgroup = WORKGROUP"; echo "  server string = ntfs-bridge-spike"; echo "  security = user"; echo "  map to guest = Bad User"; echo "  log level = 1"; echo "[ti600]"; echo "  path = /mnt/ntfs"; echo "  read only = no"; echo "  guest ok = yes"; echo "  force user = root"; } > /etc/samba/smb.conf\n' > ${PIPE}.in
    printf 'smbd; sleep 2; pgrep -x smbd >/dev/null; echo G-SMBD-RC=$?\n' > ${PIPE}.in
    printf 'echo SMB-READY\n' > ${PIPE}.in
} &

for i in $(seq 1 300); do
    grep -qa 'SMB-READY' qemu-vms.log 2>/dev/null && break
    sleep 1
done
grep -aE 'G-|SMB-READY' qemu-vms.log | tail -8
if grep -qa 'SMB-READY' qemu-vms.log; then
    GIP=$(grep -ao 'G-IP=[0-9.]*' qemu-vms.log | tail -1 | cut -d= -f2)
    echo "=== SMB 就绪: macOS 执行 mount_smbfs //GUEST@${GIP}/ti600 /tmp/ti600-smb ==="
    wait $QEMUPID
else
    echo "FAIL: SMB 未就绪, 日志:"
    tail -30 qemu-vms.log
fi
