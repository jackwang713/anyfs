# NTFS Bridge App — macOS NTFS/Linux 文件系统读写桥接工具

> 开发笔记：QEMU (HVF) + virtio-scsi 直通 + Alpine guest + SMB
> 目标：macOS 13+ / Intel + Apple Silicon 双平台 / 无内核扩展 / 零手动配置
> 架构定案日期：2026-11-01（基于一整天实测验证，详见文末"实测验证记录"）

---

## 一、项目概述

### 问题
macOS 原生只能**只读**挂载 NTFS，且不支持 ext4/btrfs 等 Linux 文件系统。现有方案要么需要内核扩展（macFUSE），要么价格高昂（Paragon/Tuxera），且都可能在 macOS 升级后失效。

### 解决方案
用 **QEMU + Alpine Linux guest** 经 virtio-scsi 直通读取整盘，guest 内用 ntfs3/ext4 等内核驱动挂载，通过 **Samba (vfs_fruit)** 经虚拟网络导出，macOS Finder 挂载为网络卷。全部封装在一个菜单栏 App 中，用户双击即运行。

### 产品需求（已定案）
1. macOS 上 NTFS 读写，速度 ≥100MB/s
2. macOS 13+，Intel + Apple Silicon 双平台（单架构分别打包）
3. 轻巧：菜单栏 App（MenuBarExtra），启动无感，配置极简
4. 除 NTFS 外支持 ext4/btrfs/exFAT 等 Linux 文件系统
5. USB SSD TRIM/UNMAP 优化内置

### 核心价值
| 优势 | 说明 |
|---|---|
| 零内核扩展 | QEMU HVF 用户态虚拟化，不碰内核、不改 SIP |
| macOS 13+ 双平台 | QEMU/HVF 覆盖 macOS 11+ Intel+ARM；单架构分别打包 |
| TRIM 端到端（独家） | 自研 QEMU 补丁打通 guest→host DKIOCUNMAP，含每设备自检绿灯 |
| 全文件系统养护（独家） | exFAT/ext4/btrfs：guest fstrim 实测可用（Linux exfat 驱动支持 TRIM 是独有卖点，macOS/Windows 的 exFAT 驱动都不发）；**NTFS：ntfs3 不支持 fstrim（6.12 实测），但支持 `-o discard` 挂载（删除即 TRIM，实测接受）+ blkdiscard 整分区初始化（186GB/1.82s）** |
| 架构可补丁 | QEMU 开源，断点可修可回馈上游；VZ 闭源不可控 |
| 多文件系统 | NTFS(ntfs3)/ext4/btrfs/exFAT/FAT32 |

---

## 二、技术架构

**定案：QEMU (HVF) + virtio-scsi raw 直通 + Linux guest + SMB(vfs_fruit) 导出。**

### 为什么放弃 VZ（实测结论）
- VZ 物理盘直通在 macOS 13 不可用：`VZDiskImageStorageDeviceAttachment` 对 /dev/rdisk2 和 /dev/disk2 都识别为 0 扇区（只支持普通文件）；`VZDiskBlockDeviceStorageDeviceAttachment` 要求 macOS 14+
- VZ 无 USB 直通 API（VZVirtioUSBController / VZUSBDeviceAttachment 等均不存在或不可用）
- VZ 配置启动后不可变，无热插拔（插盘要重启 VM）；QEMU monitor 支持 device_add/device_del
- VZ 闭源：virtio-blk discard 通路不可控，断点无法修复；QEMU 开源可打补丁
- QEMU/HVF 覆盖 macOS 11+ Intel+ARM，mountbox 已验证该路线

### 架构图

```
┌──────────────────────────────────────────────────────────────┐
│                    macOS (host)                              │
│                                                              │
│  ┌────────────────────────────────┐   ┌───────────────────┐  │
│  │ 菜单栏 SwiftUI App             │   │ Finder            │  │
│  │ (MenuBarExtra)                 │   │ smb://192.168.64.x│  │
│  │ • 磁盘列表/挂载状态            │   └───────▲───────────┘  │
│  │ • TRIM 自检绿灯                │           │ SMB3        │  │
│  └───────┬────────────────────────┘           │             │  │
│          │ XPC                     ┌───────────┴───────────┐ │  │
│  ┌───────▼────────────────────────▼─────────────────────┐ │  │
│  │ SMAppService privileged daemon (root)                 │ │  │
│  │ • 持 /dev/rdiskN (O_RDWR)，diskutil unmountDisk 压制  │ │  │
│  │ • fork/exec QEMU，monitor (QMP) 热插拔 device_add/del │ │  │
│  │ • vmnet-shared 网络（或 slirp 兜底）                  │ │  │
│  └───────┬─────────────────────────────────────────────┘ │  │
│          │ virtio-scsi (raw 整盘直通, discard=unmap)      │  │
│  ┌───────▼─────────────────────────────────────────────┐ │  │
│  │ QEMU 11.1.2 (HVF) — 已打 DKIOCUNMAP 补丁             │ │  │
│  │ handle_aiocb_discard → ioctl(fd, DKIOCUNMAP, ...)    │ │  │
│  └───────┬─────────────────────────────────────────────┘ │  │
│          ▼（guest 内部）                                   │  │
│  ┌─────────────────────────────────────────────────────┐ │  │
│  │ Alpine Linux guest（可选 diskless，全系统跑 initramfs）│ │  │
│  │ • kernel 6.12，ntfs3/ext4/btrfs/exfat 内核驱动        │ │  │
│  │ • Samba + vfs_fruit（SMB3，guest ok，sendfile）      │ │  │
│  │ • fstrim cron（每周）+ discard_max_bytes=1GiB        │ │  │
│  └─────────────────────────────────────────────────────┘ │  │
└──────────────────────────────────────────────────────────────┘
            │ USB
     ┌──────▼───────┐
     │ USB SSD/HDD  │  JMS583/RTL9210B/ASM2364/ASM2464PD
     └──────────────┘
```

### 关键概念: 块设备级直通 ≠ USB 直通 (2026-11-13 用户问答后补记)

本架构里 QEMU 只是把 `/dev/rdiskNsM` 当一个**普通文件**打开, guest 看到的
"QEMU HARDDISK" 是 scsi-hd 模拟层虚构的身份 — 这不是 UTM/VirtualBox 那种
"整个 USB 设备交给 guest 自带 usb-storage/UAS 驱动"的真 USB 直通。命令翻译链:

```
guest (smartctl/fstrim/mount)
  ↓ SCSI 命令 (INQUIRY/READ/WRITE/UNMAP/ATA PASS THROUGH...)
QEMU scsi-hd 模拟层   ← "QEMU HARDDISK" 身份是它编的
  ↓ 只翻译标准块操作 → pread/pwrite/DKIOCUNMAP(我们的补丁)
macOS 内核 IOUSBMassStorage (设备始终归 macOS 管, 从未易主)
  ↓ USB BOT/UAS
桥芯片 → SSD
```

推论 (全部有实测背书):
- **能过的**: READ/WRITE (满速)、UNMAP (补丁打通, 金标准验证)
- **过不去的**: 真身 INQUIRY/VPD、USB 描述符、ATA PASS THROUGH (SMART)
  — guest 内 smartctl -d sat 实测回 `unsupported scsi opcode` (朗科盘,
  其桥在 Ubuntu 上明明 SAT 可通 → 瓶颈在 scsi-hd 层, 与盘/桥无关)
- **为什么不做真 USB 直通**: USB 设备插入即被 macOS 内核驱动认领, 夺走需
  内核层配合 (VirtualBox 靠 kext); 纯 HVF 只有 CPU/内存虚拟化, QEMU 的
  usb-host 后端是 Linux-only。免 kext 和真直通不可兼得
- **取舍结论**: 买到 "免 kext + 满速 + TRIM", 代价是 SMART 等带外通道
  架构性不可得 — 健康监控定为"定期直插 Linux/Windows 用 smartctl -d sat"

### 资源估算（2026-11-01 SMB spike + bundle 实测）
| 项 | 数值 | 备注 |
|---|---|---|
| 安装包（单架构） | 80-120MB | QEMU 27MB + 依赖库、Alpine ISO 60MB + bundle.img ~60MB(实际53MB内容)、App 本体 |
| guest 内存配置 | **-m 256 默认（设置可调 256/384/512）** | bundle 形态下 -m 128 已验证可跑（BRIDGE-READY）；读速随内存递减（页缓存）：512MB=185 / 256MB=125 / 128MB=124(调优后) MB/s |
| 运行时 RSS | **-m 128: ~267MB / -m 256: ~437MB**（均含 QEMU 开销 ~250MB） | bundle 只读挂载消除了 live-apk 的 ~100MB tmpfs 税 |
| CPU 空闲 | ~1.5% 单核 | |
| CPU 传输中 | ~1.25 核（vmnet SMB 传输峰值实测） | 主要是 smbd 单线程 |

---

## 三、硬件选型（TRIM 兼容性）

### 移动硬盘盒芯片对比（更新于实测后）

| 芯片 | 接口 | UNMAP 实测 | 说明 |
|---|---|---|---|
| JMS583 (fw0212) | USB3 | ✅ 通过 | **平反**：经 SG_IO 全形态 UNMAP 实测通过（单/多描述符/256MB/63 描述符批量），"吞 TRIM"是旧固件冤案；SMART 不可读（macOS/Linux 均失败） |
| RTL9210B | USB3 | ✅ 通过 | 2026-11-02 实测：DKIOCUNMAP → 图案读回全零（TRIM-EXECUTED）；**SMART 经 sntrealtek 完整可读（Linux 侧）**。注：App 架构内（macOS 宿主）SMART 不可得——已穷举证伪：smartctl 无透传、QEMU scsi-generic 依赖 Linux SG_IO、SCSITaskLib 插件已注销（kIOReturnUnsupported）、苹果私有 SAT 路径仅插盘探测期瞬态可见（磁盘工具稳定"不支持"）；健康监控功能定为写入探针间接评估。2026-11-10 新方法论复测（guest FIEMAP 定位 + 宿主 F_NOCACHE 轮询读回）：TRIM-EXECUTED，**大批量 UNMAP 异步销账 ~30s/180GB ≈ 6GB/s** |
| JMS583（第三方硬盘盒 + 致态 Ti600 QLC） | USB3 | ✅ 通过 | 2026-11-10 新方法论（guest FIEMAP 定位 + 宿主 F_NOCACHE 轮询读回）：完整生产链路 TRIM-EXECUTED，归零 ~40s/171GB——**2026-11-11 终案: 延迟=smbfs deferred close 测试假象, 桥与全链路即时**, 详见文末终案 |
| ASM2364 | USB3 | ✅ | workaround 后有效 |
| ASM2464PD | USB4/雷电 | ✅ 原生 | PCIe 直通，无桥接层问题 |
| 铠侠 EXCERIA PLUS 成品 PSSD (JMS583, 铠侠定制固件 55.01) | USB3.2 Gen2 | ✅ 通过 | 2026-11-10 多层物理证据（详见文末排障案例）：宿主整盘/分区设备 DKIOCUNMAP、QMP qemu-io discard、**完整生产链路 guest 全量 fstrim** 均读回全零。内部为 M.2 NVMe（铠侠 TC58NC1202 主控 + 96 层 BiCS TLC）。曾测 86s/167GB——**2026-11-11 终案: 延迟=smbfs deferred close 测试假象 (smbd 持 fd → inode 迟回收 → discard 攒批), 全链路实测秒级**, 详见文末终案。注意：`DKIOCGETPROVISIONSTATUS` 不受理（EIO，正常），空 UNMAP 返回 EINVAL 为通路存在的标准表现 |
| 朗科 MobileDataStar 成品 PSSD 256GB (VID 0dd8 PID b600) | USB3 5Gbps **BOT(非UASP)** | ❌ **真不支持** | 2026-11-13 实测: `DKIOCGETFEATURES` raw=0x0 (UNMAP=no, 能力位全零), PROVISION ioctl EIO, 空 UNMAP EINVAL — 桥固件连 UNMAP 能力位都没报, App "桥拒绝 UNMAP" 判决正确 (**负路径真阴性第2例**, 第1例=ITE U盘 errno=45)。USB interface class 08-06-50 = Bulk-Only Transport 非 UASP。**同日 Ubuntu SAT 透传实锤**: 桥支持 SAT (smartctl -d sat 可读完整 SMART), 盘体 = SATA 3.1 6Gb/s SSD, fw N1114H, **"TRIM Command: Available, deterministic, zeroed" (DZAT)** — 不支持 UNMAP 纯为桥固件简配, 盘体 TRIM 能力完整且 DZAT 语义适配深度检测判决; 慧荣系自定义属性布局 (160-169), 与 Z 系列拆解 SM2258XT 吻合。健康基线: 通电 83h, 磨损 0, 坏块/待定 0; UDMA_CRC=17 观察项。**guest 内 SMART 再证伪 (同日, 用户要求复核)**: guest 装 smartmontools 实测, scsi-hd 对 ATA PASS THROUGH 回 `unsupported scsi opcode`, -d sat/sat,12 全拒 — 瓶颈在 QEMU scsi-hd 模拟层无 SG_IO 可转, 与盘/桥无关 (此盘桥明明支持 SAT) |

