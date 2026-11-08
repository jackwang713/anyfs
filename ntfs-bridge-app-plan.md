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
| RTL9210B | USB3 | ✅ 通过 | 2026-11-02 实测：DKIOCUNMAP → 图案读回全零（TRIM-EXECUTED）；**SMART 经 sntrealtek 完整可读（Linux 侧）**。注：App 架构内（macOS 宿主）SMART 不可得——已穷举证伪：smartctl 无透传、QEMU scsi-generic 依赖 Linux SG_IO、SCSITaskLib 插件已注销（kIOReturnUnsupported）、苹果私有 SAT 路径仅插盘探测期瞬态可见（磁盘工具稳定"不支持"）；健康监控功能定为写入探针间接评估 |
| ASM2364 | USB3 | ✅ | workaround 后有效 |
| ASM2464PD | USB4/雷电 | ✅ 原生 | PCIe 直通，无桥接层问题 |

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

**处理**：`rm -rf ~/Library/Group\ Containers/group.com.apple.coreservices.useractivityd/shared-pasteboard/*`（安全，系统下次传输自动重建；建议只清 1 小时前的条目以免切断进行中的同步）。日常清理工具：[Mole](https://github.com/tw93/mole)（`brew install mole`，开源，源码含该目录的 1 小时安全闸清理）；腾讯柠檬不覆盖此目录。

#### 对本项目的启示（backlog）

- App 可加防护：SMB 挂载掉线/未就绪时，若用户往原挂载点目录粘贴会写到**本机 SSD**（/Volumes 下残留目录），考虑卸载后删除空挂载点目录 + 状态提示
- 性能问题排查顺序固化：先 guest 裸盘 dd 定盘体上限 → 再 guest 内文件级 dd 隔 SMB → 最后宿主 SMB 测；宿主侧低速先看数据源是否经剪贴板/无线
