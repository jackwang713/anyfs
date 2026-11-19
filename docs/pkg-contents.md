# AnyFS 安装包（pkg）文件清单

以 `AnyFS-0.7.pkg`（约 113MB）为准。pkg 由两部分组成：**payload**（安装到 `/Applications/AnyFS.app`）和 **postinstall 脚本**（以 root 执行，生成 App 之外的系统文件）。

## 1. Payload：/Applications/AnyFS.app

### 可执行文件

| 文件 | 大小 | 用途 |
|---|---|---|
| `Contents/MacOS/anyfs-app` | 520K | 菜单栏 App 主程序（SwiftUI），用户看到的磁盘列表 UI |
| `Contents/Resources/daemon/anyfsd` | 340K | 特权守护进程副本；安装时由 postinstall 拷到 `/Library/PrivilegedHelperTools/anyfsd`，负责 XPC 服务、拉起 QEMU、接管/释放磁盘 |

### 内置 QEMU（不依赖系统安装 QEMU）

| 文件 | 大小 | 用途 |
|---|---|---|
| `Resources/qemu/bin/qemu-system-aarch64` | 35M | QEMU 主程序，运行 Alpine guest VM |
| `Resources/qemu/lib/*.dylib`（10 个） | 6.6M | QEMU 依赖库：libslirp（用户态网络，SMB 流量走它）、glib/gobject/gio/gmodule（QEMU 基础运行时）、pixman/jpeg/png（显示栈，headless 下基本闲置）、pcre2、zstd、intl |
| `Resources/qemu/share/qemu/pxe-virtio.rom`、`efi-virtio.rom` | 220K | virtio 网卡的 PXE/EFI 启动 ROM，QEMU 按约定路径查找，缺失会产生警告 |

### Guest VM 资产

| 文件 | 大小 | 用途 |
|---|---|---|
| `Resources/guest/vmlinuz-virt` | 9.1M | Alpine Linux 内核 |
| `Resources/guest/initramfs-anyfs` | 2.3M | **自定义精简 initramfs（默认）**：busybox + musl + 23 个内核模块，boot→就绪约 2 秒，是接管提速到 ~4.5s 的关键 |
| `Resources/guest/initramfs-virt` | 9.0M | Alpine 原版 initramfs，兜底备用（anyfsd.conf 中改 INITRD 可切回） |
| `Resources/guest/alpine-virt.iso` | 76M | Alpine 安装 ISO，提供内核模块仓库（modloop）和 apk 包源 |
| `Resources/guest/bundle.img` | 192M | 业务盘镜像：guest 的 init.sh、smbd/ntfs-3g 等工具、深度检测逻辑；VM 启动时挂为第二块盘。内容大量为零块，压缩率极高，是 pkg 远小于其体积的原因 |

### 其他

- `Contents/Info.plist` — bundle 元数据（ID `com.anyfs.app`、版本号）
- `Contents/Resources/AppIcon.icns`、`menubar.png`、`menubar@2x.png` — 图标资源
- `Contents/Resources/en.lproj/Localizable.strings` — 英文 UI 映射（开发语言=中文，中文系统直接显示源码文案，英文系统查此表）
- `Contents/Resources/zh-Hans.lproj/Localizable.strings` — 空表占位（确保中文偏好命中 zh-Hans 分支）
- `Contents/_CodeSignature/CodeResources` — anyfs-dev 自签名

## 2. postinstall 脚本生成的系统文件（不在 payload 中）

| 路径 | 用途 |
|---|---|
| `/Library/PrivilegedHelperTools/anyfsd` | 从 App 拷出的 daemon 正式安装位置 |
| `/Library/LaunchDaemons/com.anyfs.daemon.plist` | launchd 服务注册（MachServices 按需拉起，不常驻） |
| `/usr/local/etc/anyfsd.conf` | 资产路径配置：QEMU / KERNEL / INITRD / ISO / BUNDLE 五个键，指向 App 包内文件（开发机还可覆盖 MEM / SMP） |
| `/var/log/anyfsd-stdout.log` | daemon 运行日志（plist 中指定） |

postinstall 还处理 App 被安装器重定位的情况：默认路径找不到时用 Spotlight（`mdfind` 按 bundle ID）定位实际落点，再据此写 conf 路径。

## 3. 备注

- **anyfsctl 不在 pkg 中**：它是开发调试工具，经 dev 安装流程放到 `/opt/homebrew/bin/`，正式用户走 UI 无需它。
- 体积大头：bundle.img（192M，压缩后很小）+ alpine-virt.iso（76M）。ISO 实际只用到 modloop 和少量 apk，理论上可裁到 20M 以内（未做的优化项）。