> 注意：桥固件差异大，同一芯片不同固件行为可能不同 → App 内置每设备自检（见"六、TRIM"章），以实测绿灯为准，不再依赖芯片白名单。

---

## 四、核心开发步骤

### Phase 1: QEMU 启动管理（daemon 侧）

Privileged daemon（root）负责拉起 QEMU 进程，菜单栏 App 经 XPC 下发指令。

```bash
# daemon 启动 QEMU 的命令行（x86_64 spike 实测可用）
qemu-system-x86_64 \
    -accel hvf -cpu host -smp 2 -m 512 \
    -kernel vmlinuz-virt -initrd initramfs-virt \
    -append "console=ttyS0" \
    -device virtio-scsi-pci,id=scsi0 \
    -drive file=/dev/rdisk2,if=none,format=raw,id=disk0,discard=unmap \
    -device scsi-hd,drive=disk0,channel=0,scsi-id=0,lun=0,discard_granularity=512 \
    -netdev vmnet-shared,id=net0 -device virtio-net-pci,netdev=net0 \
    -nographic -monitor unix:/tmp/ntfs-bridge.qmp,server,nowait
```

```swift
// daemon 内的 QEMU 生命周期管理
final class QEMUManager {
    var process: Process?
    let qmpSocket = "/tmp/ntfs-bridge.qmp"

    func start(diskPath: String) throws {
        // 1. diskutil unmountDisk force /dev/diskN（压制 macOS 自动挂载）
        // 2. open(diskPath, O_RDWR)，EBUSY 则重试 + 再压制（见技术难点）
        // 3. fork/exec qemu-system-ARCH，stderr 管道回收日志
    }

    // QMP/monitor 指令：热插拔
    func hotplugDisk(_ path: String, id: String) {
        // device_add / blockdev-add via QMP，插盘无需重启 VM（VZ 做不到）
    }
    func removeDisk(id: String) { /* device_del */ }
}
```

### Phase 2: virtio-scsi 直通与热插拔

- 直通整盘 `/dev/rdiskN`，`-drive discard=unmap` + `scsi-hd discard_granularity=512`
- guest 侧确认 `discard_max_bytes=1GiB`（spike 实测值）
- 插盘：daemon 监听 Disk Arbitration 挂载事件 → 压制自动挂载 → QMP `device_add`
- 拔盘：guest 内先 `umount` → `device_del` → 释放 fd

### Phase 3: Alpine bundle 构建（S3 已完成，实测方案）

**最终形态：stock Alpine ISO 启动 + 自包含 bundle 盘（ext2 镜像）只读挂载。** 实测打通（2026-11-01 晚）：

```
构建流程（macOS 侧全量完成，无需 Linux）：
1. 清华镜像下载 APKINDEX → 自研依赖解析器（so: 提供方映射）→ 47 个包 / 19MB
2. bsdtar 解包合并成 rootfs（53MB：smbd + 全部依赖库 + ntfs-3g-progs + avahi）
3. 删除 bundle 内 musl（用 live 系统自带，避免双 musl 冲突）
4. tar 打包 → QEMU guest 内 mke2fs 烧制 bundle.img（192MB ext2，只读挂载）

运行时（-m 128，零网络，BRIDGE-READY 实测通过）：
- guest 挂载 bundle.img 于 /opt，执行 /opt/init.sh：
  blkid 探测分区 → ntfsfix -d 兜底 → ntfs3 -o discard / exfat / ext4 挂载
  → 生成 smb.conf（共享名=卷标）→ 起 smbd → 探 445 端口报 BRIDGE-READY
```

踩坑记录（bundle 化的三个路径陷阱，都已修复并固化在 init.sh）：

| 坑 | 现象 | 解法 |
|---|---|---|
| samba 私有库在 `usr/lib/samba/` 子目录 | Error relocating / No such file | `LD_LIBRARY_PATH=/opt/usr/lib:/opt/usr/lib/samba` |
| smbd 运行时目录不存在 | `/var/log/samba`、`/var/lib/samba/private` 无法创建 | init.sh 预建 `/var/{log,lib,cache}/samba` |
| 插件目录编译期写死 `/usr/lib/samba` | `No builtin nor plugin backend for tdbsam found` | `ln -sfn /opt/usr/lib/samba /usr/lib/samba`（live tmpfs 可写） |
| pgrep -x smbd 误报 | smbd 已活但报 FAIL | **就绪判定改为探 445 端口**（netstat），并轮询等待 tdb 初始化 ≤15s |

**v2 演进项（S3.5，自定义 initramfs）**：抛弃 OpenRC，`/init` 直接是我们的脚本 → 砍掉 25 基础包 tmpfs 安装 + modloop 验证 + OpenRC 服务链，预期启动 ~13s→3-4s、内存 128→64-96MB。OpenRC 服务可砍清单：syslog/firstboot/hostname/login records/clean-tmp（~5-10MB，启动 -2~3s）。

### Phase 4: Samba + vfs_fruit 部署与自动挂载

guest 内预置 smb.conf（详见"七、网络与 SMB 配置"），guest 启动后：
1. 内核驱动挂载直通盘分区（ntfs3/ext4/btrfs/exfat）
2. 启动 smbd
3. host 侧轮询 SMB 端口/mDNS 就绪 → `mount_smbfs` 自动挂载 → Finder 打开

### Phase 5: TRIM 层（详见"六、TRIM"章）

三部分：QEMU 补丁（已完成 spike 验证）+ guest fstrim cron + App 每设备自检。

### Phase 6: SMB 自动挂载与 Finder 集成

```swift
func mountShare(guestIP: String) {
    // mount_smbfs //GUEST@ip/ntfs /Volumes/NTFS
    // 挂载失败重试；卸载时同步 umount
}
```

### Phase 7: 打包与签名

- 单架构分别打包（x86_64 / arm64 两个 pkg/DMG）
- QEMU 二进制（27MB）+ 依赖库内嵌进 .app/Contents/Resources
- daemon 走 SMAppService privileged helper，Developer ID + Notarization

---

## 五、QEMU 补丁（TRIM 通路关键，已完成并实测通过）

### 背景
macOS 侧 DKIOCGETFEATURES 返回 DK_FEATURE_UNMAP、DKIOCUNMAP 空操作返回 EINVAL —— host 通路存在。但 QEMU 11.1.2 未打补丁时，guest `blkdiscard` 报成功（RC=0）而 SSD 数据不变（静默吞掉）：`file-posix.c` 的 `handle_aiocb_discard` 在 macOS 块设备分支无实现。

### 补丁内容
`block/file-posix.c` 的 `handle_aiocb_discard` 块设备分支：

```c
#if defined(__APPLE__) && defined(__MACH__)
        do {
            /* macOS 块设备：DKIOCUNMAP，dk_extent_t 单 extent，offset/length 直接映射 */
            dk_extent_t extent = {
                .offset = aiocb->aio_offset,
                .length = aiocb->aio_nbytes,
            };
            dk_unmap_t unmap = {
                .extents = &extent,
                .extentsCount = 1,
                .options = 0,
            };
            if (ioctl(aiocb->aio_fildes, DKIOCUNMAP, &unmap) == 0) {
                return 0;
            }
        } while (errno == EINTR);

        ret = translate_err(-errno);
#endif
```

同时必须扩展 `translate_err` 的编译守卫，否则 macOS 下该函数未定义：

```c
/* 原：*/ #if defined(CONFIG_FALLOCATE) || defined(BLKZEROOUT) || defined(BLKDISCARD)
/* 改：*/ #if defined(CONFIG_FALLOCATE) || defined(BLKZEROOUT) || defined(BLKDISCARD) || (defined(__APPLE__) && defined(__MACH__))
```

### 实测结果
补丁后 guest `blkdiscard` → macOS 侧读回全零 = **TRIM-EXECUTED**，端到端打通。补丁可回馈 QEMU 上游。

---

## 六、TRIM（完整方案）

### 分层链路与实测状态

```
guest fstrim/blkdiscard                    [✅ 可用：exFAT/ntfs3/ext4/btrfs 均支持]
    │ virtio-scsi discard=unmap
    ▼
QEMU file-posix handle_aiocb_discard      [✅ 已打补丁并实测：读回全零]
    │ ioctl(fd, DKIOCUNMAP, &dk_unmap_t)
    ▼
macOS DKIOCUNMAP                          [✅ 通路存在：FEATURES 含 UNMAP，空操作 EINVAL]
    ▼
macOS USB 驱动 → 桥固件                     [⚠️ 因桥/固件而异 → 用自检解决]
    ▼
NAND 实际擦除                              [实测：JMS583 fw0212 全形态通过]
```

### 每设备自检设计（图案读回法）

桥固件差异大，白名单不可靠。App 对每个新设备跑一次自检，菜单栏显示绿灯（TRIM 生效）：

```
1. 在挂载文件系统的空闲区写 0x5A 图案（或等价固定 pattern）
2. 删除文件
3. guest 内对该区域发 UNMAP（fstrim 或 blkdiscard）
4. 读回该区域：
   - 全零   → TRIM-EXECUTED，绿灯
   - 图案在 → 被吞（静默丢弃），黄灯 + 提示桥固件不发 TRIM
```

这套探针源自实测验证方法论（exFAT 空闲区图案写删测），演进为内置功能。

> **2026-11-10 方法论修正（铠侠实测连环假阴性后，详见文末排障案例）**：上述流程要成立，必须满足四个前提：
> 1. **阳性对照校准**：先用宿主最短路径 UNMAP 验证该盘是 DZAT 行为（读回归零）；校准不过的盘属 Indeterminate 型，判据失效，只能灰灯弃权
> 2. **读回必须宿主侧 F_NOCACHE**：QEMU 在 macOS 无 O_DIRECT（file-posix.c 降级为 O_DSYNC，全树无 F_NOCACHE），guest 内 dd 读回会命中宿主缓冲区里的旧图案 → 假阴性
> 3. **读回必须轮询等待**：桥对大批量 UNMAP 异步销账（铠侠这块 ~86s/167GB ≈ 2GB/s；1MB 小请求即时），fstrim 后立即读回必出冤案
> 4. **禁用 fstrim -o/-l 范围版**：guest exFAT FITRIM 范围路径报成功但目标区不归零（疑似驱动范围计算 bug）

### 各文件系统的养护策略（2026-11-01 实测定案）

| 文件系统 | guest 挂载选项 | 定期养护 | 初始化/大扫除 | 备注 |
|---|---|---|---|---|
| **NTFS (ntfs3)** | `-o discard`（实测接受，删除即 TRIM） | ❌ ntfs3 无 FITRIM（6.12 实测 ioctl ENOTSUP）；等 NTFSPLUS 进主线 | `blkdiscard /dev/sdXN`（186GB/1.82s 实测） | 主力靠 Windows 侧实时 TRIM；Mac 期间靠 discard 挂载预防 |
| **exFAT** | 可选 `-o discard` | ✅ fstrim（实测修剪 64.7GiB，悬崖 10→29GB） | 同上 | macOS/Windows 都不发 TRIM，**App 是唯一养护来源**（独有卖点） |
| **ext4/btrfs/FAT32** | 可选 | ✅ fstrim | 同上 | 标准路径 |
| **APFS/HFS+** | — | ❌ Linux 无可写驱动 | ❌ | 混排盘的盲区，只能靠 macOS（默认 USB 也不发） |

