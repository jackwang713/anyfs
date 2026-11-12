#!/usr/bin/env python3
# mk-initramfs.py — 构建 anyFS 自定义 initramfs (S3.5: 干掉 OpenRC/apk/modloop)
# 素材: stock initramfs-virt (busybox + 基础模块子集) + extra-modules/ (ntfs3/exfat,
#       从 guest modloop 提取)
# 产物: spike/alpine/initramfs-anyfs (gzip newc cpio)
#
# extra-modules 再生法 (modloop 更新后):
#   anyfsctl takeover <分区>; 然后 guest 内:
#   cp -L /lib/modules/$(uname -r)/kernel/fs/{ntfs3/ntfs3,exfat/exfat}.ko /mnt/<卷>/
#   经 SMB 拷回 spike/alpine/extra-modules/ (两模块零依赖, modules.dep 已验证)
import os, shutil, subprocess, sys, gzip, stat, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ALPINE = os.path.join(HERE, "alpine")
STOCK = os.path.join(ALPINE, "initramfs-virt")
EXTRA = os.path.join(ALPINE, "extra-modules")
OUT = os.path.join(ALPINE, "initramfs-anyfs")
KVER = "6.12.13-0-virt"

# 想要的模块 (basename); 依赖从 stock modules.dep 闭包解析
WANT = ["virtio_blk", "virtio_scsi", "virtio_net", "sd_mod",
        "ext4", "jbd2", "mbcache", "crc16", "libcrc32c", "crc32c_generic",
        "fat", "vfat", "msdos", "nls_cp437", "nls_utf8", "nls_ascii"]

INIT = r"""#!/bin/busybox sh
/bin/busybox --install -s /bin
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mdev -s
for m in virtio_blk virtio_scsi sd_mod virtio_net af_packet crc32c_generic libcrc32c ext4 vfat ntfs3 exfat; do
  modprobe $m 2>/dev/null
done
mdev -s
# loopback 必须显式拉起 (stock 由 OpenRC networking 代劳; 不拉则 127.0.0.1 全超时)
ip link set lo up
# init.sh 的 ln -sfn 需要父目录存在 (/usr/lib/samba, /etc/avahi, /usr/share/dbus-1)
# /var/run → /run: smbd 要 /var/run/samba/ncalrpc, stock 里它是符号链接
mkdir -p /opt /mnt /root /tmp /etc /usr/lib /usr/share /var /run /var/lib/dbus
ln -sfn /run /var/run
# dbus 的 machine-id: 缺失时 dbus-daemon 启动卡顿 (init.sh 已将其后台化, 双保险)
tr -d -- - < /proc/sys/kernel/random/uuid > /var/lib/dbus/machine-id
# daemon orchestrate 的握手法保持不变: 等 login: → 发 root → 等 :~#
echo "anyFS login:"
read _
export PS1='anyFS:~# '
cd /
exec sh
"""

UDHCPC = r"""#!/bin/sh
# busybox udhcpc default.script (canonical 精简): udhcpc 导出的变量是
# $ip/$subnet/$router/$dns (不是 $mask — 写错变量名会导致配址静默失败, 实测踩过)
# 必须写 /etc/resolv.conf: 缺失时 musl 解析器行为退化,
# smbd 处理首个 SMB 协商会卡 10s 超时 (2026-11-12 实测 10.20s→0.01s)
[ -n "$1" ] || exit 0
case "$1" in
deconfig)
  ifconfig $interface 0.0.0.0 ;;
bound|renew)
  ifconfig $interface $ip netmask ${subnet:-255.255.255.0}
  [ -n "$router" ] && route add default gw ${router%% *}
  : > /etc/resolv.conf
  for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done
  [ -s /etc/resolv.conf ] || echo "nameserver ${router%% *}" > /etc/resolv.conf ;;
esac
exit 0
"""

# newc cpio 头: magic + 13 个 8 位十六进制字段
# 字段序: ino mode uid gid nlink mtime filesize devmajor devminor rdevmajor rdevminor namesize check
def newc_entry(name, mode, data=b"", rdev=(0, 0), ino=1):
    fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, rdev[0], rdev[1],
              len(name) + 1, 0]
    hdr = b"070701" + b"".join(f"{x & 0xffffffff:08x}".encode() for x in fields)
    out = hdr + name.encode() + b"\0"
    out += b"\0" * ((4 - len(out) % 4) % 4)
    out += data + b"\0" * ((4 - len(data) % 4) % 4)
    return out

