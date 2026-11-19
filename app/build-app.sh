#!/bin/bash
# build-app.sh — 编译并打包 AnyFS.app (CLT swiftc 直编, 无需 Xcode)
# 用法: ./build-app.sh   (普通用户运行, 不需要 sudo)
set -e
cd "$(dirname "$0")"
APP=AnyFS.app
BIN=anyfs-app

swiftc -O -parse-as-library -o "$BIN" Sources/AnyFSApp.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN"
cp Resources/menubar.png Resources/menubar@2x.png Resources/AppIcon.icns "$APP/Contents/Resources/"
# 本地化资源 (en.lproj 等; 开发语言=中文, key 即中文文案)
cp -R Resources/*.lproj "$APP/Contents/Resources/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$BIN</string>
    <key>CFBundleIdentifier</key><string>com.anyfs.app</string>
    <key>CFBundleName</key><string>anyFS</string>
    <key>CFBundleDisplayName</key><string>anyFS</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <!-- 禁止 pkg 安装器把 App 重定位到系统中已存在的同名 App (如构建目录里的) -->
    <key>BundleIsRelocatable</key><false/>
    <key>CFBundleVersion</key><string>0.1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <!-- 开发语言=中文: 中文系统直接显示源码 key, 英文系统查 en.lproj 映射 -->
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

if security find-identity -v -p codesigning 2>/dev/null | grep -q anyfs-dev; then
    codesign --sign anyfs-dev --force "$APP"
    echo "已用 anyfs-dev 签名"
else
    codesign --sign - --force "$APP"
    echo "ad-hoc 签名"
fi
echo "完成. 启动: open $APP"