### NTFS 脏位与干净退出（实测踩坑）

硬杀 QEMU（卷处于挂载状态）会在 NTFS 留下脏位，下次 ntfs3 挂载报 `Invalid argument` 拒绝挂载（实测现场：`$MFTMirr does not match $MFT (record 3)`，`ntfsfix -d` 修复后挂载成功）。产品设计要求：

1. **退出/拔盘流程必须先 guest 内 umount，再停 QEMU**（QMP system_powerdown 或 monitor 指令）；
2. 挂载前兜底跑 `ntfsfix -d`（秒级，无副作用）；
3. Windows 对此无感（挂载自动恢复），但 ntfs3 严格——双系统盘必会遇到；
4. **干净退出是三段式**（S4.1 联调实测发现）：先卸载 macOS 侧的 SMB 挂载点 → 再 guest umount → 最后 poweroff。否则 guest 关机后 macOS 残留死链接，弹"服务器连接已中断"警告且 Finder 可能转圈。daemon（root）负责按盘卸载对应挂载点（umount，必要时 diskutil unmount force）。

### guest 侧 UNMAP 配置

```bash
# provisioning_mode 兜底（kernel 7.0 对 provisioning type 未知设备默认关 discard，
# provisioning_mode=full 时 discard 不可用 —— Ubuntu 对照实验确认）
echo unmap > /sys/block/sdX/device/scsi_disk/*/provisioning_mode

# 定期 fstrim（exFAT/ext4/btrfs 分区，cron）
0 2 * * 0 /usr/sbin/fstrim -v /mnt/exfat > /dev/null 2>&1
```

### 两种 TRIM 模式建议（实测后修正）
| 模式 | 方式 | 评价 |
|---|---|---|
| 定期 fstrim | cron 每周一次 | exFAT/ext4/btrfs 适用；实测抢救 64.7GiB 后 SLC 悬崖 10→29GB |
| 实时 discard | mount -o discard | **NTFS 的唯一在线养护手段（ntfs3 无 fstrim），实测挂载选项被接受**；exFAT 等其他格式也支持；作为默认开启项 |

---

## 七、网络与 SMB 配置

### 网络方案（2026-11-01 SMB spike 实测）
| 方案 | 实测速度 | 权限 | 结论 |
|---|---|---|---|
| **vmnet-shared** | **读 185 / 写 146 MB/s**（12GB dd） | 需 root | **首选**（daemon 本来就有 root）；瓶颈在 smbd 单线程 |
| slirp（用户态 NAT） | 读 106 / 写 121 MB/s | 无需特权 | 兜底；软件 NAT 天花板 ~110-120MB/s |

归因链（12GB dd 实测）：guest 内直读盘 **606 MB/s**（盘+virtio-scsi+ntfs3 满血，macOS 直读 615 的 98%）→ vmnet SMB 读 185（smbd 单线程 + 协议开销）→ slirp 再砍到 106。写入侧两方案都接近 QLC 直写物理极限。QEMU 资源：传输中 CPU ~125% 单核、RSS ~800MB、空闲 ~1.5%。**≥100MB/s 目标两种方案均达标，vmnet 裕量充足。**

提速观察项（2026-11-03 优化 spike 终局）：
- **IOThread（已采纳进 daemon）**：virtio-scsi 配 `iothread`，写 +15%、写 CPU 108%（原 ~125-200%）；读无感（读瓶颈不在磁盘路径）
- **MTU 9000（死路）**：macOS vmnet 桥 MTU 写死 1500（`ifconfig bridge100 mtu 9000` 返回 EINVAL），框架层不可改；vmnet-bridged 违背私有直连设计，弃
- **kernel NFS（完败，维持 SMB）**：nfsd vs smbd 同条件对拍 写112/读113 @157-184% CPU —— 瓶颈不在用户态协议，而在 QEMU 用户态网络数据面 + HVF 开销（协议无关的公共地板）；vhost-net 在 macOS 不存在
- virtio-net 卸载（TSO/GSO/GRO）：QEMU 默认开启，无免费午餐；读速上限 ~185MB/s（512MB guest）即此台 i3 的传输天花板
- **-smp 档位实测（2026-11-03，干净对照）**：4核 vs 2核 → 写 200→240 MB/s（**+20%**），CPU 200→260%。结论：写方向在 i3 上部分受 CPU 约束，4 核可买 20% 但功耗不划算；档位定为 **低功耗 1 核 / 标准 2 核（默认）/ 极速 4 核**（标注代价）。注：首次"4 核无用"结论系 daemon 残留 VM 抢盘导致的污染测试，干净环境重测后修正

### smb.conf（guest 内预置）

```ini
[global]
    server string = NTFS Bridge
    server min protocol = SMB3
    workgroup = WORKGROUP
    vfs objects = fruit
    fruit:metadata = stream
    fruit:model = MacSamba
    use sendfile = yes
    socket options = TCP_NODELAY

[ntfs]
    path = /mnt/ntfs
    browseable = yes
    read only = no
    guest ok = yes
    force user = root
```

> vfs_fruit 保证 macOS Finder 元数据（.DS_Store、资源叉）兼容；SMB 端到端速度已实测（见上表）：vmnet 读 185/写 146 MB/s，slirp 兜底 106-121 MB/s，≥100MB/s 目标达标。

---

## 八、项目目录结构

```
NTFS-Bridge/
├── NTFS-Bridge.xcodeproj/
├── NTFS-Bridge/                    # 菜单栏 App (MenuBarExtra)
│   ├── AppDelegate.swift
│   ├── MenuBarView.swift
│   ├── DaemonXPCClient.swift       # XPC 客户端
│   ├── TrimSelfTest.swift          # 每设备自检（图案读回法）
│   └── Info.plist
├── NTFS-BridgeDaemon/              # SMAppService privileged daemon (root)
│   ├── main.swift
│   ├── QEMUManager.swift           # QEMU 生命周期 + QMP 热插拔
│   ├── DiskGuard.swift             # 自动挂载压制 + O_RDWR 重试
│   └── com.ntfsbridge.daemon.plist
├── QEMU/
│   ├── qemu-system-x86_64          # 内嵌二进制（27MB，单架构分别打包）
│   ├── qemu-system-aarch64
│   ├── patches/
│   │   └── 0001-macos-dkiocunmap-discard.patch   # TRIM 补丁（管理+回馈上游）
│   └── build.sh                    # QEMU 编译脚本（见开发环境）
├── Resources/
│   └── alpine.bundle/              # diskless Alpine
│       ├── vmlinuz-virt
│       ├── initramfs-virt           # 预置 samba/vfs_fruit、fstrim cron、挂载服务
│       └── smb.conf
├── build-alpine-bundle.sh
├── NTFS-Bridge.entitlements
└── README.md
```

---

## 九、竞品分析

| 项目 | 路线 | macOS 最低 | Intel | TRIM | 状态 |
|---|---|---|---|---|---|
| mountbox | QEMU+SMB | 11 | Yes | No | 免费（已停产？） |
| anylinuxfs | libkrun+NFS | 15 | No | No | 活跃 |
| vmount | VZ+Finder | 15 | No | No | $29 |
| **本项目** | **QEMU(HVF)+virtio-scsi+SMB** | **13** | **Yes** | **Yes（端到端+自检）** | 开发中 |

差异点：QEMU 可补丁架构（VZ 路线修不了 TRIM 断点）、macOS 13+ 双平台、TRIM 端到端含每设备自检、exFAT TRIM 养护为全平台独有。

---

## 十、技术难点与解决方案（实测后更新）

| 难点 | 解决方案 | 状态 |
|---|---|---|
| macOS 自动挂载抢盘 | 外接盘被自动挂载抢回导致 raw 设备 O_RDWR 打开 EBUSY；第三方清理软件（如腾讯柠檬）会主动挂载外接盘。对策：diskutil unmountDisk force + 卸载压制循环 + 打开重试 | 已确认机制，daemon 侧实现 |
| QEMU TRIM 补丁 | file-posix.c 加 __APPLE__ 分支 + translate_err 守卫扩展（见第五章） | ✅ 已写好并实测通过 |
| QEMU 补丁维护 | 补丁独立管理（QEMU/patches/），可回馈上游；升级 QEMU 版本时 rebase | 持续 |
| 桥固件差异 | 不做白名单，做每设备自检绿灯（图案读回法） | 设计定稿 |
| SMB 端到端速度 | ✅ 已实测（2026-11-01）：vmnet-shared 读185/写146 MB/s，slirp 兜底 读106/写121；归因 smbd 单线程（guest 直读盘 606 MB/s 满血，损耗不在盘/直通/ntfs3） | ✅ 已解决 |
| NTFS 脏位（硬杀 QEMU） | 卷挂载状态下杀 QEMU → NTFS 脏位 → 下次 ntfs3 挂载报 Invalid argument 拒挂（实测现场 `$MFTMirr does not match $MFT`）。对策：退出/拔盘流程先 guest umount 再停 QEMU（QMP powerdown）；挂载前兜底 `ntfsfix -d`（实测秒级修复成功） | ✅ 已确认机制，daemon 设计必做 |
| QEMU 编译环境 | macOS 13 工具链坑多，见"十一、开发环境" | ✅ 已趟平 |

---

## 十一、开发环境（macOS 13 实测趟平）

### 编译 QEMU 11.1.2（macOS 13 CLT 的坑与解法）

```bash
# 坑 1：Apple clang 14 太老（QEMU 11 要求 Xcode clang 15+/上游 clang 10+）
# 解：MacPorts clang-17，且 --cc/--cxx/--objcc 三个都要指
sudo port install clang-17

# 坑 2：conda Python 建 venv 坏
# 解：用 CLT Python 3.9，pip --user 装依赖
./configure --python=/usr/bin/python3 ...
/usr/bin/python3 -m pip install --user tomli pyyaml packaging meson ninja

# 编译
./configure \
    --cc=/opt/local/bin/clang-mp-17 \
    --cxx=/opt/local/bin/clang++-mp-17 \
    --objcc=/opt/local/bin/clang-mp-17 \
    --python=/usr/bin/python3 \
    --target-list=x86_64-softmmu \
    --enable-hvf --enable-slirp \
    --disable-docs --disable-gtk --disable-sdl --disable-cocoa \
    --disable-spice --disable-usb-redir --disable-opengl \
    --disable-guest-agent --disable-xen
make -j$(sysctl -n hw.ncpu)
# 产物 qemu-system-x86_64 仅 27MB
```

### 包管理与镜像

- Homebrew 已停止为 macOS 13 出 bottle（装啥都源码编译）→ **MacPorts** 仍提供 darwin_22 x86_64 二进制（qemu 11.1.2 即由此获得；注意 ports 树版本与二进制归档可能错位）
- 清华镜像可用：homebrew-bottles、macports distfiles（含 qemu 源码，实测 41.6MB/s）、anaconda

### 其他工具
- Alpine hybrid ISO：hdiutil 挂不上（"无可装载的文件系统"）→ `bsdtar -xf` 提取 kernel/initrd
- SwiftUI App：Xcode（MenuBarExtra 需 macOS 13 SDK，符合需求）

---

## 十二、MVP 路线图

| 阶段 | 目标 | 状态/估期 |
|---|---|---|
| ~~S0: QEMU 直通 spike~~ | HVF 直启 Alpine，virtio-scsi 直通 /dev/rdisk2，1TB 识别，顺序读 615.9 MB/s | ✅ 已完成 |
| ~~S1: TRIM 链路 spike~~ | QEMU 补丁 + guest blkdiscard + 读回全零 | ✅ 已完成 |
| ~~S2: SMB 端到端~~ | guest Samba → macOS 挂载 → 速度实测（vmnet 读185/写146 MB/s） | ✅ 已完成 |
| ~~S3: Alpine bundle~~ | stock ISO + ext2 bundle 只读盘 + init.sh 全自动 → BRIDGE-READY（-m 128, RSS ~267MB） | ✅ 已完成（S3.5 自定义 initramfs 列为演进项） |
| S4: privileged daemon | S4.1 骨架 ✅（SMAppService 用 launchd 手动安装替代、QEMU 管理、抢盘压制、干净退出）→ S4.2 DiskArb 自动发现 → S4.3 QMP/XPC | 3 天（进行中） |
| S5: 菜单栏 App | MenuBarExtra、磁盘列表、自检绿灯、XPC | 3 天 |
| S6: 打包签名 | 单架构 pkg/DMG、daemon 安装、公证 | 2 天 |

