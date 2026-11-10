#!/bin/sh
# mkrootfs.sh — guest 内执行: 向 /mnt/b (bundle.img) 安装 rootfs (架构随 live 系统自动匹配)
# 由 guest-mk-bundle.sh 经 slirp HTTP (10.0.2.2:8123) 拉取后执行
set -e
apk add --root /mnt/b --initdb \
    --repository https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main \
    --keys-dir /etc/apk/keys \
    samba ntfs-3g-progs avahi dbus e2fsprogs
echo G-ROOTFS-RC=$?
# 删 bundle 内 musl (用 live 系统自带, 避免双 musl 冲突; 架构名用通配)
rm -f /mnt/b/lib/ld-musl-*.so.1 /mnt/b/usr/lib/libc.musl-*.so.1
echo G-MUSL-RC=$?
# 删掉 avahi 自带的 ssh/sftp 服务广告 (guest 没跑 sshd, 纯属广告空气;
# 也不发 _smb._tcp — Finder Network 里 Bonjour 条目和已挂载条目双份显示太乱;
# 挂载只依赖 avahi 的主机名 A 记录 anyFS.local, 与服务广告无关)
rm -f /mnt/b/etc/avahi/services/*.service
wget -O /mnt/b/init.sh http://10.0.2.2:8123/rootfs/init.sh
echo G-INIT-RC=$?
ls /mnt/b/
du -sh /mnt/b/
echo MKROOTFS-DONE
