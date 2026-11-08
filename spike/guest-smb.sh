#!/bin/bash
# guest-smb.sh — guest 起 Samba 服务 NTFS 卷, hostfwd 到 macOS 127.0.0.1:445
# 用法: sudo ./guest-smb.sh   (常驻运行, Ctrl-C 或杀任务结束)
# 之后 macOS 侧: mkdir -p /tmp/ti600-smb && mount_smbfs //GUEST@127.0.0.1/ti600 /tmp/ti600-smb
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-smb

rm -f ${PIPE}.in ${PIPE}.out qemu-smb.log qemu-smb-err.log
mkfifo ${PIPE}.in ${PIPE}.out
STOPFLAG=$(mktemp -t guest-smb)
( while [ -f "$STOPFLAG" ]; do
    diskutil unmountDisk force /dev/disk2 >/dev/null 2>&1
    sleep 1
done ) &
SUPPRESSOR=$!
trap 'rm -f "$STOPFLAG"; kill $SUPPRESSOR $CATPID $QEMUPID 2>/dev/null' EXIT

cat ${PIPE}.out > qemu-smb.log &
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
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:445-:445 \
        -device virtio-net-pci,netdev=n0 \
        -serial pipe:${PIPE} \
        -display none -monitor none 2>qemu-smb-err.log &
    QEMUPID=$!
    sleep 3
    if kill -0 $QEMUPID 2>/dev/null; then break; fi
    if grep -q 'Resource busy\|Could not set up host forwarding' qemu-smb-err.log; then
        echo "RETRY 第 $attempt 次启动失败, 重试..."
        QEMUPID=""
        continue
    fi
    echo "FAIL: QEMU 启动失败:"; cat qemu-smb-err.log
    exit 1
done
[ -z "$QEMUPID" ] && { echo "FAIL: 重试5次仍失败"; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'ip link set eth0 up && udhcpc -i eth0 -q; echo G-NET-RC=$?\n' > ${PIPE}.in
    printf 'echo https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main > /etc/apk/repositories\n' > ${PIPE}.in
    printf 'apk add samba >/dev/null 2>&1; echo G-APK-RC=$?\n' > ${PIPE}.in
    printf 'modprobe ntfs3; mkdir -p /mnt/ntfs\n' > ${PIPE}.in
    printf 'mount -t ntfs3 -o discard /dev/sda3 /mnt/ntfs; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    printf '{ echo "[global]"; echo "  workgroup = WORKGROUP"; echo "  server string = ntfs-bridge-spike"; echo "  security = user"; echo "  map to guest = Bad User"; echo "  log level = 1"; echo "[ti600]"; echo "  path = /mnt/ntfs"; echo "  read only = no"; echo "  guest ok = yes"; echo "  force user = root"; } > /etc/samba/smb.conf\n' > ${PIPE}.in
    printf 'smbd; sleep 2; pgrep -x smbd >/dev/null; echo G-SMBD-RC=$?\n' > ${PIPE}.in
    printf 'dd if=/dev/urandom of=/mnt/ntfs/readback-test.bin bs=1M count=12288 2>&1 | tail -1; sync; echo G-GEN-RC=$?\n' > ${PIPE}.in
    printf 'echo SMB-READY\n' > ${PIPE}.in
} &

for i in $(seq 1 420); do
    grep -qa 'SMB-READY' qemu-smb.log 2>/dev/null && break
    sleep 1
done
grep -aE 'G-|SMB-READY' qemu-smb.log | tail -8
if grep -qa 'SMB-READY' qemu-smb.log; then
    echo "=== SMB 就绪: macOS 执行 mount_smbfs //GUEST@127.0.0.1/ti600 /tmp/ti600-smb ==="
    wait $QEMUPID
else
    echo "FAIL: SMB 未就绪, 日志:"
    tail -30 qemu-smb.log
fi