def main():
    tmp = tempfile.mkdtemp(prefix="iramfs-")
    stock = os.path.join(tmp, "stock")
    os.makedirs(stock)
    subprocess.run(["bsdtar", "-xf", STOCK, "-C", stock], check=True)
    modroot = os.path.join(stock, "lib", "modules", KVER)
    if not os.path.isdir(modroot):
        sys.exit(f"FAIL: {modroot} 不存在 (KVER 与 stock initramfs 不符?)")

    # 解析 stock modules.dep: path -> deps, basename -> path
    path2deps, base2path = {}, {}
    for line in open(os.path.join(modroot, "modules.dep")):
        line = line.strip()
        if not line or ":" not in line:
            continue
        p, _, ds = line.partition(":")
        p = p.strip()
        path2deps[p] = ds.split()
        base2path[os.path.basename(p)[:-3]] = p

    # 依赖闭包
    keep, stack = set(), []
    for w in WANT:
        if w not in base2path:
            sys.exit(f"FAIL: stock 模块子集里找不到 {w}")
        stack.append(base2path[w])
    while stack:
        p = stack.pop()
        if p in keep:
            continue
        keep.add(p)
        stack.extend(path2deps.get(p, []))
    missing = [p for p in keep if not os.path.exists(os.path.join(modroot, p))]
    if missing:
        sys.exit(f"FAIL: 模块文件缺失 {missing}")

    # 组装根树
    root = os.path.join(tmp, "root")
    os.makedirs(root)
    os.makedirs(os.path.join(root, "bin"))
    shutil.copy(os.path.join(stock, "bin", "busybox"), os.path.join(root, "bin", "busybox"))
    os.chmod(os.path.join(root, "bin", "busybox"), 0o755)
    # busybox 是动态链接 (pie), 必须带上 musl 加载器与 libc (实测缺了执行 /init 报 ENOENT)
    for f in ["ld-musl-aarch64.so.1", "libc.musl-aarch64.so.1"]:
        dst = os.path.join(root, "lib", f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(stock, "lib", f), dst)
    dst_modroot = os.path.join(root, "lib", "modules", KVER)
    for p in sorted(keep):
        dst = os.path.join(dst_modroot, p)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(modroot, p), dst)
    # 外部模块 (ntfs3/exfat/af_packet, 均零依赖 — 取自 modloop, stock 子集没有)
    for f, rel in [("ntfs3.ko", "kernel/fs/ntfs3/ntfs3.ko"),
                   ("exfat.ko", "kernel/fs/exfat/exfat.ko"),
                   ("af_packet.ko", "kernel/net/packet/af_packet.ko")]:
        src = os.path.join(EXTRA, f)
        if not os.path.exists(src):
            sys.exit(f"FAIL: {src} 不存在 (再生法见文件头注释)")
        dst = os.path.join(dst_modroot, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(src, dst)
        keep.add(rel)
    # 裁剪版 modules.dep (只含已收模块; busybox modprobe 按它解析依赖顺序)
    with open(os.path.join(dst_modroot, "modules.dep"), "w") as f:
        for p in sorted(keep):
            deps = " ".join(d for d in path2deps.get(p, []) if d in keep)
            f.write(f"{p}: {deps}\n".replace(": \n", ":\n"))

    def put(rel, content, mode=0o755):
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as fh:
            fh.write(content)
        os.chmod(dst, mode)
    put("init", INIT)
    put("usr/share/udhcpc/default.script", UDHCPC)
    # smbd 启动要解析 guest 账户 (nobody) 与 force user (root);
    # dbus 系统总线要 messagebus/avahi 用户与 netdev 组 (dbus 配置硬引用,
    # 缺了 dbus-daemon 拒绝启动 → avahi 连带死 → anyFS.local 不解析, App 挂载全灭)
    put("etc/passwd",
        "root:x:0:0:root:/root:/bin/sh\n"
        "nobody:x:65534:65534:nobody:/:/sbin/nologin\n"
        "messagebus:x:100:101:messagebus:/var/run/dbus:/sbin/nologin\n"
        "avahi:x:102:103:avahi:/var/run/avahi-daemon:/sbin/nologin\n", 0o644)
    put("etc/group",
        "root:x:0:\n"
        "nobody:x:65534:\n"
        "messagebus:x:101:\n"
        "avahi:x:103:\n"
        "netdev:x:104:\n", 0o644)
    put("etc/hosts", "127.0.0.1 localhost\n", 0o644)
    for d in ["proc", "sys", "dev", "opt", "mnt", "root", "tmp"]:
        os.makedirs(os.path.join(root, d), exist_ok=True)

    entries = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort(); filenames.sort()
        rel = os.path.relpath(dirpath, root)
        entries.append(newc_entry(rel, stat.S_IFDIR | 0o755))
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            r = os.path.normpath(os.path.join(rel, fn))
            data = open(fp, "rb").read()
            m = os.stat(fp).st_mode & 0o777
            entries.append(newc_entry(r, stat.S_IFREG | m, data))
    # 设备节点: kernel 打开 /dev/console 需要 (devtmpfs 挂载前)
    entries.insert(1, newc_entry("dev/console", stat.S_IFCHR | 0o600, rdev=(5, 1), ino=2))
    entries.insert(2, newc_entry("dev/null", stat.S_IFCHR | 0o666, rdev=(1, 3), ino=3))
    entries.append(newc_entry("TRAILER!!!", 0, ino=4))
    blob = b"".join(entries)
    blob += b"\0" * ((4 - len(blob) % 4) % 4)
    with gzip.open(OUT, "wb", compresslevel=9) as f:
        f.write(blob)
    print(f"OK: {OUT} {os.path.getsize(OUT)/1e6:.1f}MB, 模块 {len(keep)} 个")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()
