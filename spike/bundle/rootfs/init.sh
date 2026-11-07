#!/bin/sh
# NTFS-Bridge guest 初始化: 探测分区 → 挂载 → 起 smbd → 串口报 READY
# 运行环境: Alpine live + bundle 挂载于 /opt
export LD_LIBRARY_PATH=/opt/usr/lib:/opt/usr/lib/samba
# samba 编译期插件/模块路径写死为 /usr/lib/samba, 链接到 bundle
ln -sfn /opt/usr/lib/samba /usr/lib/samba
mkdir -p /var/log/samba /var/lib/samba/private /var/cache/samba /run/samba

# --- mDNS: Finder 显示 anyFS 而非 IP ---
hostname anyFS
ln -sfn /opt/etc/avahi /etc/avahi
ln -sfn /opt/usr/share/dbus-1 /usr/share/dbus-1
mkdir -p /run/dbus
addgroup -S messagebus 2>/dev/null
adduser -S -H -D messagebus 2>/dev/null
addgroup -S avahi 2>/dev/null
adduser -S -H -D avahi 2>/dev/null
/opt/usr/bin/dbus-daemon --system --fork 2>/dev/null
/opt/usr/sbin/avahi-daemon --daemonize 2>/dev/null

echo "BRIDGE-INIT $(date)"

mkdir -p /mnt

# --- 探测并挂载所有受支持分区 ---
# 整盘直通: 文件系统在 sda1..n; 分区直通: 每个直通分区是一块独立盘 (/dev/sda, /dev/sdb ...)
# (整盘的 blkid 只有 PTTYPE 没有 TYPE, 会被下面的类型过滤自动跳过, 故两种形态可共用一份列表)
for part in /dev/sd[a-z][0-9]* /dev/sd[a-z]; do
    [ -b "$part" ] || continue
    info=$(blkid "$part" 2>/dev/null) || continue
    eval "$(echo "$info" | sed 's/^[^ ]* //;s/\bUUID="[^"]*"//g')" 2>/dev/null
    [ -z "${TYPE:-}" ] && continue
    case "$TYPE" in ntfs|exfat|vfat|ext4|ext3|ext2) ;; *) continue;; esac
    name="${LABEL:-$(basename $part)}"
    # 名字消毒: 空格转下划线
    name=$(echo "$name" | tr ' ' '_')
    mp="/mnt/$name"
    mkdir -p "$mp"
    case "$TYPE" in
        ntfs)
            /opt/usr/bin/ntfsfix -d "$part" >/dev/null 2>&1
            mount -t ntfs3 -o discard "$part" "$mp" 2>/dev/null \
                && echo "BRIDGE-MOUNT ntfs $part $name OK" \
                || echo "BRIDGE-MOUNT ntfs $part $name FAIL"
            ;;
        exfat|vfat)
            mount -t "$TYPE" "$part" "$mp" 2>/dev/null \
                && { fstrim "$mp" >/dev/null 2>&1; echo "BRIDGE-MOUNT $TYPE $part $name OK"; } \
                || echo "BRIDGE-MOUNT $TYPE $part $name FAIL"
            ;;
        ext4|ext3|ext2)
            mount -t "$TYPE" "$part" "$mp" 2>/dev/null \
                && echo "BRIDGE-MOUNT $TYPE $part $name OK" \
                || echo "BRIDGE-MOUNT $TYPE $part $name FAIL"
            ;;
    esac
done

# --- 生成 smb.conf ---
{
    echo '[global]'
    echo '  workgroup = WORKGROUP'
    echo '  server string = anyFS'
    echo '  security = user'
    echo '  map to guest = Bad User'
    echo '  log level = 1'
    echo '  load printers = no'
    echo '  disable netbios = yes'
    echo '  smb ports = 445'
    echo '  use sendfile = yes'
    echo '  socket options = TCP_NODELAY SO_RCVBUF=262144 SO_SNDBUF=262144'
    for d in /mnt/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        echo "[$n]"
        echo "  path = $d"
        echo '  read only = no'
        echo '  guest ok = yes'
        echo '  force user = root'
    done
} > /tmp/smb.conf

# --- 启动 smbd ---
/opt/usr/sbin/smbd -s /tmp/smb.conf 2>/tmp/smbd.err
# 等待服务就绪: 探 445 端口 (比 pgrep 可靠, 且等待 tdb 初始化)
i=0
while [ $i -lt 15 ]; do
    netstat -ltn 2>/dev/null | grep -q ':445 ' && break
    sleep 1
    i=$((i+1))
done
if netstat -ltn 2>/dev/null | grep -q ':445 '; then
    echo "BRIDGE-READY"
else
    echo "BRIDGE-FAIL smbd 未启动:"
    cat /tmp/smbd.err
fi
