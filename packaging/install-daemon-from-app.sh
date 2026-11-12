#!/bin/bash
# install-daemon-from-app.sh — 从自包含 AnyFS.app 安装 daemon (pkg postinstall 的原型)
# 用法: sudo ./install-daemon-from-app.sh [/path/to/AnyFS.app]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/app/AnyFS.app}"
RES="$APP/Contents/Resources"
LABEL=com.anyfs.daemon
PLIST=/Library/LaunchDaemons/$LABEL.plist
BIN=/Library/PrivilegedHelperTools/anyfsd

[ -x "$RES/daemon/anyfsd" ] || { echo "FAIL: $RES/daemon/anyfsd 不存在, 先跑 assemble-app.sh"; exit 1; }

mkdir -p /Library/PrivilegedHelperTools /usr/local/etc
cp "$RES/daemon/anyfsd" "$BIN"
chmod 755 "$BIN"

# 资产路径指向 .app 内 — 自包含的关键
case "$(uname -m)" in arm64) QB=qemu-system-aarch64;; *) QB=qemu-system-x86_64;; esac
cat > /usr/local/etc/anyfsd.conf <<EOF
QEMU=$RES/qemu/bin/$QB
KERNEL=$RES/guest/vmlinuz-virt
INITRD=$RES/guest/initramfs-anyfs
ISO=$RES/guest/alpine-virt.iso
BUNDLE=$RES/guest/bundle.img
EOF
chmod 644 /usr/local/etc/anyfsd.conf

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
        <key>$LABEL</key>
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
for i in $(seq 1 30); do
    launchctl print system/$LABEL >/dev/null 2>&1 || break
    sleep 1
done
if launchctl bootstrap system "$PLIST" 2>/dev/null; then
    echo "已注册 launchd 服务"
else
    echo "(服务已注册, 跳过 bootstrap)"
fi
echo "已安装. 验证: anyfsctl status (首次接管前确认 FDA 已授权 anyfsd)"
