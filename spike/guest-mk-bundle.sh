#!/bin/bash
# guest-mk-bundle.sh — 在 guest 中将 bundle.img 格式化为 ext2 并填入 rootfs
# 流程: QEMU(slirp网络) → apk add e2fsprogs → mke2fs /dev/vdb → 挂载
#       → apk --root 直装 aarch64 包 (samba/ntfs-3g-progs/avahi/dbus) → 删 musl
#       → wget host 的 init.sh → sync 卸载 → 关VM
# 用法: ./guest-mk-bundle.sh   (HVF 无需 root)
set -e
cd "$(dirname "$0")"

QEMU=/Users/jack/Documents/anyfs/spike/qemu-11.1.2/build/qemu-system-aarch64
PIPE=serial-mkb

# bundle.img 不存在则创建 (192MB ext2 空盘, guest 内格式化)
[ -f bundle/bundle.img ] || mkfile -n 192m bundle/bundle.img

rm -f ${PIPE}.in ${PIPE}.out qemu-mkb.log qemu-mkb-err.log
mkfifo ${PIPE}.in ${PIPE}.out

cat ${PIPE}.out > qemu-mkb.log &
CATPID=$!

# 宿主侧 HTTP 服务 (slirp 中 10.0.2.2:8123) 提供 init.sh, 自给自足
( cd bundle && exec python3 -m http.server 8123 >/dev/null 2>&1 ) &
HTTPPID=$!
sleep 1
trap 'kill $CATPID $QEMUPID $HTTPPID 2>/dev/null' EXIT

"$QEMU" \
    -machine virt,accel=hvf \
    -cpu host -smp 2 -m 512 \
    -kernel alpine/vmlinuz-virt \
    -initrd alpine/initramfs-virt \
    -append "console=ttyAMA0" \
    -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
    -drive file=bundle/bundle.img,format=raw,if=virtio \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial pipe:${PIPE} \
    -display none -monitor none 2>qemu-mkb-err.log &
QEMUPID=$!
sleep 3
kill -0 $QEMUPID 2>/dev/null || { echo "FAIL: QEMU 启动失败:"; cat qemu-mkb-err.log; exit 1; }
echo "QEMU-STARTED (PID $QEMUPID)"

{
    sleep 15
    printf '\nroot\n' > ${PIPE}.in
    sleep 3
    printf 'ip link set eth0 up && udhcpc -i eth0 -q; echo G-NET-RC=$?\n' > ${PIPE}.in
    printf 'echo https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main > /etc/apk/repositories\n' > ${PIPE}.in
    printf 'apk add e2fsprogs >/dev/null 2>&1; echo G-APK-RC=$?\n' > ${PIPE}.in
    printf 'mke2fs -t ext2 -L ntfsbridge /dev/vdb 2>&1 | tail -2; echo G-MKFS-RC=$?\n' > ${PIPE}.in
    printf 'mkdir -p /mnt/b && mount -t ext2 /dev/vdb /mnt/b; echo G-MOUNT-RC=$?\n' > ${PIPE}.in
    sleep 2
    printf 'wget -O /tmp/mkrootfs.sh http://10.0.2.2:8123/mkrootfs.sh\n' > ${PIPE}.in
    sleep 2
    printf 'sh /tmp/mkrootfs.sh\n' > ${PIPE}.in
    printf 'sync; umount /mnt/b; echo G-UMOUNT-RC=$?\n' > ${PIPE}.in
    printf 'echo MKB-DONE\n' > ${PIPE}.in
} &

for i in $(seq 1 300); do
    grep -qa 'MKB-DONE' qemu-mkb.log 2>/dev/null && break
    sleep 1
done
kill $QEMUPID 2>/dev/null || true
sleep 1
kill $CATPID 2>/dev/null || true
echo "=== guest 输出 (关键行) ==="
grep -aE 'G-|MKB-DONE|MB|init.sh' qemu-mkb.log | tail -15
