#!/bin/bash
# guest-itest.sh — 自定义 initramfs 直启冒烟 (无 daemon/无直通盘)
# 流程: 起 QEMU(slirp) → 等 login: → 发 root → udhcpc → 挂 /opt → 列模块/网卡 → 关
set -u
cd "$(dirname "$0")"
. ./qemu-env.sh
PIPE=itest
rm -f ${PIPE}.in ${PIPE}.out itest.log
mkfifo ${PIPE}.in ${PIPE}.out
cat ${PIPE}.out > itest.log &
CATPID=$!

"$QEMU" \
  -machine "$MACHINE" -cpu host -smp 2 -m 128 \
  -kernel alpine/vmlinuz-virt -initrd alpine/initramfs-anyfs -append "console=$CONSOLE" \
  -drive file=alpine/alpine-virt.iso,format=raw,if=virtio,readonly=on \
  -drive file=bundle/bundle.img,format=raw,if=virtio,readonly=on \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -serial pipe:${PIPE} -display none -monitor none &
QPID=$!
trap 'kill $CATPID $QPID 2>/dev/null; rm -f ${PIPE}.in ${PIPE}.out' EXIT

wait_for() { # 标记 超时秒
  local dl=$((SECONDS + $2))
  while [ $SECONDS -lt $dl ]; do
    grep -q "$1" itest.log && return 0
    sleep 0.2
  done
  return 1
}

wait_for "login:" 15 || { echo "FAIL: 未到 login"; tail -20 itest.log; exit 1; }
echo "OK-1 到 login (${SECONDS}s)"
echo "root" > ${PIPE}.in
wait_for ":~#" 10 || { echo "FAIL: 未进 shell"; tail -20 itest.log; exit 1; }
echo "OK-2 进 shell (${SECONDS}s)"
echo 'ip link set eth0 up && udhcpc -i eth0 -q && echo NET-""OK' > ${PIPE}.in
wait_for "NET-OK" 15 || { echo "FAIL: 网络不通"; tail -20 itest.log; exit 1; }
echo "OK-3 网络 (${SECONDS}s)"
echo 'mount -t ext2 -o ro /dev/vdb /opt && echo OPT-""OK; ls /opt | head -3' > ${PIPE}.in
wait_for "OPT-OK" 10 || { echo "FAIL: bundle 挂载失败"; tail -20 itest.log; exit 1; }
echo "OK-4 bundle 挂载 (${SECONDS}s)"
echo 'sh /opt/init.sh' > ${PIPE}.in
wait_for "BRIDGE-INIT" 25 && echo "  [打点] BRIDGE-INIT (${SECONDS}s)" || echo "  [打点] BRIDGE-INIT 25s 未现 (${SECONDS}s)"
wait_for "BRIDGE-READY" 60 || {
  echo "FAIL: init.sh 未就绪, 收集诊断..."
  echo 'cat /tmp/smbd.err; echo ERR-""END' > ${PIPE}.in
  wait_for "ERR-END" 5
  echo 'export LD_LIBRARY_PATH=/opt/usr/lib:/opt/usr/lib/samba; /opt/usr/sbin/smbd -s /tmp/smb.conf 2>/tmp/e1; sleep 2; netstat -ltn | grep 445; echo NS-""END; tail -15 /var/log/samba/log.smbd 2>/dev/null; echo LG-""END' > ${PIPE}.in
  wait_for "NS-END" 10
  wait_for "LG-END" 5
  tail -40 itest.log
  exit 1
}
echo "OK-5 BRIDGE-READY (${SECONDS}s)"
echo 'lsmod | head -20; echo CHECK-""END' > ${PIPE}.in
wait_for "CHECK-END" 5
grep -E 'ntfs3|exfat|virtio|ext4' itest.log | tail -8
echo 'poweroff' > ${PIPE}.in
sleep 2
echo "全部通过"
