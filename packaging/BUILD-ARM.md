# anyFS Apple Silicon (ARM64) 编译打包指南

目标：在 M 系 Mac 上产出 `AnyFS-arm64.pkg`。与 Intel 包的差异和步骤如下。
Intel 版打包流程见 `packaging/` 各脚本注释及 `ntfs-bridge-app-plan.md` S6 节，本文只写差异。

## 0. 核心差异（为什么是独立包，不是 universal）

| 层 | Intel 包 | ARM 包 | 原因 |
|---|---|---|---|
| QEMU | qemu-system-x86_64 | **qemu-system-aarch64** | 二进制按架构编译 |
| guest 形态 | `-machine q35` + SeaBIOS | **`-machine virt`** + UEFI(edk2) 或 `-kernel` 直启 | ARM 无 q35/SeaBIOS |
| Alpine guest | x86_64 内核/initrd/ISO | **aarch64** 内核/initrd/ISO | **Apple Silicon 的 HVF 只能虚拟化 ARM guest** |
| bundle.img | x86_64 smbd/ntfs-3g 等 | **aarch64 版**（apk 从 aarch64 仓库拉） | guest 用户态架构随内核 |
| 包管理 | MacPorts（brew 已停 macOS 13 bottle） | **Homebrew**（ARM 全量 bottle，无需 MacPorts） | collect-qemu.sh 已用 DEP_PREFIX 参数化 |
| TRIM 补丁 | file-posix.c DKIOCUNMAP | **同一份补丁直接适用**（`__APPLE__` 守卫，与 CPU 架构无关） | spike/patches/ |
| 签名/entitlements/dylib 收集/pkg | 同一套脚本 | 同一套脚本 | 无差异 |

构建机：需要一台 Apple Silicon Mac（交叉构建不值当：dylib 收集、HVF 冒烟都要本机）。
**保留 Intel 构建机**：低版本 macOS 构建向高版本跑的规则同样适用，ARM 包也建议在能到的最低 macOS 版本上构建。

## 1. QEMU (aarch64)

qemu 源码树不在 git 仓库里（太大），ARM 机器上需重新下载 11.1.2 源码再编译：

```bash
# 源码下载 (清华 MacPorts distfiles 镜像实测 41.6MB/s, 或 qemu.org):
#   https://mirrors.tuna.tsinghua.edu.cn/macports/distfiles/qemu/qemu-11.1.2.tar.xz

# ARM 上用 Homebrew 装构建依赖即可, 不需要 MacPorts:
brew install meson ninja pkg-config glib pixman libslirp
# ARM Mac 的 macOS ≥14, CLT clang 够新 — Intel 机上"clang-17 太老"的坑不存在,
# --cc/--cxx/--objcc 三个参数可省; conda python 的坑同理, 确认 /usr/bin/python3 优先即可

# 编译 (完整选项说明见 ntfs-bridge-app-plan.md 第十一节"编译 QEMU 11.1.2"):
git apply spike/patches/qemu-11.1.2-macos-dkiocunmap-trim.patch   # 在解压的 qemu-11.1.2 里 patch -p1
./configure --target-list=aarch64-softmmu --enable-hvf --enable-slirp \
    --disable-docs --disable-gtk --disable-sdl --disable-cocoa \
    --disable-spice --disable-usb-redir --disable-opengl \
    --disable-guest-agent --disable-xen
make -j$(sysctl -n hw.ncpu)
```

验证：`-machine virt,accel=hvf` 起得来（冒烟脚本同 Intel，见 collect-qemu.sh 端到端段）。

## 2. guest 启动参数差异（daemon 需要按架构分支）

```diff
- -machine q35,accel=hvf -cpu host
+ -machine virt,accel=hvf -cpu host
- -kernel vmlinuz-virt -initrd initramfs-virt -append "console=ttyS0"
+ -kernel vmlinuz-virt(aarch64) -initrd initramfs-virt(aarch64) -append "console=ttyAMA0"
```

- ARM virt 机器的串口是 **ttyAMA0**（不是 ttyS0），daemon 的 `console=` 和登录探测不变但要改设备名
- 固件不同：ARM 不需要 bios-256k.bin/vgabios；`-kernel` 直启可完全跳过 UEFI（最简），否则用 edk2-aarch64-code.fd
- virtio-scsi / vmnet-shared / discard=unmap 参数与 Intel 完全一致

## 3. Alpine aarch64 guest

```bash
# spike/build.sh 已按 uname -m 自动选架构, ARM 机器上直接跑即可:
./spike/build.sh   # 下载 alpine-virt-3.21.3-aarch64.iso 并抽取内核/initrd
# 网络慢可换清华镜像: mirrors.tuna.tsinghua.edu.cn/alpine/v3.21/releases/aarch64/
```

