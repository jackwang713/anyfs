#!/bin/bash
# native-deep-trim.sh — exFAT 原生(免接管) TRIM 深度检测 spike
# 验证 v1.1 拟落地的原生检测链路: macOS 原生挂载写入图案 → 位图 diff 定位
# (与 exfat-locate.py 目录解析法交叉对拍) → 删除(macOS 不发 TRIM) → 卸载 →
# 定向 DKIOCUNMAP (trimNative 同款动作) → F_NOCACHE 读回判决
# 用法: sudo ./native-deep-trim.sh <分区如disk7s2>
# 前提: 分区由 macOS 原生挂载(读写); Terminal.app (FDA) 里跑
set -e
cd "$(dirname "$0")"
PART="${1:?用法: sudo $0 <分区如disk7s2>}"
DEV="/dev/r$PART"
T0=$SECONDS

MNT=$(mount | grep "^/dev/$PART " | sed -n 's|^/dev/[^ ]* on \(.*\) (exfat.*|\1|p')
[ -n "$MNT" ] || { echo "FAIL: $PART 未被 macOS 原生挂载"; exit 1; }
touch "$MNT/.nt-wtest" 2>/dev/null && rm -f "$MNT/.nt-wtest" \
    || { echo "FAIL: $MNT 不可写 (TCC? 换 Terminal.app)"; exit 1; }
echo "挂载点: $MNT (读写 OK)"
rm -f "$MNT/.anyfs-trim-probe"   # 上轮中断的残留: 不清会让本轮 diff 无新分配位

echo "== 1/6 位图快照 A =="
./exfat-bitdiff.py "$DEV" snapshot /tmp/exfat-bm-A.bin

echo "== 2/6 经原生挂载埋图案: 32MB 0x5A + sync =="
python3 -c "import sys; sys.stdout.buffer.write(b'\x5a'*32*1024*1024)" > "$MNT/.anyfs-trim-probe"
sync

echo "== 3/6 位图快照 B + diff 定位 =="
./exfat-bitdiff.py "$DEV" snapshot /tmp/exfat-bm-B.bin
./exfat-bitdiff.py "$DEV" diff /tmp/exfat-bm-A.bin /tmp/exfat-bm-B.bin | tee /tmp/bitdiff.out
OFF=$(sed -n 's/BITDIFF-OFFSET=\([0-9]*\)/\1/p' /tmp/bitdiff.out)
[ -n "$OFF" ] || { echo "FAIL: 位图 diff 定位失败"; rm -f "$MNT/.anyfs-trim-probe"; exit 1; }

echo "== 3.5/6 交叉对拍: exfat-locate.py 目录解析法 =="
LOC=$(./exfat-locate.py "$DEV" .anyfs-trim-probe | grep '^LOCATE-OFFSET=')
echo "$LOC"
LOFF=$(echo "$LOC" | sed 's/LOCATE-OFFSET=//')
if [ "$LOFF" = "$OFF" ]; then
    echo "CROSS-CHECK OK: 两种定位法偏移一致 ($OFF)"
else
    echo "CROSS-CHECK MISMATCH: bitdiff=$OFF locate=$LOFF (以 locate 为准继续)"
    OFF=$LOFF
fi

echo "== 4/6 宿主 F_NOCACHE 预校验 =="
PRE=$(./unmap-live "$DEV" --verify "$OFF")
echo "$PRE"
PAT=$(echo "$PRE" | sed -n 's/.*pattern=\([0-9]*\).*/\1/p')
[ "${PAT:-0}" -gt 1038090 ] || { echo "FAIL: 预校验非全图案, 中止"; rm -f "$MNT/.anyfs-trim-probe"; exit 1; }

echo "== 5/6 经原生挂载删除 (macOS 不发 TRIM) + 卸载 =="
rm -f "$MNT/.anyfs-trim-probe"
sync
for i in 1 2 3; do
    diskutil unmount "/dev/$PART" && break
    echo "卸载失败, 重试 $i..."; sleep 2
done
mount | grep -q "^/dev/$PART " && { echo "FAIL: 卸载不掉"; exit 1; }

echo "== 6/6 定向 DKIOCUNMAP (trimNative 同款) + 读回判决 =="
./unmap-live "$DEV" --unmap "$OFF"
./unmap-live "$DEV" --verify "$OFF"
diskutil mount "$PART" >/dev/null 2>&1 || true
echo "---- 总耗时 $((SECONDS - T0))s ----"