**剩余预估：约 8 天（单人开发）**

---

## 十三、实测验证记录（2026-11-01）

环境：Intel Mac mini 2018 + macOS 13.7.8 + JMS583(fw0212) 硬盘盒 + 致态 Ti600 1TB

### 关键数字

| 项 | 结果 |
|---|---|
| QEMU 11.1.2 + HVF 直启 Alpine 3.21.3 (kernel 6.12.13) | guest 内核 <1s 完成设备初始化，数秒到 shell |
| virtio-scsi 直通 /dev/rdisk2 | 1TB 完整识别（1953525168 扇区） |
| 直通盘顺序读（dd 4GB） | **615.9 MB/s** —— ≥100MB/s 目标的 6 倍余量 |
| guest discard_max_bytes | 1 GiB（-drive discard=unmap + scsi-hd discard_granularity=512） |
| macOS DKIOCGETFEATURES | 返回 DK_FEATURE_UNMAP |
| macOS DKIOCUNMAP 空操作 | EINVAL（通路存在） |
| 1MB 实测 UNMAP 后读回 | 全零 = TRIM-EXECUTED |
| QEMU 未打补丁时 guest blkdiscard | RC=0 但数据不变（静默吞掉） |
| QEMU 打补丁后 guest blkdiscard | 读回全零 = TRIM-EXECUTED，端到端打通 |
| QEMU 二进制体积 | 27MB（裁剪配置后） |
| Ubuntu 对照：fstrim 解锁后 | 成功 TRIM 156.9 GiB |
| MacPorts 清华镜像下载 qemu 源码 | 41.6 MB/s |
| guest 直读直通盘（dd 12GB，ntfs3） | **606.5 MB/s**（满血，macOS 直读 615 的 98%） |
| SMB over slirp（12GB dd） | 读 106 / 写 121 MB/s（用户态 NAT 天花板） |
| **SMB over vmnet-shared（12GB dd）** | **读 185 / 写 146 MB/s**（瓶颈 smbd 单线程，非盘/直通/ntfs3） |
| QEMU 资源占用 | 传输中 CPU ~125% 单核、RSS ~800MB、空闲 ~1.5% |
| guest blkdiscard 整分区（186GB） | **1.82 秒**（初始化级大扫除） |
| guest mkfs.ntfs（ntfs-3g-progs，清华 apk 镜像） | ✅ App 可独立初始化 NTFS 盘，无需 Windows |
| ntfs3 `-o discard` 挂载 | ✅ 接受（NTFS 删除即 TRIM，在线养护主手段） |
| ntfs3 fstrim | ❌ ENOTSUP（kernel 6.12 无 FITRIM；NTFSPLUS 新驱动已补，待进主线） |
| NTFS 硬杀脏位 | 挂载中杀 QEMU → ntfs3 拒挂（`$MFTMirr` 不同步）→ `ntfsfix -d` 秒级修复 → 挂载成功 |
| guest fstrim exFAT 抢救 | 修剪 **64.7 GiB**，SLC 悬崖 10GB→29GB |
| macOS spaceman 日志（USB APFS，默认配置） | `(no trims)` + `0 blocks free in 0 extents`——策略层禁 TRIM（trimforce=NVRAM 全局开关，重启生效，本机黑苹果未实测开启） |
| Alpine guest 能力 | modprobe exfat/ntfs3 ✅、udhcpc（slirp/vmnet）✅、apk 清华镜像 ✅、ntfs3 中文写入 → macOS 原生只读验证 ✅ |

### S3 Alpine bundle（2026-11-01 晚）

| 项 | 结果 |
|---|---|
| bundle 构建 | macOS 侧 bsdtar 解 47 个 apk（19MB）→ rootfs 53MB → guest 烧制 192MB ext2 bundle.img |
| 运行时形态 | -m 128 + 零网络安装 + bundle 只读挂载 + init.sh 全自动（探测→ntfsfix→ntfs3 -o discard→smbd→探445报 READY） |
| **BRIDGE-READY** | ✅ 通过（-m 128），macOS 挂载 //GUEST@192.168.64.6/Ti600-NTFS（共享名=卷标） |
| **QEMU RSS（-m 128）** | **~267MB**（含 QEMU 开销；live-apk 形态 -m 512 时为 ~800MB，省 67%） |
| 读写速度（-m 128 bundle） | 写 114 / 读 124 MB/s（sendfile+socket 调优后；读速随内存递减：512MB=185/256MB=125/128MB=124，产品默认 -m 256 可调） |
| bundle 化踩坑 | samba 私有库子目录（LD_LIBRARY_PATH 加 `lib/samba`）、/var 运行时目录预建、tdbsam 插件路径（`/usr/lib/samba` 符号链接）、pgrep 误报（改探 445 端口） |

### S4.1 privileged daemon 骨架（2026-11-02，Swift 5.8/CLT 纯命令行构建）

实现：`daemon/Sources/anyfsd/main.swift`（单文件，swiftc 直编，无 Xcode 依赖；SwiftPM 在纯 CLT 环境缺 Platforms 不可用）。ad-hoc 签名 + 手动 launchd 安装（install-dev.sh），**无需开发者账号**（生产公证决策留 S6）。

| 验收项 | 结果 |
|---|---|
| 启动到 BRIDGE-READY | **9 秒**（直跑）/ 11 秒（launchd）—— 轮询就绪信号替代脚本固定 sleep 18s |
| 干净退出（SIGINT/SIGTERM/launchd kill 三种路径） | guest umount → poweroff → **QEMU code=0**（全部非强杀，NTFS 零脏位风险） |
| EBUSY 抢盘重试 + QEMU stderr 全量入日志 | ✅（stderr 改造当场破案 FDA 问题） |
| **TCC 完全磁盘访问权限（FDA）** | ⚠️ **生产必备发现**：launchd daemon 打开 /dev/rdiskN 报 `Operation not permitted`（EPERM）——终端直跑能成功是因为终端 App 有 FDA 且权限沿进程树继承，daemon 必须单独授权（系统设置→隐私与安全性→完全磁盘访问权限）。安装器需引导用户授权（Paragon 等同类产品同款流程） |

组件：SerialPipe（mkfifo 双工 + 行回调）、MountSuppressor（diskutil unmountDisk force 每秒压制，**S4.4 删除换 DA 审批回调，见下**）、QEMUManager（启动重试/串口编排/干净退出）、Log（/var/log/anyfsd.log）。

### S4.2 DiskArb 自动接管（2026-11-02）

实现：DiskManager + Disk Arbitration 回调（whole+USB 过滤，`diskutil list -plist` 判可接管分区：NTFS/exFAT/msdos/ext*/"Microsoft Basic Data"/"Linux"）。验收全绿：

| 场景 | 结果 |
|---|---|
| 启动时盘已插入（DA 回放） | 单次接管 → 9s READY（曾现双接管竞态：DA 注册即回放 + 冗余的启动扫描双通道抢盘 → **删掉启动扫描，DA 回放单通道**） |
| 物理直接拔盘 | 检测 → forceTeardown（卸 SMB + terminate）→ QEMU code=0 |
| 回插 | 自动再接管，全周期 11s |
| APFS 容器合成盘（disk3） | 正确忽略（Content 不在白名单） |

**签名与 FDA（开发基建，生产必读）**：
- ad-hoc 签名每次构建 cdhash 都变 → TCC/FDA 授权随重装失效；**解法：自建 anyfs-dev 自签代码签名证书**（openssl 生成 + `security add-trusted-cert -p codeSign`），TCC 按证书认身份，重装不再掉授权。GUI 钥匙串证书助理创建的证书私钥关联易失败（find-identity 查不到），CLI 生成 + pkcs12 `-legacy` 导入路径最稳。
- install-dev.sh 签名必须 `sudo -u $SUDO_USER` 执行（证书在用户登录钥匙串，sudo 下查到的是 root 的空串）。
- 生产环境（S6）用正式 Developer ID 证书则天然无此问题。

### S4.3 QMP + XPC（2026-11-02）

实现：QEMU 加 `-qmp unix:/tmp/anyfsd.qmp,server,nowait`；daemon 内 QMPClient（AF_UNIX + JSON 握手 `qmp_capabilities`）；XPCService（NSXPCListener，launchd plist 声明 MachServices）+ anyfsctl 测试客户端。四接口实测全绿：

```
anyfsctl status  → active=disk2 qemu=ready qmp={"return":{"status":"running"}}  ← QMP 协议层打通
anyfsctl disks   → disk2: ready
anyfsctl trim    → guest 内批量 fstrim (exFAT/ext4; NTFS 走 -o discard)
anyfsctl eject   → 三段式干净退出, QEMU code=0
```

设计备忘（S5 需要）：XPC eject 后盘物理上仍插着，DA 不会再发"插入"事件 → **S5 菜单必须有显式 mount/takeover XPC 命令**（否则 eject 后只能拔插才能复活）。XPCService 实例必须强引用持有（NSXPCListener 对 delegate 是弱引用，临时变量会被秒释放）。**Foundation Pipe 坑**：`readabilityHandler` 在 EOF 时必须置 nil，否则 handler 空转 100% CPU（实测两台 QEMU 的 stderr 管道各烧一核，idle 200%）；S6 前全量审查同类 handler。

### S4.4 事件驱动挂载压制 + 休眠问题结案（2026-11-03）

**症状**：SMB 卸载后盘盒 LED 仍常闪、永不休眠。**定位**（QMP query-blockstats 两次采样计数器零变化 → guest/QEMU 对盘零 I/O 无辜；iostat 显示接管期间 ~10 IOPS 的 2KB 小读；eject 后归零）→ 元凶是 daemon `MountSuppressor` **每秒一次 `diskutil unmountDisk force` 轮询**，每次触发 macOS 重读 GPT/枚举卷，刚好打满盘盒休眠计时器。

**修复**：删除轮询，改用 `DARegisterDiskMountApprovalCallback` 挂载审批回调——接管期间（activeBSD 匹配 whole disk）同步否决一切对该盘直接分区的挂载（返回 DADissenter），事件驱动零轮询。启动时的一次性 unmount + 5 次 EBUSY 重试保留。验收：接管后 iostat 全程 0 tps，**盘盒数分钟后正常休眠**；TRIM/读写功能不受影响。

**平台行为新发现（否决了"APFS 共存顺带实现"的推断）**：QEMU 持握整块裸盘（/dev/rdisk2）期间，macOS 会**拆掉该盘全部分区节点和 APFS 合成容器**（日志可见 disk3 拔出事件；`diskutil mount /dev/disk2s3` 报 "Failed to find disk"——查找阶段即失败，根本没走到 veto）。含义：① veto 回调定位为兜底保险，覆盖 QEMU 打开设备前的窗口期；② 整盘直通模式下 macOS 侧彻底摸不到该盘，**APFS 原生共存（两分区 Finder 互拷）只能走分区级直通**（/dev/rdisk2s3，`spike/guest-part.sh` 已建成未测，需求搁置中）。

### S5 前置：分区级直通共存验证（2026-11-07）✅

**动机**：S4.4 证明整盘直通会让 macOS 拆掉全盘节点（APFS 共存不可能）；用户 UI 设计要求"按分区接管/不交还的留给 macOS" → 必须分区级直通（`/dev/rdiskXsY`）。

| 验证项 | 结果 |
|---|---|
| APFS 原生挂载期间 QEMU 打开 /dev/rdisk3s3 | ✅ 不冲突（EBUSY 只作用于被挂载的那个分区，兄弟分区无碍） |
| guest 识别"整盘即文件系统"（无 GPT 的 /dev/sda） | ✅ init.sh 探测列表加 `/dev/sda /dev/sdb`（整盘 blkid 只有 PTTYPE 无 TYPE，自动被类型过滤跳过，两种直通形态共用一份代码） |
| **Finder 同时看到 SMB 的 NTFS + 原生的 APFS，互拷 8GB** | ✅ **~200MB/s**（同盘读写并发，高于纯 SMB 写地板） |
| TRIM 经分区 fd 透传（DKIOCUNMAP） | ✅ guest 删 16MB 文件 → `unmap_ops:4 unmap_MB:16 failed:0`，与删除量字节级吻合 |