bundle 重建：在构建机上直接跑 `sudo ./spike/guest-mk-bundle.sh` 即可——
guest 内 `apk --root` 按 live 系统架构自动拉对应包（samba/ntfs-3g-progs/avahi/dbus），
musl 清理按通配符匹配，两个平台零差异。（旧的 rootfs/ 目录 + bundle.tar.gz 流程已废弃，
仅 init.sh 仍从 `spike/bundle/rootfs/init.sh` 取用）

**注意**：spike 脚本已参数化——各脚本统一 source `spike/qemu-env.sh`，
按 `uname -m` 自动选择 QEMU 二进制 / 机器类型（q35↔virt）/ 串口（ttyS0↔ttyAMA0），
两个平台同一份脚本，无需手改。

**init.sh 无需改动**（blkid/挂载/smbd 全部架构无关）。

## 4. 打包脚本差异

打包脚本已全部参数化，两个平台同一份代码、零手改：

- `collect-qemu.sh`：按 `uname -m` 自动选择 `QEMU_BIN`（x86_64/aarch64）、冒烟机器类型
  （q35↔virt）、固件集（x86=BIOS 8 件；ARM=仅 efi-virtio.rom/pxe-virtio.rom 两个 option ROM）、
  依赖前缀默认值（Intel=/opt/local, ARM=/opt/homebrew，均可用 `DEP_PREFIX=` 覆盖）
- `assemble-app.sh` / `build-pkg.sh` / `install-daemon-from-app.sh` / `postinstall`：
  ROOT 由脚本位置自动推导（不再写死路径）；anyfsd.conf 的 QEMU 路径按目标机 `uname -m` 生成
- daemon `Config.loadOverrides` 已支持 conf 指定路径，无需改代码

## 5. 预期性能（为什么要做 ARM 包）

Intel 包的瓶颈是 QEMU 用户态网络数据面吃单核性能（实测读 ~124-185MB/s）。
M 系单核性能 2-4 倍于 Mac mini 2018 i3。**已实测验收（2026-11-08，见第 7 节）：读 410MB/s、写 500-600MB/s**——写方向在 Intel 上同样受 CPU 约束，M 系红利比预期更大。
**注意**：Intel 包在 M 系 Mac 上不能靠 Rosetta 用（x86 guest 无法 HVF，只能 TCG 模拟，慢到不可用）——所以 ARM 包不是可选项，是 M 系用户的唯一路径。

## 6. 验收清单（与 Intel 相同）

1. `assemble-app.sh` 全 OK（依赖内聚/entitlement/签名/端到端冒烟）
2. `sudo installer -pkg` 成功，/Applications/AnyFS.app 就位
3. 接管 → BRIDGE-READY → Finder 可写 → 释放 → macOS 挂回
4. TRIM 验证：guest 删文件 → QMP unmap_operations 递增（DKIOCUNMAP 补丁在 arm64 同等生效）

## 7. ARM 首建实测记录（2026-11-08, macOS 15.8.1 arm64）

- 全链路已跑通：QEMU 11.1.2 打补丁编译（106s）→ Alpine aarch64 ISO → bundle.img → AnyFS.app(238M) → AnyFS-0.1.pkg(104M)
- brew 依赖 `meson ninja pkg-config libslirp`（glib/pixman 常被其他包带入已存在）
- **串口长命令截断坑**：guest tty 吃不掉 ~95 字符以上的单行注入，命令头部静默丢失且 RC=0 假成功。解法：guest 侧逻辑固化进 `spike/bundle/mkrootfs.sh`，串口只发短 wget + sh
- **apk --root 必须显式给 `--repository` 和 `--keys-dir /etc/apk/keys`**（initdb 后 root 内仓库/密钥皆空，否则只建骨架不装包）
- bundle 构建无需 sudo（HVF + slirp 用户态即可）；顶层包装机清单 = `samba ntfs-3g-progs avahi dbus`
- **证书**：openssl 3.x 导出的 p12 在本机 `security import` 报 "MAC verification failed"（-legacy/非 legacy 均败）；改为 **crt/key 分开 PEM 导入** + 用户域 `security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db` 即可，无需 sudo
- ARM 依赖库只有 11 个（Homebrew 依赖树比 MacPorts 精简，Intel 为 26 个）
- collect-qemu.sh 固件集 ARM 不能置空：virtio-net-pci 初始化时查找 option ROM（`-kernel` 直启不执行它，但缺文件直接拒绝启动 `failed to find romfile "efi-virtio.rom"`）；ARM 收集 `efi-virtio.rom pxe-virtio.rom` 两个即可，冒烟测试已加 virtio-net 设备覆盖此回归
- **性能验收（真机，RTL9210B + Ti600 1TB）**：guest 裸读盘 528MB/s、guest 内 ntfs3 直写 117MB/s、SMB 读 410MB/s、SMB 写（本机数据源）500-600MB/s 平均 500+——ARM 满血达成，是 Intel 的 ~2.5-3 倍。验收期曾误判"写入只有 10MB/s"，真凶是通用剪贴板跨机粘贴走 AWDL 无线 + QLC 盘 GC，与本项目无关（完整排障记录见 ntfs-bridge-app-plan.md 文末"排障案例"节）
