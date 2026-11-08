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
| MacPorts 前缀 | /opt/local | /opt/local（ARM 版 MacPorts 同路径；若用 Homebrew 则是 /opt/homebrew） | collect-qemu.sh 需参数化 |
| TRIM 补丁 | file-posix.c DKIOCUNMAP | **同一份补丁直接适用**（`__APPLE__` 守卫，与 CPU 架构无关） | spike/patches/ |
| 签名/entitlements/dylib 收集/pkg | 同一套脚本 | 同一套脚本 | 无差异 |

构建机：需要一台 Apple Silicon Mac（交叉构建不值当：dylib 收集、HVF 冒烟都要本机）。
**保留 Intel 构建机**：低版本 macOS 构建向高版本跑的规则同样适用，ARM 包也建议在能到的最低 macOS 版本上构建。

## 1. QEMU (aarch64)

qemu 源码树不在 git 仓库里（太大），ARM 机器上需重新下载 11.1.2 源码再编译：

```bash
# 源码下载 (清华 MacPorts distfiles 镜像实测 41.6MB/s, 或 qemu.org):
#   https://mirrors.tuna.tsinghua.edu.cn/macports/distfiles/qemu/qemu-11.1.2.tar.xz
# 依赖与编译选项的完整版见 ntfs-bridge-app-plan.md 第十一节"编译 QEMU 11.1.2"
# (MacPorts clang-17 / CLT python3 / --enable-hvf --enable-slirp 等), ARM 只需改 target:
git apply spike/patches/qemu-11.1.2-macos-dkiocunmap-trim.patch   # 在解压的 qemu-11.1.2 里 patch -p1
./configure --target-list=aarch64-softmmu ...                     # 其余选项照抄 plan 文档
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

bundle 重建（二选一）：
- **推荐**：在 ARM Mac 上直接跑 `guest-mk-bundle.sh`（QEMU aarch64 + aarch64 ISO），
  apk 仓库换 aarch64 路径：`.../alpine/v3.21/main/aarch64/`
  rootfs 里的 amd64 二进制要全部换 aarch64 版（smbd/avahi/ntfs-3g 及其依赖；
  **x86 版 apk 清单不在 git 里**, 在本机 `spike/bundle/apks/` 目录, 去 ARM 前把整个
  anyfs 工作目录拷过去, 或在 ARM 上按清单从 aarch64 仓库逐个重新下载解包）
- 或找一台 ARM Linux 机器/云主机跑同样的 bundle 制作流程，把 bundle.img 拷回来

**注意**：spike 脚本（`guest-mk-bundle.sh` / `guest-part.sh`）有三处 x86 硬编码，
在 ARM 上跑之前每个脚本都要改：QEMU 路径指向 `qemu-system-aarch64`、
`-machine q35,accel=hvf` → `-machine virt,accel=hvf`、`console=ttyS0` → `console=ttyAMA0`。

**init.sh 无需改动**（blkid/挂载/smbd 全部架构无关）。

## 4. 打包脚本差异

```bash
# collect-qemu.sh 需小改 (做成参数):
QEMU_SRC=.../build/qemu-system-aarch64
FW_FILES=""        # -kernel 直启时 ARM 不需要固件文件; 用 edk2 则收集 edk2-aarch64-code.fd
# MacPorts 前缀 /opt/local 不变; 若依赖来自 Homebrew 则 /opt/local → /opt/homebrew
# daemon Config.loadOverrides 已支持 conf 指定路径, 无需改代码
```

注意 collect-qemu.sh 里 `qemu-system-x86_64` 不止 QEMU_SRC 一处：stage 落地路径、
otool/install_name_tool/codesign 各步、以及**末尾的端到端冒烟测试**都写死了文件名，
冒烟测试的 `-machine q35,accel=hvf` 也要改成 `virt,accel=hvf`。
建议把二进制名抽成 `QEMU_BIN=qemu-system-aarch64` 变量全文引用。

assemble-app.sh / install-daemon-from-app.sh / postinstall / build-pkg.sh 无需改动
（SIGN_ID、entitlements、自检全部架构无关）。

## 5. 预期性能（为什么要做 ARM 包）

Intel 包的瓶颈是 QEMU 用户态网络数据面吃单核性能（实测读 ~124-185MB/s）。
M 系单核性能 2-4 倍于 Mac mini 2018 i3，同架构下预期：读 300-500MB/s，写仍受 QLC 盘体限制 ~150-240MB/s。
**注意**：Intel 包在 M 系 Mac 上不能靠 Rosetta 用（x86 guest 无法 HVF，只能 TCG 模拟，慢到不可用）——所以 ARM 包不是可选项，是 M 系用户的唯一路径。

## 6. 验收清单（与 Intel 相同）

1. `assemble-app.sh` 全 OK（依赖内聚/entitlement/签名/端到端冒烟）
2. `sudo installer -pkg` 成功，/Applications/AnyFS.app 就位
3. 接管 → BRIDGE-READY → Finder 可写 → 释放 → macOS 挂回
4. TRIM 验证：guest 删文件 → QMP unmap_operations 递增（DKIOCUNMAP 补丁在 arm64 同等生效）
