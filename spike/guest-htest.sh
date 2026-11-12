#!/bin/bash
# guest-htest.sh — slirp+hostfwd 绕过 vmnet 的 SMB 对照实验
# guest 445 → 宿主 127.0.0.1:1445, 直接用 python 发 SMB2 协商验证
set -u
cd "$(dirname "$0")"
. ./qemu-env.sh
PIPE=htest
rm -f ${PIPE}.in ${PIPE}.out htest.log
mkfifo ${PIPE}.in ${PIPE}.out
cat ${PIPE}.out > htest.log &
CATPID=$!

"$QEMU" \
  -machine "$MACHINE" -cpu host -smp 2 -m 128 \
  -kernel alpine/vmlinuz-virt -initrd alpine/initramfs-anyfs -append "console=$CONSOLE" \
  -drive file=bundle/bundle.img,format=raw,if=virtio,readonly=on \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:1445-:445 -device virtio-net-pci,netdev=n0 \
  -serial pipe:${PIPE} -display none -monitor none &
QPID=$!
trap 'kill $CATPID $QPID 2>/dev/null; rm -f ${PIPE}.in ${PIPE}.out' EXIT

wait_for() {
  local dl=$((SECONDS + $2))
  while [ $SECONDS -lt $dl ]; do
    grep -q "$1" htest.log && return 0
    sleep 0.2
  done
  return 1
}

wait_for "login:" 15 || { echo "FAIL: boot"; tail -10 htest.log; exit 1; }
echo "root" > ${PIPE}.in
wait_for ":~#" 10 || { echo "FAIL: shell"; exit 1; }
echo 'ip link set eth0 up && udhcpc -i eth0 -q && echo NET-""OK' > ${PIPE}.in
wait_for "NET-OK" 15 || { echo "FAIL: net"; tail -5 htest.log; exit 1; }
echo 'mount -t ext2 -o ro /dev/vda /opt && sh /opt/init.sh' > ${PIPE}.in
wait_for "BRIDGE-READY" 60 || { echo "FAIL: init"; tail -10 htest.log; exit 1; }
echo "guest 就绪, 从宿主经 hostfwd 打 SMB2 协商..."
python3 - << 'EOF'
import socket, struct, time
hdr = (bytes.fromhex("fe534d42") + struct.pack("<H",64) + struct.pack("<H",0)
       + struct.pack("<I",0) + struct.pack("<H",0) + struct.pack("<H",1)
       + struct.pack("<I",0) + struct.pack("<I",0) + struct.pack("<Q",1)
       + struct.pack("<I",0) + struct.pack("<I",0) + struct.pack("<Q",0) + b"\x00"*16)
body = (struct.pack("<H",36) + struct.pack("<H",2) + struct.pack("<H",1)
        + struct.pack("<H",0) + struct.pack("<I",0) + b"\x00"*16
        + struct.pack("<I",0) + struct.pack("<H",0) + struct.pack("<H",0)
        + struct.pack("<HH",0x0202,0x0210))
pkt = hdr + body
try:
    s = socket.create_connection(("127.0.0.1", 1445), timeout=6)
    t0 = time.time()
    s.sendall(struct.pack(">I", len(pkt)) + pkt)
    r = s.recv(4)
    if not r:
        print(f"FAIL: 服务端立即关闭 (EOF), {time.time()-t0:.2f}s")
    else:
        n = struct.unpack(">I", r)[0]
        data = s.recv(min(n, 64))
        print(f"OK: SMB2 响应 {n}B, magic={'对' if data[:4]==b'\xfeSMB' else '错'}, {time.time()-t0:.2f}s")
except Exception as e:
    print(f"FAIL: {e}")
EOF
echo 'poweroff' > ${PIPE}.in
sleep 2
