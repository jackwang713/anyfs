#!/bin/bash
# trim-live-test.sh — TRIM 金标准 (图案读回法) 宿主侧完整流程
# 原理: ① 经 macOS 已挂载的卷写入 32MB 0x5A 图案文件 (落在盘上空余区)
#       ② 只读解析 exFAT 元数据直接定位文件物理偏移 (免全盘扫描; 失败回退扫描)
#       ③ 删除文件 — macOS 的 exFAT/NTFS 驱动对 USB 不发 TRIM, 图案原样留在 NAND
#       ④ unmap-live --unmap 对该 1MB 发 DKIOCUNMAP (安全闸: 必须 >99% 是图案才动手)
#          → 读回: 全零 = TRIM-EXECUTED; 图案在 = TRIM-SWALLOWED (被桥吞)
# 用法: sudo ./trim-live-test.sh disk7
#   卷需先被 macOS 挂载; 脚本中途卸载整盘 (裸盘直读要独占), 结束自动挂回
#   注意: 需在"有完全磁盘访问权限"的终端里跑 (macOS 自带 Terminal.app)
set -e
cd "$(dirname "$0")"
DISK="${1:?用法: sudo $0 <diskN> (如 disk7)}"
[ -x ./unmap-live ] || clang -O2 -o unmap-live unmap-live.c
[ -x ./unmap-probe ] || clang -O2 -o unmap-probe unmap-probe.c

VOL=$(mount | grep -E "^/dev/${DISK}(s[0-9]+)? on " | sed -E 's|^[^ ]+ on (.*) \(.*$|\1|' | head -1)
[ -n "$VOL" ] || { echo "FAIL: $DISK 没有已挂载的卷, 先让 macOS 挂上再跑"; exit 1; }

echo "== 1/5 埋图案: 32MB 0x5A → $VOL/.trim-live-pattern =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$VOL/.trim-live-pattern"
sync

echo "== 2/5 只读解析 exFAT 元数据, 定位图案文件物理偏移 =="
OFF=$(python3 ./exfat-locate.py "/dev/r$DISK" ".trim-live-pattern" | tee /dev/stderr | sed -n 's/^LOCATE-OFFSET=//p')

echo "== 3/5 删除图案文件 (macOS 不发 TRIM, 图案留盘) =="
rm "$VOL/.trim-live-pattern"
sync

echo "== 4/5 卸载 $DISK (裸盘直读需要独占; QuickLook 缩略图可能占用, 重试 3 次) =="
for i in 1 2 3; do
    diskutil unmountDisk force "$DISK" 2>&1 && break
    [ "$i" = 3 ] || { echo "卸载失败, 2s 后重试 ($i/3)..."; sleep 2; }
done
sleep 1
if mount | grep -qE "^/dev/${DISK}(s[0-9]+)? on "; then
    echo "FAIL: $DISK 卸载不掉, 有程序占用"; exit 1
fi
trap 'echo "挂回 $DISK ..."; diskutil mountDisk "$DISK" >/dev/null 2>&1 || true' EXIT

echo "== 5/5 探测 + UNMAP + 读回验证 =="
./unmap-probe "/dev/r$DISK"
if [ -n "$OFF" ]; then
    ./unmap-live "/dev/r$DISK" --unmap "$OFF"
else
    echo "(定位失败, 回退全盘扫描模式, 大容量盘可能要几分钟)"
    ./unmap-live "/dev/r$DISK"
fi