**对 S5 架构的锁定**：接管粒度 = 分区；单 VM 可挂多个分区设备；APFS 共存互拷场景落地；macOS 对 NTFS 的原生只读自动挂载用 DA veto 按分区精确拦截（禁止 spike 里的轮询压制进生产）。spike 脚本教训：盘符会随重启/插拔漂移（disk2→disk3），一律按卷标 `diskutil info <label>` 探测；`set -e` 脚本里外部命令必须 `|| true`（否则静默退出难排查）。

### S5.1 daemon 分区化改造（2026-11-07）✅

架构变更（应用户 UI 设计要求）：**取消自动接管**，DA 仅用于枚举刷新/拔盘保护/veto；接管粒度从整盘改为**分区**（`/dev/rdiskXsY`，单 VM 可挂多分区，scsi-id 递增）；同盘未选中的分区（APFS）留给 macOS 原生。

- 新 XPC 接口：`listAvailable`（外接盘可接管分区枚举，diskutil list -plist external 解析）/ `takeover(分区数组)`（集合变更=干净重启 VM）/ `releaseAll` / `appQuit`（收尸+自毁）/ 保留 `status`/`trimNow`
- **交还语义**：releaseAll/appQuit 后 daemon 主动 `diskutil mount` 把分区挂回 macOS（分区直通下节点从未消失，macOS 无自动挂载事件，必须主动挂；NTFS 为原生只读）。接管变更的中间释放不挂回（避免抖动）；SIGTERM 系统关机路径不挂回
- **按需启动闭环**：KeepAlive=false + MachServices → 首条 XPC 拉起 daemon；appQuit 后 `active count = 0`，进程消失。用户体感 = 单 App
- veto 改为按分区 BSD 精确匹配（DADiskGetBSDName 直接比对 activeParts），APFS 等兄弟分区不受影响
- unmountSMBShares 加 anyFS/192.168.64 过滤（不再误伤用户其他 SMB/NAS 挂载）
- guest init.sh 探测改 `/dev/sd[a-z][0-9]* /dev/sd[a-z]`（支持多分区直通 sda..sdz）
- **验收全绿**：list → takeover(15s ready) → SMB → trim → release → 不拔盘再 takeover → quit 自毁
- 已知余项：盘符漂移下 UI 要用 bsd 实时枚举而非缓存；list 的 fs 字段在未挂载分区上回退为 Content（"Microsoft Basic Data"），UI 展示层再美化

### S5 菜单栏 App（2026-11-07）✅

- **形态**：SwiftUI MenuBarExtra（.window 风格面板），LSUIElement 纯菜单栏无 Dock；`app/Sources/AnyFSApp.swift` 单文件 + `build-app.sh`（swiftc -parse-as-library 直编 + 手工组 .app bundle + anyfs-dev 签名）
- **交互定稿**：无全局状态概念（分区行自表达：可读写绿/只读蓝/未挂载灰）；switch 开关接管/释放；养护按行（NTFS 显示"在线养护"无按钮，exFAT/ext* 行尾 🍃 按分区 fstrim，daemon 新增 trimPartition XPC）；退出联动 daemon 收尸自毁（appQuit 改为**收尸完成才回话**，App 显示"正在关闭…"等待，兜底 20s）
- **挂载点权限坑**：/Volumes 是 root:wheel，普通用户 App 建不了目录 → daemon XPC `prepareMountpoint` 预建并 chown 给控制台用户（SCDynamicStoreCopyConsoleUser）
- **多盘**：按物理盘分组显示（MediaName 如 RTL9210B-CG）；单 VM 挂多分区；拔盘保护改为只收受影响盘的分区、剩余重启 VM 恢复
- **图标**：`app/Tools/render-icons.swift` CoreGraphics 程序化渲染（SSD 轮廓+双向箭头），菜单栏模板图 + 深色底 App 图标
- **配置定稿**：2 核 / 128MB 默认，不做开机启动，设置页留待后续版本
- **遗留 backlog**：QMP 热插拔消除增删分区时的 VM 重启（~15s 中断）；设置页（内存/CPU 档位）

### S5.2 整盘无分区表 (superfloppy) 支持（2026-11-09）✅

场景：Linux 侧 `mkfs.ext4 /dev/sdX` 直接格整盘的 U 盘（无 GPT/MBR），macOS `diskutil` 完全无感知（Content=None、无分区节点、无 fs 类型），App 列表看不到。

| 改动 | 说明 |
|---|---|
| 整盘枚举 | `listAvailable` 对"无 Partitions 且 Content 为空"的外接盘加魔数探测分支 |
| **魔数探测 `probeWholeDisk`** | daemon 是 root 直接读 `/dev/rdiskN` 固定偏移签名（与 blkid 同原理，确定性识别非猜测）：ext4 超块 @1080=0x53EF + 卷标 @+120(16B)、NTFS/exFAT @3、FAT32 @82/FAT16 @16；结果（含"不支持"）缓存，随 DA 变更失效——不缓存会每次枚举都真读盘闪灯 |
| takeover 放行整盘 | 校验 `^disk\d+(s\d+)?$`；partLabels 卷标回退链 diskutil→探测缓存→bsd |
| unmount/remount 跳过整盘 | macOS 本就挂不了，无需压制/挂回 |
| guest 侧零改动 | S5 已验证整盘形态（init.sh 探测 `/dev/sd[a-z]`） |

注意：只探测 init.sh 挂载白名单内的类型（ntfs/exfat/vfat/ext4）；btrfs/xfs 魔数可识别但 guest 未启用挂载，不列出。

**踩坑：macOS 裸盘字符设备（/dev/rdiskN）的 pread 要求偏移和长度都按扇区（512）对齐**，否则直接返回失败且不报错——首版探测按精确偏移读 2 字节魔数全部静默失败，表现为"盘在列表里消失"。修法：读所在扇区再切片。验证工具：伪镜像文件测切片逻辑（文件无对齐限制）+ FDA 终端 `sudo swift` 实测真机裸盘。

### S6 打包管线（2026-11-07，自包含包已跑通）

产物：`AnyFS.app`（321MB 全自包含，bundle.img 192M + Alpine ISO 60M + QEMU 45M）。脚本在 `packaging/`：`collect-qemu.sh`（依赖收集+固件+签名+自检）、`assemble-app.sh`（一键组包）、`install-daemon-from-app.sh`（pkg postinstall 原型，写 /usr/local/etc/anyfsd.conf 覆盖资产路径，daemon 已支持 conf 覆盖）。

**零成本分发决策**：自签 anyfs-dev 走全流程；用户侧两道手动关卡（Gatekeeper 放行：13/14 右键打开、15+ 只能系统设置→隐私与安全性；FDA 授权 anyfsd），安装说明按版本写。兼容性：macOS 13 构建机覆盖 13/14/15+ Intel（低版本构建向高版本跑，勿反向）；ARM 需另起 qemu-system-aarch64 + aarch64 guest，暂缓。

**S6 踩坑清单（全部已固化进脚本自检，重跑 assemble 即全量回归）**：
1. MacPorts dylib 散落 /opt/local → BFS 收集 26 个 + install_name_tool 重写（qemu→@executable_path/../lib，互引→@loader_path）
2. anyfsd 漏签 → FDA 按证书身份失效，开裸盘 EPERM（"Operation not permitted" 是 TCC 不是 EBUSY）
3. codesign --force 丢 entitlements → HVF "Could not access HVF"；**ad-hoc 签名豁免 HVF 检查，证书签名强制**，需 com.apple.security.hypervisor（≠ virtualization）
4. BIOS 固件缺失：预编译 blob 在**源码树** pc-bios/（build/pc-bios 只有 edk2 等构建产物）；QEMU 从 <exe_dir>/../share/qemu 找固件 → 布局 bin/lib/share/qemu；QEMU 11 无 linuxboot.bin/multiboot.bin（只剩 *_dma）；virtio-net 需 efi-virtio.rom
5. 冒烟测试带 -S = 假阳性（不触发固件加载）；WARN 被 grep 过滤吞掉；set -e 不穿管道（要 pipefail）
6. pipefail + `codesign|grep -q` = SIGPIPE(141) 误判（grep -q 提前退出杀上游）→ 一律先捕获输出再匹配
7. 钥匙串弹窗循环：27 文件逐个签 → 批量一次签；`security set-key-partition-list` 一劳永逸
8. codesign -dv（单v）不打印 Authority，要 -dvv
9. git 首提交教训：.gitignore 不支持行尾注释（# 必须行首）；1.6G QEMU 树不入库，TRIM 补丁提取至 spike/patches/

**S6 剩余**：pkgbuild 打 .pkg（root=stage/Applications + scripts/postinstall）、安装说明（分版本 Gatekeeper 指引+FDA 引导）、（可选）公证脚本留 SIGN_ID=Developer ID 参数位。

### 兼容性修复：MBR 盘 + 非 ASCII 卷标（2026-11-07 晚）

| 问题 | 根因 | 修法 |
|---|---|---|
| MBR U盘（老毛桃 FAT32）不出现在列表 | `diskutil list -plist` 的 Content 命名按分区表类型分两套：GPT=`Microsoft Basic Data`，MBR=`Windows_FAT_32/Windows_NTFS/DOS_FAT_32…`；且 FilesystemType 恒为空 | 过滤前先用 `diskutil info -plist` 拿真实 fs 类型（fsTypeOf 前置），命名差异全免疫；白名单同步补 MBR 命名；EFI 显式排除保留 |
| FAT32 共享"挂载失败"，smbutil view Broken pipe | **guest busybox blkid 读非 ASCII 卷标（中文 FAT32 卷标为 OEM 字符集）乱码**，乱码共享名致 SMB 枚举崩溃 | daemon 用 `diskutil info` 的真卷标经串口注入 `/tmp/anyfs-names`（sda=卷标），init.sh `get_name` 优先读映射 |
| 注入真中文卷标后 mount_smbfs 仍失败 | **macOS SMB 客户端 URL 解析器不接受非 ASCII**（原始中文报 URL parsing failed，百分号编码不解码报共享不存在） | 共享名强制 ASCII 化：纯 ASCII 卷标用卷标，否则回退 bsd 设备名（`disk2s1`）；daemon 注入与 App shareName 同一规则。UI 仍显示真卷标 |
| macOS 挂载态文案"只读"错误 | 只有 NTFS 只读，FAT32/exFAT 原生可读写 | stateText 按 fs 区分："macOS 只读"(ntfs) / "macOS 读写" |

遗留优化：App 挂载改 NetFS 框架可支持中文共享名（macOS 客户端限制，非 Samba/协议限制）。**运维教训**：daemon conf 指向 /Applications 包内资产后，重烧 spike bundle 必须同步（cp 或重跑 assemble），否则 VM 跑的是旧 init.sh。

**养护链路的两个后续修正**（实测发现）：① 🍃 按分区养护曾"假成功"——App 误传显示名（非 ASCII 卷标）而非 shareName，guest 无此挂载点，fstrim 静默失败；已改为传 shareName，且 trimPartition 回传 fstrim 真实输出（成功显示修剪量，失败显示错误）。② 判读工具 `spike/check-trim.sh`（QMP query-blockstats）：unmap_ops 计数在 **SCSI 设备模型的完成回调**里记（hw/scsi/scsi-disk.c，取决于 host DKIOCUNMAP 真实返回值），故 ops>0&failed=0 = 端到端受理；注意 unmap_bytes 是累计请求量不去重（同区域多次 fstrim 重复计），展示"本次修剪量"需前后快照取差。

### 验证方法论

- **TRIM 探针**：exFAT 空闲区写 0x5A 图案 → 删除 → UNMAP → 读回（全零=执行 / 图案在=被吞）。已演进为 App 内置每设备自检设计。
- **Ubuntu 对照实验**（佐证"JMS583 吞 TRIM"是旧固件冤案）：kernel 7.0 对 provisioning type 未知设备默认关 discard（provisioning_mode=full），`echo unmap > /sys/block/sdX/device/scsi_disk/*/provisioning_mode` 解封后 fstrim 成功 156.9 GiB；JMS583 fw0212 经 SG_IO 全形态 UNMAP 实测通过（单描述符/多描述符/256MB/63 描述符批量）。
- **VZ 证伪**：VZDiskImageStorageDeviceAttachment 对 /dev/rdisk2 和 /dev/disk2 均识别为 0 扇区（macOS 13，只支持普通文件）；VZ 配置启动后不可变、无热插拔；VZ 不支持 VHDX（只认 raw）。原方案中引用的 VZ API（VZVirtioUSBController/VZUSBDeviceAttachment/VZSharedEthernetNetworkAdapterAttachment/VZSocketSharingNetworkInterface/VZVirtioEthernetDevice/VZLinuxBootLoaderArguments/$architecture）均不存在或不可用。

