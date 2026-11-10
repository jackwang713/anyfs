#!/bin/bash
# guest-blkdiscard-test.sh — 判定 guest 的 SCSI UNMAP 路径本身是否工作 (绕过 fstrim/exfat)
# 背景: QMP qemu-io discard 已证明 QEMU 补丁路径正常; fstrim(FITRIM) 却无效
# 方法: guest 内 umount → blkdiscard 定点 → 重新挂载 → 结果写回共享; 宿主 F_NOCACHE 判决
# 用法: sudo ./guest-blkdiscard-test.sh <分区> <共享名> <偏移字节>
#   例: sudo ./guest-blkdiscard-test.sh disk7s2 KIOXIA 832183844864  (上轮的残留图案区)
# 注意: guest 会短暂卸载/重挂 exfat, SMB 连接会瞬断一下
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区> <共享名> <偏移字节>}"
SHARE="${2:?缺少共享名}"
OFF="${3:?缺少偏移字节}"
VOL="/Volumes/$SHARE"
[ -d "$VOL" ] || { echo "FAIL: $VOL 不存在"; exit 1; }
PIPE=/tmp/anyfsd-serial
RESULT=.blkd-result.txt
SCRIPT=.blkd-$$.sh

echo "== 1/3 靶子确认 (偏移 $OFF 必须仍是全图案) =="
PRE=$(./unmap-live "/dev/r$PART" --verify "$OFF")
echo "$PRE"
echo "$PRE" | grep -q "pattern=1048576" || { echo "FAIL: 靶子不是全图案, 换个偏移"; exit 1; }

echo "== 2/3 guest: umount → blkdiscard → remount =="
rm -f "$VOL/$RESULT"
cat > "$VOL/$SCRIPT" <<GUESTEOF
M=/mnt/$SHARE
DEV=\$(mount | grep " on \$M " | cut -d' ' -f1)
if umount \$M 2>/tmp/um.err; then
    blkdiscard -o $OFF -l 1048576 \$DEV 2>/tmp/bd.err
    RC=\$?
    mount -t exfat \$DEV \$M 2>/tmp/m.err
    RC_M=\$?
    echo "BLKD:RC=\$RC err=\$(cat /tmp/bd.err) remount-rc=\$RC_M" > \$M/$RESULT
else
    echo "BLKD:UMOUNT-FAIL err=\$(cat /tmp/um.err)" > \$M/$RESULT
fi
rm -f \$M/$SCRIPT
GUESTEOF
printf 'sh /mnt/%s/%s\n' "$SHARE" "$SCRIPT" > "$PIPE.in"
for i in $(seq 1 20); do
    sleep 3
    [ -f "$VOL/$RESULT" ] && break
    printf '.'
done
echo
[ -f "$VOL/$RESULT" ] && cat "$VOL/$RESULT" || { echo "FAIL: 超时无结果"; exit 1; }

echo "== 3/3 宿主 F_NOCACHE 读回判决 =="
./unmap-live "/dev/r$PART" --verify "$OFF"
rm -f "$VOL/$RESULT" "$VOL/$SCRIPT"
