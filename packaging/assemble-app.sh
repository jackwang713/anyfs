#!/bin/bash
# assemble-app.sh — 组自包含 AnyFS.app (S6)
# 内容: UI + QEMU(含全部 dylib) + Alpine guest 资产 + daemon
# 用法: ./assemble-app.sh   (普通用户, 不需要 sudo)
set -e
set -o pipefail   # collect 经管道过滤时, 其失败也必须终止组包 (踩过: grep 吃掉退出码)
ROOT=/Users/jack/anyfs
APP=$ROOT/app/AnyFS.app
RES=$APP/Contents/Resources

echo "== 1/4 编译 UI =="
"$ROOT/app/build-app.sh"

echo "== 2/4 收集 QEMU + 依赖 =="
"$ROOT/packaging/collect-qemu.sh" "$ROOT/packaging/stage" | grep -E '已收集|OK|FAIL|WARN'

echo "== 3/4 组包 =="
mkdir -p "$RES/qemu" "$RES/guest" "$RES/daemon"
rm -rf "$RES/qemu/lib"
cp -R "$ROOT/packaging/stage/qemu/" "$RES/qemu/"
cp "$ROOT/spike/alpine/vmlinuz-virt" "$ROOT/spike/alpine/initramfs-virt" "$ROOT/spike/alpine/alpine-virt.iso" "$RES/guest/"
cp "$ROOT/spike/bundle/bundle.img" "$RES/guest/"
cp "$ROOT/daemon/anyfsd" "$RES/daemon/"
# daemon 必须随包签名 — FDA/TCC 按证书身份授权, 裸二进制装到系统目录后授权失效 (EPERM)
codesign --sign anyfs-dev --force "$RES/daemon/anyfsd"
# 注意: Authority 只在 -dvv (双v) 才打印, -dv 没有
# 注意: 不能用 codesign|grep -q 管道 — grep -q 提前退出致 codesign 吃 SIGPIPE(141), pipefail 下误判
SIGN_INFO=$(codesign -dvv "$RES/daemon/anyfsd" 2>&1)
echo "$SIGN_INFO" | grep -q "Authority=anyfs-dev" \
    && echo "OK: anyfsd 签名身份 anyfs-dev" \
    || { echo "FAIL: anyfsd 未用 anyfs-dev 签名 (检查钥匙串授权弹窗)"; exit 1; }
# bundle.img 在 VM 里以只读方式挂载, 打包时设为只读防意外
chmod 444 "$RES/guest/bundle.img"

echo "== 4/4 重签 .app (资源变更后密封失效, 必须重签) =="
codesign --sign anyfs-dev --force "$APP"

du -sh "$APP"
echo "完成: $APP"
echo "守护进程安装 (pkg 流程原型): sudo $ROOT/packaging/install-daemon-from-app.sh"
