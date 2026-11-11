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

# 真实卷标映射 (daemon 经串口注入 /tmp/anyfs-names, 格式 tgt<N>=卷标):
# busybox blkid 读非 ASCII 卷标 (中文 FAT32 卷标的 OEM 字符集) 会乱码,
# 乱码共享名导致 SMB 枚举崩溃/挂载失败, 故卷标以宿主侧 diskutil 为准。
# 注意: 不能按 sda/sdb 字母对位 — SCSI 异步探测, 字母分配是竞争结果
# (2026-11-11 实踩: sda 落到 target1 上, 卷标张冠李戴);
# 唯一稳定对位 = sysfs 路径 targetH:0:N 末位 N (= daemon 侧的 scsi-id);
# host 号 H 因平台而异 (ARM=0, Intel/x86 实测=6), 不能写死
get_name() {  # $1=回退名(blkid LABEL) $2=target号
    if [ -f /tmp/anyfs-names ]; then
        n=$(sed -n "s|^tgt$2=||p" /tmp/anyfs-names | head -1)
        [ -n "$n" ] && { echo "$n"; return; }
    fi
    echo "$1"
}

# 设备枚举按 target 升序 (= daemon 的直通顺序), 不按字母
# (字母是异步竞争结果; 重复卷标去重后缀也要确定性)
tgt_of() {  # $1=块设备路径 → 打印 target 号 (无则空)
    readlink "/sys/block/$(basename "$1")" 2>/dev/null \
        | sed -n 's|.*target[0-9]*:0:\([0-9]*\)/.*|\1|p'
}
DEVICES=""
for t in $(seq 0 15); do
    for b in /sys/block/sd?; do
        [ -e "$b" ] || continue
        [ "$(tgt_of "$b")" = "$t" ] && DEVICES="$DEVICES /dev/$(basename "$b")"
    done
done
# target 对不上的 (理论上不会有) 追加末尾兜底
for b in /sys/block/sd?; do
    [ -e "$b" ] || continue
    case " $DEVICES " in *"/dev/$(basename "$b")"*) ;; *) DEVICES="$DEVICES /dev/$(basename "$b")";; esac
done

# --- 探测并挂载所有受支持分区 ---
# 整盘直通: 文件系统在 sda1..n; 分区直通: 每个直通分区是一块独立盘 (/dev/sda, /dev/sdb ...)
# (整盘的 blkid 只有 PTTYPE 没有 TYPE, 会被下面的类型过滤自动跳过, 故两种形态可共用一份列表)
USED_NAMES=" "
for part in $DEVICES; do
    [ -b "$part" ] || continue
    info=$(blkid "$part" 2>/dev/null) || continue
    eval "$(echo "$info" | sed 's/^[^ ]* //;s/\bUUID="[^"]*"//g')" 2>/dev/null
    [ -z "${TYPE:-}" ] && continue
    case "$TYPE" in ntfs|exfat|vfat|ext4|ext3|ext2) ;; *) continue;; esac
    # 卷标优先用 daemon 注入的真实值 (按 target 对位), 回退 blkid
    name=$(get_name "$LABEL" "$(tgt_of "$part")")
    # 名字消毒: 空格转下划线; 重名去重 (同卷标多盘按 target 序加 -2/-3)
    name=$(echo "$name" | tr ' ' '_')
    base=$name; k=2
    while case "$USED_NAMES" in *" $name "*) true;; *) false;; esac; do
        name="$base-$k"; k=$((k+1))
    done
    USED_NAMES="$USED_NAMES$name "
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
            # -o discard: 在线养护 (与 ntfs3/ext4 一致, 删除即 TRIM);
            # fstrim 保留为补充手段 (修复历史删除的死块)
            mount -t "$TYPE" -o discard "$part" "$mp" 2>/dev/null \
                && { fstrim "$mp" >/dev/null 2>&1; echo "BRIDGE-MOUNT $TYPE $part $name OK"; } \
                || echo "BRIDGE-MOUNT $TYPE $part $name FAIL"
            ;;
        ext4|ext3|ext2)
            # -o discard: 在线养护 (与 ntfs3 一致, 删除即 TRIM); fstrim 作为补充手段
            mount -t "$TYPE" -o discard "$part" "$mp" 2>/dev/null \
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
    # smbd 默认会经 avahi 自注册 _smb._tcp (NetBIOS 名大写 ANYFS),
    # 与已挂载条目 anyFS.local 在 Finder Network 双份显示; 主机名 A 记录由 avahi 宣告不受影响
    echo '  multicast dns register = no'
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
        # ext4 等 POSIX 文件系统: 新建文件/目录人人可写, 拿回 Linux 主机后普通用户可正常增删
        echo '  create mask = 0666'
        echo '  directory mask = 0777'
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
