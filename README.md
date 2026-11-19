# AnyFS

**English** | [中文](#中文)

Read & write NTFS / exFAT / ext4 drives natively on macOS, with automatic TRIM maintenance that keeps USB SSDs running at full speed over the long term.

## How it works

macOS can't write NTFS, has no ext4 driver, and never sends TRIM to USB drives. AnyFS bridges all three gaps with a **micro Linux VM** (QEMU + Alpine, only 128MB RAM / 2 CPU cores):

```
Mac (Finder/Terminal)
   │  SMB (anyFS.local)
   ▼
Micro Linux VM ── virtio passthrough ──► physical partition (NTFS / exFAT / ext4)
   │
   └─ online discard + periodic fstrim ──► UNMAP commands reach the SSD controller
```

Taking over a partition takes ~4.5 seconds, and the idle VM costs almost nothing. Measured SMB write throughput exceeds 500MB/s on Thunderbolt/USB4 enclosures, with SMART health data readable over the Thunderbolt/USB4 path.

## Features

- **NTFS / ext4 read-write**: the VM takes over the partition and re-exports it to macOS over SMB — use it directly in Finder
- **exFAT native maintenance**: stays mounted natively in macOS; AnyFS issues TRIM directly via DKIOCUNMAP
- **Online TRIM maintenance**: guest-side `discard` mount option plus periodic fstrim
- **Deep TRIM verification**: writes a data pattern → deletes it → reads back the physical blocks to verify UNMAP actually reached the NAND (zero-fill verdict) — instantly identifies enclosures that swallow TRIM
- **Thunderbolt / USB4 enclosure support**: PCIe tunneling with working SMART, native TRIM, and no speed loss
- Menu bar app with per-partition status, capacity, and TRIM channel info at a glance

## Installation

Download `AnyFS-x.x.pkg` from [Releases](../../releases) and double-click to install.

**Notes (the package is currently self-signed):**

1. If macOS reports "unidentified developer", go to **System Settings → Privacy & Security** and click **Open Anyway**
2. Grant **Full Disk Access** to the `anyfsd` daemon on first use
3. Apple Silicon (arm64) Macs only

## Usage

Click the menu bar icon → toggle a partition on to take it over and mount it; toggle off to safely release it.

Supported partition types:

| Filesystem | Mode | TRIM |
|---|---|---|
| NTFS | VM takeover, re-exported via SMB | online discard + fstrim |
| ext4 | VM takeover, re-exported via SMB | online discard + fstrim |
| exFAT | native macOS mount | native DKIOCUNMAP |
| APFS / HFS+ | native macOS | AnyFS not needed |

## Building from source

See [packaging/BUILD-ARM.md](packaging/BUILD-ARM.md) (Apple Silicon) and [packaging/INSTALL.md](packaging/INSTALL.md). The installer contents are documented in [docs/pkg-contents.md](docs/pkg-contents.md).

## Third-party components & licensing

AnyFS itself is released under the [MIT License](LICENSE).

The distributed installer bundles the following third-party components, which retain their original licenses:

- **QEMU** (GPLv2) — the virtual machine; source at https://www.qemu.org , build patches used by this project are in `spike/patches/`
- **Alpine Linux** (per-component licenses, see https://alpinelinux.org ) — the guest system
- **busybox / musl / samba / ntfs-3g**, etc. (their respective licenses) — guest-side tools

These components are distributed as a mere aggregation alongside AnyFS and remain independent of its code.

## Disclaimer

This software operates directly on physical disk partitions. Although care has been taken to ensure correctness, you use it at your own risk of data loss. **Back up important data first.**

---

<a id="中文"></a>

# AnyFS (中文)

在 macOS 上原生读写 NTFS / exFAT / ext4 移动硬盘，并自动执行 TRIM 养护，让 USB 移动 SSD 长期保持满速。

## 原理

macOS 不支持 NTFS 写入，也没有 ext4 驱动，更不会向 USB 移动盘发送 TRIM。AnyFS 用一个**微型 Linux 虚拟机**（QEMU + Alpine，仅 128MB 内存、2 核 CPU）桥接解决这三件事：

```
Mac (Finder/终端)
   │  SMB (anyFS.local)
   ▼
微型 Linux VM ── virtio 直通 ──► 物理磁盘分区 (NTFS / exFAT / ext4)
   │
   └─ 在线 discard + 定期 fstrim ──► UNMAP 指令直达 SSD 主控
```

接管一个分区约 4.5 秒，VM 闲置时几乎零开销；实测 USB SSD 经 SMB 写入可达 500MB/s 以上（雷电/USB4 硬盘盒），并支持 SMART 健康信息读取（雷电/USB4 路径）。

## 功能

- **NTFS / ext4 读写**：VM 接管分区，通过 SMB 挂载回 macOS，Finder 直接操作
- **exFAT 原生养护**：不接管挂载，直接在 macOS 原生读写，AnyFS 定期下发 TRIM
- **TRIM 在线养护**：guest 内 `discard` 挂载选项 + 深度检测，验证 UNMAP 真正到达 SSD 物理层（读回归零判定）
- **TRIM 深度检测**：埋数据图案 → 删除 → 物理读回，判定"TRIM 已执行 / 被吞"，一眼识别不支持 UNMAP 的硬盘盒
- **雷电 / USB4 硬盘盒支持**：PCIe 隧道直通，SMART 可读、TRIM 原生、速度无损
- 菜单栏 App，分区状态、容量、TRIM 通道一目了然

## 安装

从 [Releases](../../releases) 下载 `AnyFS-x.x.pkg`，双击安装。

**注意事项（当前为自签名包）：**

1. 首次打开如遇"无法验证开发者"，请到 **系统设置 → 隐私与安全性** 中点击"仍要打开"
2. 首次使用需授予 **完全磁盘访问权限**（给 `anyfsd` 守护进程）
3. 仅支持 Apple Silicon (arm64) Mac

## 使用

点击菜单栏图标 → 列表中打开分区开关即可接管挂载；再次点击关闭即安全释放。

支持的分区类型：

| 文件系统 | 模式 | TRIM |
|---|---|---|
| NTFS | VM 接管，SMB 回挂 | 在线 discard + fstrim |
| ext4 | VM 接管，SMB 回挂 | 在线 discard + fstrim |
| exFAT | macOS 原生挂载 | 原生 DKIOCUNMAP |
| APFS / HFS+ | macOS 原生 | 不需要 AnyFS |

## 从源码构建

见 [packaging/BUILD-ARM.md](packaging/BUILD-ARM.md)（Apple Silicon）与 [packaging/INSTALL.md](packaging/INSTALL.md)。安装包内容清单见 [docs/pkg-contents.md](docs/pkg-contents.md)。

## 第三方组件与许可

AnyFS 本仓库代码以 [MIT License](LICENSE) 发布。

发布的安装包中捆绑了以下第三方组件，它们各自保留原有许可证：

- **QEMU**（GPLv2）— 虚拟机，源码见 https://www.qemu.org ，本仓库使用的构建补丁见 `spike/patches/`
- **Alpine Linux**（各组件许可证见 https://alpinelinux.org ）— guest 系统
- **busybox / musl / samba / ntfs-3g** 等（各自许可证）— guest 内工具

上述组件以聚合（mere aggregation）方式随安装包分发，与 AnyFS 自身代码相互独立。

## 免责声明

本软件直接操作物理磁盘分区。虽然已尽努力确保正确性，使用本软件导致的数据丢失风险由使用者自行承担。**重要数据请先备份。**
