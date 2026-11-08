#!/bin/bash
# collect-qemu.sh — 收集 QEMU + 全部第三方依赖到 staging (按 uname -m 自动选架构)
# 产物布局 (最终拷入 .app/Contents/Resources/qemu/):
#   stage/qemu/bin/qemu-system-{x86_64,aarch64}
#   stage/qemu/lib/*.dylib
#   stage/qemu/share/qemu/*.bin|*.rom   (QEMU 从 <exe_dir>/../share/qemu 找固件)
# 引用规则: qemu → @executable_path/../lib/libX; dylib 互引 → @loader_path/libY
# 用法: ./collect-qemu.sh [stage目录, 默认 ./stage]
# 可覆盖: QEMU_SRC / DEP_PREFIX / SIGN_ID
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
STAGE="${1:-stage}"

# 架构分支: 二进制名 / 机器类型 / 固件集 / 依赖前缀默认值
case "$(uname -m)" in
  arm64)
    QEMU_BIN=$QEMU_BIN
    MACHINE="virt,accel=hvf"
    # ARM (-kernel 直启) 不需要 BIOS, 但 virtio-net-pci 初始化时要能找到 option ROM
    # (不执行, 仅查找; 实测缺失直接拒绝启动: failed to find romfile)
    FW_FILES="efi-virtio.rom pxe-virtio.rom"
    DEP_PREFIX_DEFAULT=/opt/homebrew ;;   # ARM 用 Homebrew
  x86_64)
    QEMU_BIN=qemu-system-x86_64
    MACHINE="q35,accel=hvf"
    # x86 q35 最小固件集 (全量 pc-bios 79 个文件含所有架构, 只取需要的; 缺失=硬失败)
    # QEMU 11 起非 DMA 变体 (linuxboot.bin/multiboot.bin) 已移除, 只剩 *_dma
    FW_FILES="bios-256k.bin kvmvapic.bin linuxboot_dma.bin \
              multiboot_dma.bin vgabios-stdvga.bin vgabios-virtio.bin \
              pxe-virtio.rom efi-virtio.rom"
    DEP_PREFIX_DEFAULT=/opt/local ;;      # Intel 用 MacPorts
  *) echo "FAIL: 未知架构 $(uname -m)"; exit 1 ;;
esac

QEMU_SRC="${QEMU_SRC:-$ROOT/spike/qemu-11.1.2/build/$QEMU_BIN}"
# 注意: 固件在源码树 pc-bios/ (预编译 blob), build/pc-bios/ 只有 edk2 等构建产物
FW_SRC="$ROOT/spike/qemu-11.1.2/pc-bios"
QDEST="$STAGE/qemu"
LIBDEST="$QDEST/lib"
FWDEST="$QDEST/share/qemu"

rm -rf "$QDEST"
mkdir -p "$QDEST/bin" "$LIBDEST" "$FWDEST"
cp "$QEMU_SRC" "$QDEST/bin/$QEMU_BIN"

for f in $FW_FILES; do
    [ -f "$FW_SRC/$f" ] && cp "$FW_SRC/$f" "$FWDEST/" || { echo "FAIL: 固件缺失 $FW_SRC/$f"; exit 1; }
done
echo "已收集 $(ls "$FWDEST" | wc -l | tr -d ' ') 个固件文件"