### 排障案例：写入"慢到 10MB/s"+ 磁盘神秘占满（2026-11-08，ARM 移植验收期）

**教训：两个看似 anyFS 的问题，根因都在 macOS 自身。以后再遇到先做对照测试，别先怀疑桥接链路。**

#### 案例 A：SMB 写入 NTFS 只有 ~10MB/s，QEMU CPU 很低

分层隔离测试（工具：`spike/diag-run.sh` + guest 内 diag 脚本，经串口注入执行、结果写回 NTFS 卷读回）：

| 层 | 实测 | 结论 |
|---|---|---|
| guest 裸读盘（virtio-scsi+USB 通路） | 528 MB/s | 完好 |
| guest 内 ntfs3 直写（oflag=direct，无 SMB） | 117 MB/s | 完好（QLC 盘体水平） |
| SMB 读真实大文件 | 410 MB/s | 网络/签名/smbd 全部完好 |
| SMB 写（本机数据源） | 500-600 MB/s | ARM 满血（Intel 2 核打满才 200） |
| SMB 写（剪贴板同步期间粘贴） | **<10 MB/s** | 问题仅在此场景 |

**真凶：通用剪贴板（Universal Clipboard/Continuity）**。附近有同 iCloud 账号的 Mac 且接力开启时，⌘C 的文件会被 sharingd 接管；粘贴时数据经 **AWDL 无线点对点**从另一台 Mac 边收边写（或在同步被 X 掉后走剪贴板数据提供者管道串行交付），源端喂不饱 → QEMU CPU 自然低。**与本项目无关。** 正确姿势：本机复制用拖拽（不经过剪贴板），跨机传文件用 AirDrop，大批量用 rsync/ditto。

注意全零数据的 dd 写是假快（87MB/s）——macOS SMB 客户端对全零区域走零块卸载（SET_ZERO_DATA），不经过真实盘写路径；测写入必须用随机数据。

#### 案例 B：系统数据暴涨 215.9GB、磁盘 100% 占满

定位路径（关键坑：**sudo 不能穿透 TCC**，du 须由有"完全磁盘访问权限"的终端跑才完整；df 与 du 差额 >200GB 时优先怀疑 TCC 盲区）：

```
df(471.6GB) - sudo du(~253GB) = 218GB 幽灵
→ 排除: APFS 快照(无) / 已删除未释放文件(lsof +L1 无) / 挂载点覆盖(无) / 废纸篓(0B)
→ 真身: ~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard = 175GB
```

**机制**：通用剪贴板把 ⌘C 的文件**完整暂存**到该目录供其他设备拉取，useractivityd 本应自动清理但存在泄漏（取消/中断的传输不被回收；也未注册进 macOS CacheDelete 磁盘压力清理名单）。同类案例：mole issue #1178 整理电影飙 300GB、Apple 社区 370GB。**苹果官方无文档无开关**（[官方储存空间文档](https://support.apple.com/zh-cn/102624)对"系统数据"只有一句"通用类别"）。

**目录因 macOS 版本而异**（实测）：macOS 15 在 `~/Library/Group Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard`（不自动清理，会积累成灾）；macOS 13 在 `$TMPDIR/com.apple.useractivityd/shared-pasteboard`（即 `/var/folders/.../T/` 下，系统约 3 天自动清 + 重启清，基本无泄漏风险）。通用定位法：`defaults read com.apple.coreservices.useractivityd` 打出的 `kLocalPasteboardBlobName`/`kRemotePasteboardBlobName` 即实际路径。

