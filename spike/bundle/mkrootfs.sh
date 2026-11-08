#!/bin/sh
# mkrootfs.sh — guest 内执行: 向 /mnt/b (bundle.img) 安装 aarch64 rootfs
# 由 guest-mk-bundle.sh 经 slirp HTTP (10.0.2.2:8123) 拉取后执行
set -e
apk add --root /mnt/b --initdb \
    --repository https://mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/main \
    --keys-dir /etc/apk/keys \
    samba ntfs-3g-progs avahi dbus
echo G-ROOTFS-RC=$?
# 删 bundle 内 musl (用 live 系统自带, 避免双 musl 冲突)
rm -f /mnt/b/lib/ld-musl-aarch64.so.1 /mnt/b/usr/lib/libc.musl-aarch64.so.1
echo G-MUSL-RC=$?
wget -O /mnt/b/init.sh http://10.0.2.2:8123/rootfs/init.sh
echo G-INIT-RC=$?
ls /mnt/b/
du -sh /mnt/b/
echo MKROOTFS-DONE