is_sys() { case "$1" in /usr/lib/*|/System/*) return 0;; *) return 1;; esac }

# 第三方依赖前缀: ARM/Homebrew=/opt/homebrew, Intel/MacPorts=/opt/local (默认随架构, 可覆盖)
DEP_PREFIX="${DEP_PREFIX:-$DEP_PREFIX_DEFAULT}"

# BFS 收集依赖闭包 (收所有非系统库, 前缀无关; 只有下面两处 install_name_tool 按前缀过滤)
SEEN="$STAGE/.seen"
: > "$SEEN"
queue=("$QDEST/bin/$QEMU_BIN")
while [ ${#queue[@]} -gt 0 ]; do
    f="${queue[0]}"
    queue=("${queue[@]:1}")
    for dep in $(otool -L "$f" | awk 'NR>1{print $1}'); do
        is_sys "$dep" && continue
        case "$dep" in @*) continue;; esac
        [ -f "$dep" ] || { echo "WARN: 依赖不存在 $dep (来自 $f)"; continue; }
        base=$(basename "$dep")
        if ! grep -qx "$base" "$SEEN"; then
            echo "$base" >> "$SEEN"
            cp "$dep" "$LIBDEST/$base"
            chmod 755 "$LIBDEST/$base"
            queue+=("$LIBDEST/$base")
        fi
    done
done
COUNT=$(wc -l < "$SEEN" | tr -d ' ')
rm -f "$SEEN"
echo "已收集 $COUNT 个依赖库"

# 重写 dylib: id → @loader_path/libX, 互引 → @loader_path/libY
for lib in "$LIBDEST"/*.dylib; do
    base=$(basename "$lib")
    install_name_tool -id "@loader_path/$base" "$lib"
    for dep in $(otool -L "$lib" | awk 'NR>1{print $1}' | grep "^$DEP_PREFIX"); do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$lib"
    done
done

# 重写 qemu 主二进制: $DEP_PREFIX/lib/libX → @executable_path/../lib/libX
for dep in $(otool -L "$QDEST/bin/$QEMU_BIN" | awk 'NR>1{print $1}' | grep "^$DEP_PREFIX"); do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$QDEST/bin/$QEMU_BIN"
done

# 重签 (本地开发用 anyfs-dev; 分发时换 Developer ID, 同一脚本参数化)
# 批量单次调用 — 避免每个文件触发一次钥匙串授权弹窗
# 注意: QEMU 必须带 entitlements 重签 (证书签名后 HVF 强制检查 com.apple.security.hypervisor;
#       ad-hoc 签名豁免 — 开发期 spike 二进制裸跑没事的原因)
SIGN_ID="${SIGN_ID:-anyfs-dev}"
codesign --sign "$SIGN_ID" --force "$LIBDEST"/*.dylib
codesign --sign "$SIGN_ID" --force --entitlements $ROOT/spike/entitlements.plist "$QDEST/bin/$QEMU_BIN"
codesign -d --entitlements - "$QDEST/bin/$QEMU_BIN" 2>/dev/null | grep -q 'security.hypervisor' \
    && echo "OK: hypervisor entitlement 已嵌入" \
    || { echo "FAIL: hypervisor entitlement 丢失, HVF 将不可用"; exit 1; }
# 注意: Authority 只在 -dvv (双v) 才打印, -dv 没有
# 注意: 不能用 codesign|grep -q 管道 — grep -q 提前退出致 codesign 吃 SIGPIPE(141), pipefail 下误判
SIGN_INFO=$(codesign -dvv "$QDEST/bin/$QEMU_BIN" 2>&1)
echo "$SIGN_INFO" | grep -q "Authority=$SIGN_ID" \
    || { echo "FAIL: qemu 签名身份不是 $SIGN_ID (钥匙串弹窗被拒?)"; exit 1; }

echo "=== 验证: 依赖应全部指向 @executable_path/@loader_path 或系统库 ==="
otool -L "$QDEST/bin/$QEMU_BIN" | awk 'NR>1{print $1}' | grep -v '^/usr/lib\|^/System\|^@' && echo "FAIL: 仍有未重写引用" || echo "OK: 引用全部内聚"

# 端到端冒烟: 固件 + HVF + entitlement + virtio-net romfile 查找一次验证 (无需 root, 无需磁盘)
# 注意: 不能加 -S — 停住的 guest 可能不触发固件加载, 造成假阳性 (踩过)
# 注意: 必须带 virtio-net-pci — 裸机器测不到 romfile 缺失 (ARM 踩过: efi-virtio.rom 漏收集)
"$QDEST/bin/$QEMU_BIN" -machine "$MACHINE" -cpu host -smp 1 -m 64 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -monitor none &
TPID=$!
sleep 2
if kill -0 $TPID 2>/dev/null; then
    kill $TPID 2>/dev/null
    echo "OK: 固件+HVF 端到端启动通过 ($MACHINE)"
else
    echo "FAIL: QEMU 端到端启动失败 (BIOS 固件或 HVF 问题)"
    exit 1
fi