**处理**：`rm -rf ~/Library/Group\ Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*`（安全，系统下次传输自动重建；建议只清 1 小时前的条目以免切断进行中的同步）。日常清理工具：[Mole](https://github.com/tw93/mole)（`brew install mole`，开源，源码含该目录的 1 小时安全闸清理）；腾讯柠檬不覆盖此目录。

#### 对本项目的启示（backlog）

- App 可加防护：SMB 挂载掉线/未就绪时，若用户往原挂载点目录粘贴会写到**本机 SSD**（/Volumes 下残留目录），考虑卸载后删除空挂载点目录 + 状态提示
- 性能问题排查顺序固化：先 guest 裸盘 dd 定盘体上限 → 再 guest 内文件级 dd 隔 SMB → 最后宿主 SMB 测；宿主侧低速先看数据源是否经剪贴板/无线

### 排障案例：TRIM 金标准连环假阴性（2026-11-10，铠侠 EXCERIA PLUS 1TB 实测）

**对象**：铠侠 EXCERIA PLUS 1TB（JMS583 桥，铠侠定制固件 55.01；盘芯 TC58NC1202 + 96 层 BiCS TLC），exFAT 分区（GPT 分区盘 disk7s2，832GB 已用）。

**最终结论**：TRIM 端到端**真实有效**，任何一环（QEMU 补丁、macOS 整盘/分区设备、JMS583 桥、铠侠固件）都无故障；但**大批量 UNMAP 是异步销账**（~86s/167GB ≈ 2GB/s），1MB 小请求即时生效。

**证据矩阵**（全部宿主 F_NOCACHE 读回 + 预校验安全闸）：

| 路径 | 结果 |
|---|---|
| 宿主 DKIOCUNMAP → 整盘 /dev/rdisk7（1MB @832GB） | ✅ 全零 |
| 宿主 DKIOCUNMAP → 分区 /dev/rdisk7s2（1MB，分区相对偏移） | ✅ 全零 |
| QMP `qemu-io usbdisk0 discard`（验证运行中 QEMU 的补丁路径，绕过 guest） | ✅ 全零 |
| guest 全量 fstrim 167GB（完整生产链路） | ✅ ~86s 后全零 |

**连环假阴性（一天踩遍的判读陷阱，按发现顺序）**：

1. **guest 内 dd 读回 → 假"被吞"**：QEMU 在 macOS 无 O_DIRECT（`file-posix.c:126` 降级为 `O_DSYNC`，全树无 F_NOCACHE），daemon 又未传 `cache=`（默认 writeback），guest 的读回命中 macOS 缓冲区里的旧图案。教训：**读回必须在宿主侧 F_NOCACHE 直读**（daemon 有 FDA，可行）。
2. **fstrim 后立即读回 → 假"被吞"**：该桥对大批量 UNMAP 异步销账 ~86s，立即读回图案必在。教训：**读回必须轮询等待**（建议每 10s、最长 10min），归零时延本身是设备画像。
3. **`fstrim -o OFF -l 1M` 报 "1048576 bytes trimmed" 但目标区 180s 不归零**：guest exFAT FITRIM 范围路径失效（疑似范围计算 bug；QMP delta 实验脚本已备 `guest-trim-delta.sh` 未跑）。教训：**检测与养护都禁用范围版 fstrim，只用全量**。
4. **busybox blkdiscard 挂载中 O_EXCL 拒开（无 -f）**：定点实验改用 `fstrim -o/-l`（且 FITRIM 只碰空闲簇，安全性优于指哪打哪的 blkdiscard）。
5. **`/tmp/anyfsd-serial.out` 是 fifo**：宿主直读会永久阻塞且与 daemon 的读取器抢数据；guest 结果必须写**卷内结果文件**经 SMB 读回（diag-run.sh 的老经验）。

**规范层依据（TRIM 异步的合法性）**：三层协议都把 TRIM 定义为 hint，生效时机是固件实现细节——SCSI SBC：UNMAP 后内容 "may be indeterminate"，sg_unmap 手册 "unclear how long the UNMAP command will take"；ATA：DZAT 仅为可选能力位（Word 69 bit 14）；NVMe：DLFEAT 字段声明读回行为（000b=厂商自定/001b=全零/010b=全FF）。USB 桥层完全无规范约束（可 ACK 后内部排队）。Windows"优化驱动器"从不做读回验证正是这个原因——协议没给验证通道。

**修正后的金标准流程**（工具均已落盘 spike/）：

```
① 阳性对照校准: 宿主最短路径 UNMAP → 读回; 非零=Indeterminate 盘 → 灰灯弃权
② 埋 32MB 0x5A 图案 → 定位物理偏移 (免全盘扫描):
   guest 链路用 filefrag (FIEMAP, 问内核要 extents, 文件系统无关,
   分区直通场景 physical offset 与宿主分区设备寻址直接通用);
   宿主裸机链路用 exfat-locate.py 只读解析元数据 (自检 <99% 图案拒绝动手)
③ guest sync 落盘 → 宿主 F_NOCACHE 预校验图案物理在盘
④ guest 删除 + 全量 fstrim (禁用 -o/-l)
⑤ 宿主 F_NOCACHE 轮询读回 (10s×60), 记录归零时延
工具: trim-live-test.sh (宿主一把梭) / guest-deep-trim.sh (anyFS 链路)
     guest-trim-latency.sh (时延曲线) / guest-blkdiscard-test.sh / exfat-locate.py
     unmap-live --unmap (带 99% 图案安全闸)
```

**产品结论（深度检测功能重新定位）**：

- **通道状态灯用 QMP 计数器**（`unmap_ops/failed_unmap_operations`）：便宜、即时，覆盖 guest→QEMU→macOS 三层，适合做展开详情的常驻三态灯（✅ 有流量 / ❌ 被拒 / ● 未观察）
- **NAND 级深度检测降级为可选诊断**（spike 工具或专家按钮）：~90s+ 轮询 + 写删 32MB，不适合做每设备强制自检；养护本身 fire-and-forget 即可（与 Windows 同哲学）

### 排障续案：TRIM 延迟归因翻转 + 金标准基建修正（2026-11-11，Ti600@JMS583/RTL9210B 双盒实测）

**核心翻转：桥是无辜的，延迟在 guest→QEMU 段。**
之前归到桥固件的"大批量 UNMAP 异步销账 30~86s"被 QMP 打点推翻：guest 删除后 20~36s 内 QEMU 收不到任何 UNMAP（`unmap_ops=+0`），ops 跳变的**同一瞬间** NAND 归零。桥一旦收到立即执行，零积压。

**数据矩阵（Ti600 1TB 致态 QLC，JMS583 盒）**：

| 路径 | 量 | 结果 |
|---|---|---|
| 宿主直发 DKIOCUNMAP（bridge-direct-trim，VM 离场） | 1MB | **即时归零 ×4 复现**（NTFS/exFAT 时代均然，fs 无关） |
| guest exFAT 删除（-o discard 在线） | 32MB | +256 ops @T+22s 同刻归零（256×128KB=恰为图案体量，guest 拆成 128KB 条） |
| guest NTFS 删除（-o discard 在线） | 32MB | +1 op @T+24~36s 同刻归零（ntfs3 合并成单条大范围） |
| guest 全量 fstrim | 171~180GB | 30~40s（旧数据，打点粒度粗，疑同因——fstrim 逐段同步发） |
| 铠侠 PSSD 86s/167GB | — | **旧"异步销账"结论作废，归因需按新法复测** |

**归因收敛**：延迟与文件系统无关（exFAT/NTFS 一致）、与 UNMAP 数量无关（256 条瞬间归零）、与桥无关（直发秒回）。剩两个嫌疑：guest 内核攒批 或 QEMU→宿主 ioctl 段在"VM 持有设备"状态下被压。最后一刀：DEL-BEGIN/DELETE-DONE 双标记打点测 rm 是否同步阻塞等 discard 完成（已加进脚本，待跑）。

**金标准基建踩坑（一日四坑，全部根治）**：

1. **共享名大小写**：卷标真实大小写 `exFAT`；SMB 共享名大小写不敏感（能挂上），但注入 guest 的路径大小写敏感 → 写不存在路径静默失败，表象酷似"串口死"。根治：`anyfsctl share` 查询 + 脚本自动解析，不再手工传共享名
2. **smbfs 目录缓存假阴性**：guest 带外新建文件，宿主 `ls`/`[ -f ]` 看不到但 `cat` 能读到（铁证实测）。卷内结果文件信号旗机制整体废弃 → **控制台回显 + `anyfsctl console` 轮询**（标记带 PID 后缀防多轮误读）
3. **filefrag 输出格式**：Alpine e2fsprogs-extra 的 filefrag 裸 `-v` 只出摘要不出 extent 表，必须 `-e -v`；文件碎段时首段可能 <1MB，需扫描选首个够长的 extent
4. **QMP qemu-io 已移除**：QEMU 11 无此命令（CommandNotFound），对照组曾因 `>/dev/null` 吞输出而假死——**诊断输出永远不许吞**
5. **busybox blkdiscard 挂载中 EBUSY**（-f 无效）：guest 内块层对照组暂缺可用手段

**新增工具（spike/ 已落盘）**：

- `anyfsctl console`：guest 串口 transcript 末尾 60 行（原来只在 daemon 内存，排查全靠猜）
- `anyfsctl inject <命令>`：串口注入走 XPC（与启动注入同路径，**免 sudo**；原来脚本要 sudo 很大程度是因为 root 持有的 fifo）
- `anyfsctl share <分区>`：查共享名真实大小写
- `bridge-direct-trim.sh`：宿主直发金标准（方案A 文件系统无关版，借 anyFS 埋图案+定位，释放 VM 后直发 DKIOCUNMAP）
- `guest-deep-trim.sh` v3：`--fast`（只删不全量 fstrim，验证在线 discard）+ QMP unmap_ops 打点 + 控制台信号旗 + 删除前后双标记计时

**对产品结论的修正**：通道灯用 QMP 计数器、养护 fire-and-forget 的设计**维持不变且更稳固**——桥侧即时执行意味着"养护发出即生效"（guest 侧的 ~30s 攒批反而减少命令数，有益无害）。延迟归因清楚后，"每设备首次接入的物理认证"若做，可走宿主直发单条 1MB（即时出结果），不必走 guest 批量路径。

### 排障终案: 延迟元凶 = macOS smbfs 客户端 deferred close (2026-11-11 下午, KIOXIA 三连复现)

**终案结论: 观测到的 16~53s "TRIM 延迟"根本不是 TRIM 路径的延迟, 而是测试架构自身的产物。**
经 SMB 埋入图案文件后, macOS smbfs 客户端在**内核层**缓存/延迟关闭 SMB 句柄 (lsof 看不到任何进程级持有者), smbd 连接进程因此在 guest 内一直持有该文件的 fd。控制台 rm 只是摘了名字 (秒回), 但 inode 还有引用, **VFS 推迟 evict; exFAT 不到 evict 不释放簇, 自然不发 discard**。等客户端句柄缓存到期 (各轮观测 16/18/24/34/38/47/53s 浮动), smbd 关 fd → 最终 iput → `exfat_evict_inode` 一次性释放 256 簇 → 256 条 discard 爆发 → virtio-scsi→QEMU→DKIOCUNMAP→桥→NAND 全程 <2s。

**完整证据链 (KIOXIA disk7s2, 同日)**:

| 实验 | 条件 | 结果 |
|---|---|---|
| rm 路径 ×2 | SMB 活着 (原始条件) | 16s/24s 延迟, ops 悬崖与归零同刻 |
| 对照组 blkdiscard 1MB | umount 后裸发, 绕开 fs | `real 0m0.00s` + 2s 后读回全零 — **传输段瞬时** |
| rm 路径 (run3) | 对照组副作用: smbd 被杀+remount | 秒归零 |
| --local rm / 全量 fstrim | 无 smbd 无客户端, 图案 guest 本地 dd | **双双秒归零** (fstrim 全程 5s, +1086 ops) |
| --no-ctrl 复现 ×2 | SMB 活着 + diskstats/fd 全打点 | 47s/53s 延迟; **FD-HELD /proc/2114/fd/29 = smbd[192.168.64.x]**; DS 显示 guest 块层在 rm 后 47/53s 才记 +256 (sectors 恰为 32MB), 与归零同刻 |

**三方时钟对齐法**: DEL-BEGIN/DELETE-DONE 带 guest `date +%s`; DS watcher (diskstats 2s 采样: inflight/discards完成/sectors) 从埋图案起全程跑; 宿主轮询 zero+unmap_ops。注意宿主轮询的 "T+Xs" 标签比真实时间慢 (每轮 verify+qmp 有 ~2s 开销), 对表以 DS/QMP 跳变为准。

**基建新坑 (续前 5 坑)**:

6. **QMP 打点 sed 张冠李戴**: `sed 's/.*"unmap_operations"...'` 贪婪匹配拿的是 JSON 行尾设备 (bundle/ISO), usbdisk0 的计数被淹没 → 全程 +0 假象。根治: 对齐 check-trim.sh, python 解析 + `device.startswith("usbdisk")` 过滤
7. **console XPC 只返回末尾 60 行**: DS 打点器刷屏会顶掉基线 → rm 前必须快照 CONS_PRE
8. **打点器启动晚于 rm 丢关键 5s**: 必须从埋图案阶段就启动, 采样窗口盖住 rm 前后

**金标准最终形态**:

- **快速物理认证**: `guest-deep-trim.sh <分区> --fast --local` — **13s 出判决** (无 SMB, 图案 guest 本地 dd|tr 生成, 删除即 discard, T+0 读回全零)
- 生产链路验证: `--fast` (有 SMB) 会触发本文句柄缓存延迟, 判决轮询窗口需给到 90s
- 全量养护验证: `--local` (fstrim ~5s/167GB 空区)
- 新工具 `qmp-stats.py`: 逐设备 QMP 计数探针 (`--watch` 实时), 替代 sed 解析

**产品结论 (终)**:

- "桥异步销账 30~86s" **彻底作废** — 铠侠 86s 旧案与 Ti600 22~36s 同为此句柄缓存假象; TRIM 全链路任意路径 (宿主直发/guest 块层/guest fs/fstrim) 实测都是秒级
- 通道灯 (QMP unmap_ops 计数) 与养护 fire-and-forget 设计维持不变; 每设备首次接入的物理认证可行, 走 --local 同款 guest 内埋点, 10s 量级出结果

### 原生(免接管) exFAT 深度检测 spike 验证通过 (2026-11-11, KIOXIA disk4s2)

`native-deep-trim.sh` + `exfat-bitdiff.py` 全链路 3s 贯通: macOS 原生挂载埋 32MB 图案
→ **位图 diff 定位**(写前写后两份分配位图差分, 新分配簇段即图案) 与目录解析法
(exfat-locate.py) **偏移完全一致** → 删除(macOS 不发 TRIM) → 卸载 → 定向 DKIOCUNMAP
(trimNative 同款) → F_NOCACHE 读回全零 TRIM-EXECUTED。v1.1 移植定位机制选定位图 diff
(daemon trimNative 已持有位图解析代码, 无需目录树解析)。

### TRIM 深度检测产品化落地 (2026-11-11, v1)

**功能形态**: 分区行 chevron 展开详情 (格式/容量/可用空间/TRIM 通道灯) + 深度检测按钮,
不持久化检测结果; 判决物理读回为准, 通道灯只表示"有流量"(受理≠执行, 三星吞 TRIM 实踩)。

**双路径** (深度检测跟着养护路径走, 不跟接管状态走):

| 分区状态 | 链路 | 实现 | 实测 |
|---|---|---|---|
| 接管中 (NTFS/exFAT/ext4) | guest | daemon deepTrim: guest dd 埋图案(避开 smbfs deferred close) → filefrag FIEMAP → F_NOCACHE 预校验 → rm → 读回 | NTFS/ext4 ~2s ✅; 三星 ❌ ~19s |
| exFAT 未接管 | 原生 | 三阶段 XPC: daemon 位图快照A → App 原生挂载写图案 → daemon diff 定位 → App 删除 → daemon 卸载/定向 DKIOCUNMAP/读回/挂回 (与 trimNative 共用 exfatBitmap) | ~3s ✅ |
| NTFS/ext* 未接管 | — | 按钮置灰 (macOS 写不了, 无通路) | — |

**实现期踩坑 (全部根治)**:

1. **串口标记被 tty 回显提前匹配**: 短标记 (DT-LOCATED) 在命令回显里完整出现, waitSerial 命中回显而非真实输出。根治: 标记插入空引号拆断 (`echo DT-LOCA""TED`, 回显不匹配, shell 拼接后输出匹配)。脚本版当年靠 PID 后缀把标记推过 80 列换行点天然免疫
2. **CRLF 是单个 grapheme cluster**: transcript 行尾 \r\n, `split(separator: "\n")` 永远匹配不到独立 "\n" 字符 → 解析整体落空 (trimPartition 的真实输出回传也因此静默退化, 已一并修)。根治: `components(separatedBy: .newlines)`
3. **多盘 target 对位**: 见下条

**多盘设备对位 bug (深度检测试出来的真产品 bug)**: guest SCSI 字母分配是异步探测竞争结果, 与 scsi-id 脱钩 (实测 sda 落到 target1)。后果: 多盘接管时卷标/共享名张冠李戴, SMB 共享指错卷。根治: 放弃字母对位, 按 sysfs 路径 `targetH:0:N` 末位 N (= daemon 的 scsi-id) 对位 — daemon 写 `tgt<N>=卷标`, init.sh 按 target 升序枚举; 重名挂载点按 target 序去重 (-2/-3), daemon shareNameOf 同规则派生。**注意 host 号 H 因平台而异** (ARM=0, Intel/x86 实测=6, 路径形如 `host6/target6:0:0/6:0:0:0/block/sda`), 匹配必须写 `target[0-9]*:0:N`, 写死 `target0:0:` 会导致 Intel 上深度检测找不到挂载点、init.sh 掉回字母兜底 (2026-11-11 实踩)。

**UI 打磨 (同日)**: 分区行浅底色圆角框 (primary 6% 自适应, 信息全收敛框内);
展开详情静默挂载 SMB 共享取可用空间; 首扫加载过渡态 ("正在扫描外接盘…"
vs "无盘"可区分); ext* 分区卷标魔数探测 (diskutil 读不了 ext 卷标, 探测不限
fs 类型 — diskutil 对 ext4 报 "Linux Filesystem" 按类型过滤会漏)。

### 已知限制: 深度检测判决仅覆盖 DZAT 读语义 (2026-11-11 记录, 暂不修)

TRIM 后读回语义有三类: DZAT (确定返零) / DRAT (确定返旧数据) / Indeterminate (任意)。
当前 deepTrim/deepTrimNative 的判决是纯 DZAT: 读回全零=✅, 非零=❌。在
DRAT/Indeterminate 设备上, "TRIM 执行了但读回旧数据"与"桥吞 TRIM"物理不可区分
(受理回执与读回结果完全相同, 无外部可观测量) — 存在冤判 ❌ 的理论风险。
评估不改的理由: 消费级 SATA/NVMe SSD (含群联/慧荣/瑞昱系 USB 桥主控) 几乎全是
DZAT 返零型, 实测盘 (铠侠/致态/RTL9210B/JMS583 fw55.01) 无一例外。
若未来遇到疑似冤案, 预案是三态判决: ❶ 归零=✅; ❷ 未归零+能力探针 UNMAP=no
或 ioctl 拒绝=❌; ❸ 未归零+探针支持+受理=⚠️"已受理但读语义不返零, 物理不可判"。

### 排障案例: QEMU 孤儿空转烧 2 核 (2026-11-11 夜, Intel Mac mini)

**现象**: 无 SMB 流量时 QEMU 持续 ~175% CPU (累计 471 分钟), 且 ps 里有两个
QEMU 同时挂同一个 /dev/rdisk2s3。

**根因链 (三环)**:
1. **收尸竞态 (daemon bug, 已修)**: QEMUManager.start() 在 `p.run()` 后先
   sleep 3s 验活再登记 `process` 属性; appQuit/release 若落在这 3s 窗口内,
   releaseInternal 看到 `process == nil` 直接跳过 shutdown → daemon 自毁,
   QEMU 被孤儿化。实测触发场景: pkg 安装后 App 退出, 距 QEMU 启动恰好 2s。
   修复: run() 后立刻登记 process/state, 验活失败再摘除。
2. **孤儿不可达**: daemon 收尸时 unlink 串口 fifo, 后继 daemon 在同路径建新
   inode — 孤儿持有的 fd 指向已删除 inode, 串口注入永远到不了; QMP unix
   socket 同路径被新 VM 重新 bind 夺走; guest 没跑过 init.sh (udhcpc 未执行),
   无网络。三个通道全断, 只能宿主侧 sample/lsof 观察后 kill。
3. **CPU 燃烧点 (sample 实锤)**: 不是 guest 在跑 (两个 vCPU 线程 99% 在
   __psynch_cvwait), 是 QEMU 的 vmnet 后端事件线程 — guest 网卡从未
   `ip link set up`, vmnet 接口事件回调不停触发, 每次 getsockopt +
   qemu_bh_schedule 写 eventfd, 636/736 采样全在这个热循环里。
   即: 任何"guest 没走到配网那步"的 VM 都会一直吃这个 vmnet 事件风暴税。

**附带观察**: 孤儿 QEMU 对 SIGTERM 无响应, 需 -9 (主线程 CFRunLoop
mach_msg 等待, vmnet 热循环可能拖死了关机路径)。

**免疫措施**: 收尸竞态修复后孤儿不再产生; 若 daemon 被 kill -9 等极端情况
仍可能孤儿, 手工排查法 = ps 找多 QEMU → lsof 看 fd 是否指向已删除 inode
→ sample 确认 vmnet 线程热循环 → kill -9。

### 雷电/USB4 硬盘盒兼容性预备 (2026-11-12, 改完待实测)

**背景**: 此前发现链路硬过滤 `DeviceProtocol == "USB"`, 雷电/USB4 盒 (NVMe over
PCIe 隧道) 的盘在 DA 回调里直接被丢弃, App 列表根本看不到。

**改动** (daemon/Sources/anyfsd/main.swift):

1. `wholeUSBDiskBSD` → `wholeExternalDiskBSD`: 协议白名单扩为
   `USB / NVMe / PCI-Express`, 并加 `DAInternal == true` 排除闸
   (Apple Silicon 内置盘协议本是 Apple Fabric 天然不在名单, 双闸防
   其它形态内置 NVMe 混入)。此函数管 onAppear/onDisappear —— 不改的话
   雷电盘接管中被拔出不会触发收尸保护。
2. `usbProductName` → `externalProductName`: IOService 树向上找型号名,
   优先 "USB Product Name" (USB 盒, 行为不变), 整趟找不到回退首个
   "Model" (IONVMe 节点)。缓存 usbNameCache → extNameCache。

**本不需改的部分**: 枚举 (diskutil list external 本就含雷电盘)、接管/QEMU
直通 (/dev/rdiskX 协议无关)、TRIM 链路 (DKIOCUNMAP 是块层 ioctl, 走 macOS
NVMe 栈原生 deallocate, 无桥片翻译)、exFAT 原生养护 (裸设备 ioctl 协议无关)。

**待实测清单** (USB4 盒到货后):

- [ ] 盘出现在 App 列表, 型号名正常 (NVMe 盘 MediaName 通常就是盘型号,
      回退路径大概率用不上)
- [ ] `diskutil info -plist diskN | grep -i protocol` 确认实际协议字符串,
      不在白名单则补上
- [ ] 接管/释放/深度检测全流程
- [ ] `sudo spike/unmap-probe /dev/rdiskN` 验证 NVMe deallocate 通路
- [ ] SMART: `smartctl --scan` + `sudo smartctl -a` — 雷电原生应可读
      (USB 桥时代的 SMART 透传难题在雷电路径不存在)
- [ ] USB 盘回归: 发现/接管/养护确认无回归

### SMB 语义修正: 只读位误导 + AppleDouble 残渣 (2026-11-12, bundle init.sh)

**案发现场**: Linux 侧拷入 ext4 的目录 (权限 711, owner 无写位) 在 Mac 上改名
EPERM; Mac 侧拷入的目录正常。排查链: guest 内 root mv 成功 → 排除文件系统;
chmod 755 后 Mac 仍失败 → 排除即时属性; 重新接管后成功 → **Samba 默认
`map readonly=yes` 从 owner 写位推导 DOS 只读位** (无 vfs_fruit/store dos
attributes 时的行为), 只读目录禁止改名; chmod 后仍失败是 macOS smbfs 客户端
缓存了旧的只读属性, 重挂载清缓存生效。注意 Mac 上 `ls -la` 看到的
`drwxrwxrwx jack staff` 是 SMB 挂载合成值, 不是真实权限。

**修复** (spike/bundle/rootfs/init.sh, smb.conf global):

1. `map readonly = no` — force user=root 下 unix 权限本就拦不住写, 从权限位
   推导的只读位是纯误导 (会拦改名/删除), 直接关闭。选它而非
   `store dos attributes = yes` 的理由: 后者依赖文件系统 xattr 支持,
   Linux exFAT 驱动不支持 xattr, 多文件系统混用有坑
2. `veto files = /._*/.DS_Store/` + `delete veto files = yes` — 拦截
   AppleDouble/Finder 元数据文件: 对客户端不可见不可写 (写入静默失败,
   Finder 照常), 删除目录时连带清理残渣。bundle 里 fruit.so/streams_xattr.so
   都在, 但 fruit 方案同样依赖 xattr (exFAT 不支持), veto 方案全文件系统
   通用。历史 ._ 文件只隐藏不自动删, 需清理时 guest 内
   `find /mnt -name '._*' -delete`

### S3.5 自定义 initramfs 落地 + 接管提速终案 (2026-11-12)

**成绩**: 接管全程 10-20s → **4.5s** (guest boot→BRIDGE-READY 2s)。三段提速:
① daemon 验活 3s 固定 sleep → 串口出现内核输出即放行 (自适应); ② udhcpc
固定 sleep 2s → NET-OK 标记事件化; ③ **S3.5 自定义 initramfs** 干掉 OpenRC/
25 包 tmpfs 安装/modloop 验签, /init 直通。

**形态** (`spike/mk-initramfs.py` 一键构建, 产物 2.4MB vs stock 9.4MB):
busybox+musl (stock 里抽, **busybox 是动态链接**) + 23 个内核模块
(stock 子集闭包 + modloop 提取的 ntfs3/exfat/af_packet, 均零依赖;
extra-modules 再生法见脚本头注释) + 手写 /init (mdev→modprobe→lo up→
假 login 握手兼容 daemon orchestrate) + Python 手写 newc cpio (免 root
造 /dev/console 节点)。冒烟: `spike/guest-itest.sh` 五关 (~15s/轮)。

**环境缺件清单 (每样缺了都是一个坑, 全部实踩)**:
/bin/busybox 路径、musl 加载器+libc、af_packet (udhcpc)、crc32c (ext4 运行时
算法不在 moddep)、/etc/passwd+group (smbd 解析 nobody/root)、/var/run→/run
软链 (ncalrpc)、lo 显式 up (127.0.0.1 不通)、udhcpc $subnet 变量名、
dbus machine-id (init.sh 已把 dbus/avahi 后台化不挡就绪, stock 同受益)。

### 排障案例: Mac mount 全灭 — 10s DNS 超时 (2026-11-12 下午)

**症状**: 自定义 initramfs 下 mount_smbfs/smbutil 全部失败 (Socket is not
connected / Operation timed out), 但 guest 内 smbclient 走 loopback 完全正常。

**冤案清单 (排查路上排除的错误方向)**: ① 两个 QEMU 干扰 (清场后复现);
② 手写 python 协商包被秒拒 (message_id 该用 0 用了 1, 被拒是正确行为, 红鲱鱼);
③ "stock 对照也失败" — **conf sed 因行首空格 `^INITRD` 不匹配根本没生效**
(heredoc 粘进终端时每行被加了缩进, EOF 还漏进了文件), 所谓对照组其实是实验组;
④ host↔guest 裸 TCP "143KB 截断" (nc -w 语义误导, 与本案无关)。

**实锤链**: bridge100 抓包 → macOS 发包完全正常, **guest 收到协商请求后
smbd 用户态恰好卡 10.1s 才回响应** (两次精确 10.1s = 超时值非负载) →
level-10 日志 `smbd_tevent_trace_callback_before_wait: Handling event took
10 seconds!` 确认是单事件处理器内阻塞 → **真·stock 对照 (0.076s) 确认是
custom initramfs 环境差** → 逐项补缺: **/etc/resolv.conf 缺失即卡 10s,
补上 10.20s→0.01s**。根因: musl 解析器在无 resolv.conf 时退化, smbd 首协商
路径上的名字解析吃满 DNS 超时。修法: udhcpc default.script 按 $dns 写
resolv.conf (固化进 mk-initramfs.py)。

**教训**: ① "对照实验"必须先验证对照组真的成立了 (看启动日志确认 OpenRC
标记/Run /init); ② pcap 是终结"客户端还是服务端"争论的终极裁判, 早该上;
③ 缺件的失败模式离缺件位置可以很远 (DNS 配置缺失 → SMB 层 10s 卡顿)。

**pkg 切换已完成 (AnyFS-0.5)**: assemble-app.sh 同包携带 initramfs-anyfs
(默认) + initramfs-virt (兜底), postinstall/install-daemon-from-app.sh 的
INITRD 指向 anyfs 版; 释放路径 umount 后 QMP quit (2c14bd4), 卸载 ~3s。

### guest 内存下限实测: 96MB OOM (2026-11-12)

MEM/SMP 已支持 conf 覆盖 (daemon Config.loadOverrides)。96MB 冒烟五关全过
(启动/网络/bundle/init.sh 均正常), 但**真实 SMB 写入负载下 guest OOM 杀 smbd**
(512MB 随机写压测, `Out of memory: Killed process (smbd)`): 空闲 25MB 是假象,
持续写入时页缓存+写回缓冲瞬间吃光配额。结论: 128MB 维持为下限, 不建议下调。

### 稳定运行上限: 同时最多接管 2 个分区 (2026-11-12)

daemon takeover 入口硬限制 (Config.maxTakeoverParts, 默认 2, conf `MAX_PARTS=` 可覆盖):
超过直接 `failed: 同时最多接管 N 个分区`, 在动 QEMU 之前拒绝。理由: 单 VM 全包架构下
每加一个分区 = 一路 SCSI 直通盘 + 一个 SMB 导出 + 串口编排/收尸复杂度, 内存
(默认 128MB) 与故障域余量按 2 设计; 真要多盘场景建议排队使用而非并发。
注意部分释放的重启续上路径 (`release` → 剩余集合重 takeover) 也过同一 guard,
remaining ≤ 原集合恒成立, 不会误伤。

### 雷电/USB4 硬盘盒实测全绿 (2026-11-15, ASM2464PD + 致态 Ti600)

实测清单 (对 2026-11-12 预备清单逐项验收, 设备为 ASMedia 246x 盒 @ 40Gb/s):

- [x] 盘出现在列表: DeviceProtocol=**PCI-Express** (白名单含此项, 预备时的
      双候选 NVMe/PCI-Express 判断正确), DAInternal=false 双闸生效;
      GPT 混合盘 (EFI+APFS+NTFS) 正确只列 NTFS, APFS 留给 macOS
- [x] 接管/QEMU 直通/释放: 全通, 与 USB 盘无差异
- [x] 界面标识: "雷电/USB4 · PCIe 隧道" 显示正确 (system_profiler 旁证
      40Gb/s 协商)
- [x] TRIM: 深度检测 **2.2s 物理归零** — NVMe deallocate 原生通路,
      无桥片翻译层, 比 USB 桥更干脆
- [x] SMART 宿主直读: **smartctl -a 完整 NVMe 健康数据可读** (7.5, Darwin
      原生) — USB 桥时代"SMART 不可达"死穴在雷电 PCIe 隧道不存在;
      **健康监控功能走 daemon 宿主直读路线可行性实锤**
- [x] SMB 速度: 写 432 / 读 502 MB/s (瓶颈 smbd 单线程, 与 USB 盘一致)

Ti600 健康快照: PASSED, 寿命 3%, 备用块 100%, 写入 12.3TB, 上电 2410h,
不安全断电 108 次 (非正常拔出成本的可量化证据)。
