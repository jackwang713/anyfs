#!/bin/bash
# install-dev.sh — anyfsd 开发模式安装 (手动 launchd, 无需开发者账号)
# 用法: sudo ./install-dev.sh [--uninstall]
set -e
cd "$(dirname "$0")"

LABEL=com.anyfs.daemon
PLIST=/Library/LaunchDaemons/$LABEL.plist
BIN=/Library/PrivilegedHelperTools/anyfsd

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout system/$LABEL 2>/dev/null || true
    rm -f "$PLIST" "$BIN"
    echo "已卸载"
    exit 0
fi

[ -f anyfsd ] || swiftc -O -o anyfsd Sources/anyfsd/main.swift
# 有自签证书就用 (FDA 授权一次永久有效), 否则 ad-hoc (每次构建都要重新授权)
# 注意: 证书在普通用户的登录钥匙串, 查询和签名都必须以该用户身份执行 (不能在 sudo 下查 root 的)
SIGN_USER="${SUDO_USER:-$USER}"
if sudo -u "$SIGN_USER" security find-identity -v -p codesigning | grep -q anyfs-dev; then
    sudo -u "$SIGN_USER" codesign --sign anyfs-dev --force anyfsd
    echo "已用 anyfs-dev 自签证书签名 (用户: $SIGN_USER)"
else
    sudo -u "$SIGN_USER" codesign --sign - --force anyfsd
    echo "ad-hoc 签名 (提示: 可在钥匙串创建 anyfs-dev 代码签名证书以固定 FDA 授权)"
fi

mkdir -p /Library/PrivilegedHelperTools
cp anyfsd "$BIN"
chmod 755 "$BIN"
[ -f anyfsctl ] && cp anyfsctl /usr/local/bin/anyfsctl && chmod 755 /usr/local/bin/anyfsctl

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <false/>
    <key>MachServices</key>
    <dict>
        <key>com.anyfs.daemon</key>
        <true/>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/anyfsd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/anyfsd-stdout.log</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST"

launchctl bootout system/$LABEL 2>/dev/null || true
# 等服务完全退出 (SIGTERM 干净收尸最长 ~15s), 否则 bootstrap 会撞 "Bootstrap failed: 5"
for i in $(seq 1 30); do
    launchctl print system/$LABEL >/dev/null 2>&1 || break
    sleep 1
done
if launchctl bootstrap system "$PLIST" 2>/dev/null; then
    echo "已注册 launchd 服务"
else
    echo "(服务已注册, 跳过 bootstrap)"
fi
echo "已安装. 启动: sudo launchctl kickstart system/$LABEL (或任意 XPC 调用按需拉起)"
echo "停止: sudo launchctl kill SIGTERM system/$LABEL"
echo "日志: /var/log/anyfsd.log 和 /var/log/anyfsd-stdout.log"
