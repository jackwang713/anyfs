#!/bin/bash
# build-pkg.sh — 打 AnyFS.pkg 安装包 (零成本路径: 内容自签, pkg 本身不签名)
# 用法: ./build-pkg.sh [版本号, 默认 0.1]   (普通用户)
set -e
set -o pipefail
ROOT=/Users/jack/anyfs
VERSION="${1:-0.1}"
STAGE_PKG=$ROOT/packaging/pkg-stage
SCRIPTS=$ROOT/packaging/pkg-scripts
OUT=$ROOT/packaging/AnyFS-$VERSION.pkg

echo "== 1/3 组自包含 .app =="
"$ROOT/packaging/assemble-app.sh" | grep -E 'OK|FAIL|完成'

echo "== 2/3 组 pkg stage =="
rm -rf "$STAGE_PKG" "$SCRIPTS"
mkdir -p "$STAGE_PKG/Applications" "$SCRIPTS"
cp -R "$ROOT/app/AnyFS.app" "$STAGE_PKG/Applications/"
cp "$ROOT/packaging/postinstall" "$SCRIPTS/postinstall"
chmod +x "$SCRIPTS/postinstall"

echo "== 3/3 pkgbuild =="
rm -f "$OUT"
# 组件属性: BundleIsRelocatable=false 禁止安装器把 App 重定位到系统里已存在的同名 bundle
# (注意: 必须写在 pkgbuild 的 component plist 里, 写 App 的 Info.plist 不生效 — 踩过)
COMPS=$ROOT/packaging/components.plist
pkgbuild --analyze --root "$STAGE_PKG" "$COMPS"
plutil -replace 0.BundleIsRelocatable -bool false "$COMPS"
pkgbuild --root "$STAGE_PKG" \
    --component-plist "$COMPS" \
    --scripts "$SCRIPTS" \
    --identifier com.anyfs.pkg \
    --version "$VERSION" \
    "$OUT"
du -sh "$OUT"
echo "完成. 测试安装: sudo installer -pkg $OUT -target /"
