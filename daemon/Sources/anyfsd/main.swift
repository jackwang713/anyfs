// anyfsd — anyFS privileged daemon (S5.1: 分区级直通 + 显式接管)
// 职责: 枚举外接盘分区 → 按 App/XPC 指令接管选中分区(启VM) → 释放/退出时干净收尸
// 运行方式: root (launchd, /Library/LaunchDaemons/com.anyfs.daemon.plist)
// 设计: 不再自动接管 (DA 只用于枚举刷新和拔盘保护); 接管粒度=分区 (/dev/rdiskXsY);
//       单 VM 挂多个分区设备; 同盘未选中的分区 (如 APFS) 留给 macOS 原生使用
import Foundation
import DiskArbitration
import IOKit
import SystemConfiguration   // SCDynamicStoreCopyConsoleUser: 取当前登录用户 uid

// MARK: - 配置 (打包形态: /usr/local/etc/anyfsd.conf 覆盖 dev 默认路径)
struct Config {
    static let confPath    = "/usr/local/etc/anyfsd.conf"
    static let spikeDir    = "/Users/jack/Documents/anyfs/spike"
    static var qemu        = "\(spikeDir)/qemu-11.1.2/build/qemu-system-aarch64"
    static var kernel      = "\(spikeDir)/alpine/vmlinuz-virt"
    static var initrd      = "\(spikeDir)/alpine/initramfs-virt"
    static var iso         = "\(spikeDir)/alpine/alpine-virt.iso"
    static var bundle      = "\(spikeDir)/bundle/bundle.img"
    static var guestMemMB  = 128
    static var guestSMP    = 2
    static let serialBase  = "/tmp/anyfsd-serial"
    static let qmpPath     = "/tmp/anyfsd.qmp"
    static let xpcName     = "com.anyfs.daemon"
    static let logPath     = "/var/log/anyfsd.log"
    static let statePath   = "/tmp/anyfsd.state"
    // 可接管的文件系统 (diskutil list -plist 的字段值; MBR 盘的 Content 命名不同, 见下)
    static let supportedFSTypes: Set<String> = ["ntfs","exfat","msdos","vfat","ext4","ext3","ext2"]
    static let supportedContent: Set<String> = ["Microsoft Basic Data","Basic Data","Linux","Linux Filesystem",
                                                "Windows_FAT_32","Windows_FAT_16","Windows_NTFS","Windows_EXFAT",
                                                "DOS_FAT_32","DOS_FAT_16","DOS_FAT_12"]

    // pkg 安装后资产位于 .app/Contents/Resources, 由 postinstall 写 conf 覆盖路径
    static func loadOverrides() {
        guard let s = try? String(contentsOfFile: confPath, encoding: .utf8) else { return }
        for line in s.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard kv.count == 2, !kv[0].hasPrefix("#") else { continue }
            switch kv[0] {
            case "QEMU":   qemu   = kv[1]
            case "KERNEL": kernel = kv[1]
            case "INITRD": initrd = kv[1]
            case "ISO":    iso    = kv[1]
            case "BUNDLE": bundle = kv[1]
            case "MEM":    guestMemMB = Int(kv[1]) ?? guestMemMB
            case "SMP":    guestSMP = Int(kv[1]) ?? guestSMP
            default: break
            }
        }
        log("已加载 \(confPath): qemu=\(qemu)")
    }
}

// MARK: - 日志
final class Log {
    static let shared = Log()
    private var handle: FileHandle?
    private init() {
        if !FileManager.default.fileExists(atPath: Config.logPath) {
            FileManager.default.createFile(atPath: Config.logPath, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: Config.logPath)
        handle?.seekToEndOfFile()
    }
    func write(_ s: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        handle?.write(line.data(using: .utf8)!)
    }
}
func log(_ s: String) { Log.shared.write(s) }

// MARK: - 串口管道 (QEMU -serial pipe:)
final class SerialPipe {
    let base: String
    private var outFD: Int32 = -1
    private var inFD:  Int32 = -1
    private(set) var transcript = ""
    private let lock = NSLock()

    init(base: String) { self.base = base }

    func prepare() throws {
        unlink("\(base).in"); unlink("\(base).out")
        if mkfifo("\(base).in", 0o600) != 0 || mkfifo("\(base).out", 0o600) != 0 {
            throw NSError(domain: "anyfsd", code: 1, userInfo: [NSLocalizedDescriptionKey: "mkfifo failed: \(errno)"])
        }
    }

    func startReader(queue: DispatchQueue) {
        queue.async { [weak self] in
            guard let self else { return }
            self.outFD = open("\(self.base).out", O_RDONLY)
            guard self.outFD >= 0 else { log("serial: open .out failed"); return }
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(self.outFD, &buf, buf.count)
                if n <= 0 { break }
                let chunk = String(decoding: buf[0..<n], as: UTF8.self)
                self.lock.lock()
                self.transcript += chunk
                if self.transcript.count > 1_000_000 {
                    self.transcript = String(self.transcript.suffix(500_000))
                }
                self.lock.unlock()
            }
        }
    }

    func send(_ s: String) {
        if inFD < 0 { inFD = open("\(base).in", O_WRONLY | O_NONBLOCK) }
        guard inFD >= 0 else { log("serial: writer unavailable"); return }
        _ = s.withCString { write(inFD, $0, strlen($0)) }
    }

    func contains(_ needle: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transcript.contains(needle)
    }

    func cleanup() {
        if inFD >= 0 { close(inFD); inFD = -1 }
        if outFD >= 0 { close(outFD); outFD = -1 }
        unlink("\(base).in"); unlink("\(base).out")
    }

    var length: Int {
        lock.lock(); defer { lock.unlock() }
        return transcript.count
    }

    func containsAfter(_ needle: String, offset: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard offset < transcript.count else { return false }
        return transcript[transcript.index(transcript.startIndex, offsetBy: offset)...].contains(needle)
    }

    func substringAfter(_ offset: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        guard offset < transcript.count else { return "" }
        return String(transcript[transcript.index(transcript.startIndex, offsetBy: offset)...])
    }

    // 末尾 N 行 (anyfsctl console 诊断用)
    func tail(_ maxLines: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return transcript.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(maxLines).joined(separator: "\n")
    }
}

// MARK: - QMP 客户端 (QEMU monitor JSON 协议)
final class QMPClient {
    private var fd: Int32 = -1

    deinit { if fd >= 0 { close(fd) } }

    func connect(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "qmp", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket failed"]) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { strcpy($0, path) }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            close(fd); fd = -1
            throw NSError(domain: "qmp", code: 2, userInfo: [NSLocalizedDescriptionKey: "connect failed: \(errno)"])
        }
        _ = try readLine()          // 读 QMP greeting
        _ = try execute("qmp_capabilities")
    }

    func execute(_ command: String) throws -> String {
        let json = "{\"execute\":\"\(command)\"}\n"
        _ = json.withCString { write(fd, $0, strlen($0)) }
        return try readLine()
    }

    private func readLine() throws -> String {
        var out = Data()
        var b = [UInt8](repeating: 0, count: 4096)
        while !out.contains(0x0a) {
            let n = read(fd, &b, b.count)
            if n <= 0 { throw NSError(domain: "qmp", code: 3, userInfo: [NSLocalizedDescriptionKey: "read failed"]) }
            out.append(contentsOf: b[0..<n])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

// MARK: - QEMU 管理 (一个 VM, 可挂多个分区设备)
final class QEMUManager {
    let partitions: [String]
    var partLabels: [String: String] = [:]   // bsd → 真实卷标 (宿主 diskutil 为准)
    private var process: Process?
    private(set) var state = "stopped"
    let serial = SerialPipe(base: Config.serialBase)
    private var stderrBuf = ""

    init(partitions: [String]) { self.partitions = partitions }

    // 只卸选中的目标 (不可用 unmountDisk 整盘 — 会波及留给 macOS 的 APFS 等分区);
    // 整盘 (superfloppy) 同样要卸: NTFS/exFAT 整盘会被 macOS fskit 只读自动挂载,
    // 不压掉就是 guest/macOS 双持; ext4 整盘 macOS 挂不上, unmount 报错无害
    private func unmountTargetsSync() {
        for part in partitions {
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            t.arguments = ["unmount", "force", "/dev/\(part)"]
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            try? t.run()
            t.waitUntilExit()
        }
    }

    func start() throws {
        try serial.prepare()
        serial.startReader(queue: DispatchQueue(label: "serial-reader"))

        for attempt in 1...5 {
            unmountTargetsSync()

            let p = Process()
            p.executableURL = URL(fileURLWithPath: Config.qemu)
            // 架构分支 (编译期确定, 同一份源码双平台): Intel=q35/ttyS0, Apple Silicon=virt/ttyAMA0
            #if arch(arm64)
            let machine = "virt,accel=hvf"
            let consoleArg = "console=ttyAMA0"
            #else
            let machine = "q35,accel=hvf"
            let consoleArg = "console=ttyS0"
            #endif
            var args = [
                "-machine", machine,
                "-cpu", "host", "-smp", "\(Config.guestSMP)", "-m", "\(Config.guestMemMB)",
                "-kernel", Config.kernel,
                "-initrd", Config.initrd,
                "-append", consoleArg,
                "-drive", "file=\(Config.iso),format=raw,if=virtio,readonly=on",
                "-drive", "file=\(Config.bundle),format=raw,if=virtio,readonly=on",
                "-object", "iothread,id=io0",
                "-device", "virtio-scsi-pci,id=scsi0,iothread=io0",
            ]
            for (i, part) in partitions.enumerated() {
                args += ["-drive", "file=/dev/r\(part),format=raw,if=none,id=usbdisk\(i),discard=unmap"]
                args += ["-device", "scsi-hd,bus=scsi0.0,drive=usbdisk\(i),scsi-id=\(i),discard_granularity=512"]
            }
            args += [
                "-netdev", "vmnet-shared,id=n0",
                "-device", "virtio-net-pci,netdev=n0",
                "-serial", "pipe:\(Config.serialBase)",
                "-qmp", "unix:\(Config.qmpPath),server,nowait",
                "-display", "none", "-monitor", "none",
            ]
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    // EOF: 必须注销, 否则 handler 空转 100% CPU
                    fh.readabilityHandler = nil
                    return
                }
                if let s = String(data: d, encoding: .utf8) { self.stderrBuf += s }
            }
            p.terminationHandler = { proc in
                log("QEMU 退出, code=\(proc.terminationStatus)")
                if !self.stderrBuf.isEmpty {
                    log("QEMU stderr: \(self.stderrBuf.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                self.state = "exited(\(proc.terminationStatus))"
            }
            try p.run()
            // 进程登记必须先于验活 sleep: 窗口内到达的 appQuit/release 收尸依赖
            // process 非空才能 terminate (2026-11-11 实踩: 登记在 sleep 后,
            // appQuit 落在 3s 窗口内 → 收尸跳过 → QEMU 孤儿空转烧 2 核)
            process = p
            state = "running"
            log("QEMU 已启动 pid=\(p.processIdentifier) (第\(attempt)次) 分区=\(partitions.joined(separator: ","))")
            // 自适应验活 (原固定 3s): 串口出现内核输出即证明活过启动危险窗
            // (实测输出 ~0.3s 到达, 省 ~2.5s); 早夭 (如 Resource busy 抢盘) 立即落出进重试
            let aliveDeadline = Date().addingTimeInterval(3)
            while p.isRunning && serial.length == 0 && Date() < aliveDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning {
                return
            }
            process = nil
            state = "stopped"
            if stderrBuf.contains("Resource busy") {
                log("第 \(attempt) 次被抢挂, 重试...")
                stderrBuf = ""
                continue
            }
            throw NSError(domain: "anyfsd", code: 2, userInfo: [NSLocalizedDescriptionKey: "QEMU 启动失败: \(stderrBuf)"])
        }
        throw NSError(domain: "anyfsd", code: 3, userInfo: [NSLocalizedDescriptionKey: "重试 5 次仍被抢挂"])
    }

    func orchestrate() -> Bool {
        state = "booting"
        if !waitFor("login:", timeout: 180) { log("超时: 未等到 login"); return false }
        serial.send("\nroot\n")
        if !waitFor(":~#", timeout: 30) { log("超时: 未进入 shell"); return false }
        // 租约到位才继续 (原固定 sleep 2s; 标记拆断防 tty 回显误匹配, 实测 <0.5s)
        serial.send("ip link set eth0 up && udhcpc -i eth0 -q && echo NET-\"\"OK\n")
        if !waitFor("NET-OK", timeout: 15) { log("超时: 未拿到 IP 租约"); return false }
        serial.send("mount -t ext2 -o ro /dev/vdb /opt\n")
        // 注入真实卷标映射: guest busybox blkid 读非 ASCII 卷标 (中文 FAT32 等) 会乱码。
        // 键用 tgt<N> (= scsi-id), 不用 sda/sdb 字母 — SCSI 异步探测字母是竞争结果,
        // init.sh 按 sysfs target 对位 (2026-11-11 实踩字母交换致卷标张冠李戴)
        for (i, part) in partitions.enumerated() {
            guard let label = partLabels[part], !label.isEmpty else { continue }
            let safe = label.replacingOccurrences(of: "'", with: "")
                            .replacingOccurrences(of: "\\", with: "")
                            .replacingOccurrences(of: "\n", with: "")
            serial.send("echo 'tgt\(i)=\(safe)' >> /tmp/anyfs-names\n")
        }
        serial.send("sh /opt/init.sh\n")
        state = "guest-init"
        if waitFor("BRIDGE-READY", timeout: 120) {
            state = "ready"
            log("BRIDGE-READY: \(partitions.joined(separator: ",")) guest 服务就绪")
            return true
        }
        log("超时: 未就绪 (见串口记录)")
        return false
    }

    private func waitFor(_ needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if serial.contains(needle) { return true }
            if state.hasPrefix("exited") { return false }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // 干净退出三段式 (盘还在) — 释放/App退出/守护进程退出路径
    func shutdown(graceSeconds: TimeInterval = 10) {
        guard let p = process, p.isRunning else { return }
        unmountSMBShares()
        log("干净退出: 通知 guest umount ...")
        serial.send("sync; for d in /mnt/*/; do umount \"$d\" 2>/dev/null; done\n")
        Thread.sleep(forTimeInterval: 2)
        // QMP quit 直接收: sync+umount 已完成, 数据安全已保证, 关机只是收进程。
        // 不依赖 guest init 形态 — 自定义 initramfs 无 init 系统, poweroff 无人
        // 理会 → 白等满 10s 宽限才强杀 (实测每次释放 12s)
        var qmpQuit = false
        if let qmp = try? QMPClient(), (try? qmp.connect(path: Config.qmpPath)) != nil {
            qmpQuit = (try? qmp.execute("quit")) != nil
        }
        if !qmpQuit {
            log("QMP 不可用, 回退串口 poweroff")
            serial.send("poweroff -f\n")
        }
        let deadline = Date().addingTimeInterval(qmpQuit ? 3 : graceSeconds)
        while Date() < deadline && p.isRunning { Thread.sleep(forTimeInterval: 0.5) }
        if p.isRunning {
            log("guest 未及时关机, 强制 terminate (脏位风险)")
            p.terminate()
        } else {
            log("guest 已干净关机")
        }
        finishCleanup()
    }

    // 盘已消失的快速收尸 (拔出路径), 或接管失败的资源回收
    func forceTeardown() {
        unmountSMBShares()
        log("回收 QEMU 资源")
        if let p = process, p.isRunning { p.terminate() }
        finishCleanup()
    }

    private func finishCleanup() {
        serial.cleanup()
        state = "stopped"
    }

    // 只卸 anyFS 自己的 SMB 挂载 (不能误伤用户其他 SMB/NAS 挂载)
    private func unmountSMBShares() {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let pipe = Pipe()
        t.standardOutput = pipe
        try? t.run()
        t.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            guard line.contains("smbfs"),
                  line.contains("anyFS") || line.contains("192.168.64.") else { continue }
            guard let onRange = line.range(of: " on "),
                  let paren = line.range(of: " (", options: .backwards) else { continue }
            let mp = String(line[onRange.upperBound..<paren.lowerBound])
            log("卸载 SMB 挂载点: \(mp)")
            let u = Process()
            u.executableURL = URL(fileURLWithPath: "/sbin/umount")
            u.arguments = [mp]
            u.standardOutput = FileHandle.nullDevice
            u.standardError = FileHandle.nullDevice
            try? u.run()
            u.waitUntilExit()
        }
    }

    var isRunning: Bool { process?.isRunning ?? false }
}

// MARK: - 磁盘事件管理 (Disk Arbitration)
final class DiskManager {
    static let shared = DiskManager()
    private var session: DASession?
    private var qemu: QEMUManager?
    private var busy = false
    private let lock = NSLock()
    private(set) var activeParts: Set<String> = []
    private var parentDisks: Set<String> = []
    private var createdMountpoints: Set<String> = []
    // diskutil info 结果缓存: fs类型/卷标/型号不随时间变, 且对 macOS 不认识的
    // 分区 (ext4 等) 每次 info 都会触发真实介质探测读 (U盘灯闪的元凶), 必须缓存;
    // 插拔/属性变更 (重格式化) 时经 DA 回调整体失效
    private var infoCache: [String: [String: Any]] = [:]
    // 整盘 (superfloppy, 无分区表) 探测出的卷标缓存, 随 infoCache 一并失效
    private var wholeDiskLabels: [String: String] = [:]
    // 整盘探测结果缓存 (fs 为空串 = 已探测但不支持): 探测要真读盘, 不缓存会每次枚举都闪灯
    private var wholeDiskProbe: [String: (fs: String, label: String)] = [:]

    // 整盘文件系统魔数探测 — 无分区表的盘 macOS 完全无感知 (Content=None),
    // daemon 是 root 直接读裸盘固定偏移签名 (与 Linux blkid 同原理, 确定性识别非猜测);
    // 只识别 guest init.sh 支持的类型; 结果含"不支持"也缓存 (fs="")
    private func probeWholeDisk(_ bsd: String) -> (fs: String, label: String)? {
        lock.lock()
        if let c = wholeDiskProbe[bsd] { lock.unlock(); return c.fs.isEmpty ? nil : c }
        lock.unlock()
        let result = probeWholeDiskUncached(bsd) ?? ("", "")
        lock.lock(); wholeDiskProbe[bsd] = result; lock.unlock()
        return result.fs.isEmpty ? nil : result
    }

    private func probeWholeDiskUncached(_ bsd: String) -> (fs: String, label: String)? {
        let fd = open("/dev/r\(bsd)", O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        func at(_ off: Int64, _ len: Int) -> [UInt8]? {
            // 裸盘字符设备要求偏移和长度都按扇区 (512) 对齐, 否则 pread 直接失败
            let sector: Int64 = 512
            let start = off / sector * sector
            let total = Int((off + Int64(len) + sector - 1) / sector * sector - start)
            var buf = [UInt8](repeating: 0, count: total)
            guard pread(fd, &buf, total, start) == total else { return nil }
            let s = Int(off - start)
            return Array(buf[s..<(s + len)])
        }
        if let m = at(3, 8) {
            if m == Array("EXFAT   ".utf8) { return ("exfat", "") }
            if m == Array("NTFS    ".utf8) { return ("ntfs", "") }
        }
        if let m = at(82, 8), m == Array("FAT32   ".utf8) { return ("msdos", "") }
        if let m = at(16, 8), m == Array("FAT16   ".utf8) { return ("msdos", "") }
        // ext2/3/4: 超级块在偏移 1024, 魔数 0x53EF 在 +56, 卷标在 +120 (16 字节, NUL 填充)
        if let m = at(1080, 2), m == [0x53, 0xEF] {
            var label = ""
            if let raw = at(1144, 16) {
                let bytes = raw.prefix { $0 != 0 }
                label = String(decoding: bytes, as: UTF8.self)
            }
            return ("ext4", label)
        }
        return nil
    }

    // 为 App 预建 SMB 挂载点: /Volumes 是 root:wheel 普通用户不可建,
    // 由 daemon (root) 创建并 chown 给当前登录用户, App 随后以用户身份 mount_smbfs
    func prepareMountpoint(_ name: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let mp = "/Volumes/\(safe)"
        if !FileManager.default.fileExists(atPath: mp) {
            var uid: uid_t = 0, gid: gid_t = 0
            _ = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid)
            do {
                try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: false)
            } catch {
                return "failed: mkdir \(mp): \(error.localizedDescription)"
            }
            if uid != 0 { chown(mp, uid, gid) }
            lock.lock(); createdMountpoints.insert(mp); lock.unlock()
            log("已创建挂载点 \(mp) (uid=\(uid))")
        }
        return mp
    }

    func start() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            log("DASessionCreate 失败")
            return
        }
        self.session = session
        DARegisterDiskAppearedCallback(session, nil, { disk, _ in
            DiskManager.shared.onAppear(disk)
        }, nil)
        DARegisterDiskDisappearedCallback(session, nil, { disk, _ in
            DiskManager.shared.onDisappear(disk)
        }, nil)
        // 挂载审批: 接管期间否决对已接管分区的挂载 (事件驱动, 零轮询)
        // 按分区精确匹配 — 同盘未接管的分区 (APFS 等) 不受影响
        DARegisterDiskMountApprovalCallback(session, nil, { disk, _ in
            DiskManager.shared.mountApproval(disk: disk)
        }, nil)
        // 属性变更 (重格式化/重命名卷标等) → 枚举缓存失效
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, _ in
            DiskManager.shared.invalidateInfoCache("磁盘属性变更")
        }, nil)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        log("DA 注册完成 (仅枚举/拔盘保护, 不自动接管)")
    }

    // 返回非 nil 即否决挂载
    func mountApproval(disk: DADisk) -> Unmanaged<DADissenter>? {
        guard let bsdPtr = DADiskGetBSDName(disk) else { return nil }
        let bsd = String(cString: bsdPtr)
        lock.lock(); let active = activeParts.contains(bsd); lock.unlock()
        guard active else { return nil }
        log("拦截挂载请求 \(bsd) (anyFS 已接管)")
        let d = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted),
                                  "anyFS 正在接管此分区" as CFString)
        return Unmanaged.passRetained(d)
    }

    // 协议白名单: USB 大容量存储 + 雷电/USB4 盒的 NVMe (PCIe 隧道直出);
    // DAInternal=true 一律排除 — Apple Silicon 内置盘协议本是 Apple Fabric 不在名单,
    // 双闸防其它形态内置 NVMe 混入
    private func wholeExternalDiskBSD(_ disk: DADisk) -> String? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true
        else { return nil }
        if (desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool) == true { return nil }
        let proto = (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) ?? ""
        guard ["USB", "NVMe", "PCI-Express"].contains(proto) else { return nil }
        return bsd
    }

    // disk3s3 → disk3 (用于判断拔出事件是否波及已接管分区)
    private func parentDisk(of part: String) -> String {
        if let r = part.range(of: #"s\d+$"#, options: .regularExpression) {
            return String(part[..<r.lowerBound])
        }
        return part
    }

    private func invalidateInfoCache(_ reason: String) {
        lock.lock(); infoCache.removeAll(); wholeDiskLabels.removeAll(); wholeDiskProbe.removeAll(); extNameCache.removeAll(); lock.unlock()
        log("枚举缓存已清空 (\(reason))")
    }

    private func onAppear(_ disk: DADisk) {
        guard let bsd = wholeExternalDiskBSD(disk) else { return }
        // bsd 名会复用 (新盘可能仍叫 disk2), 插拔一律清缓存
        invalidateInfoCache("插入 \(bsd)")
        log("DiskArb: 外接盘插入 \(bsd) (等待 App 指令, 不自动接管)")
    }

    private func onDisappear(_ disk: DADisk) {
        guard let bsd = wholeExternalDiskBSD(disk) else { return }
        invalidateInfoCache("拔出 \(bsd)")
        lock.lock()
        let affected = activeParts.filter { parentDisk(of: $0) == bsd }.sorted()
        lock.unlock()
        guard !affected.isEmpty else { return }
        log("DiskArb: 已接管盘 \(bsd) 被拔出, 受影响分区: \(affected)")
        lock.lock()
        let remaining = activeParts.subtracting(affected).sorted()
        activeParts = []; parentDisks = []
        lock.unlock()
        let q = qemu
        qemu = nil
        DispatchQueue(label: "teardown").async {
            if let q, q.isRunning {
                log("非正常拔出, 直接回收 QEMU (该盘 guest umount 已无意义)")
                q.forceTeardown()
            }
            FileManager.default.createFile(atPath: Config.statePath, contents: "ejected-abnormal \(affected.joined(separator: ","))\n".data(using: .utf8))
            self.busy = false
            // 多盘场景: 其他盘的分区不应陪葬, 重启 VM 恢复 (v1 复用 takeover 干净重启路径)
            if !remaining.isEmpty {
                log("剩余分区 \(remaining) 属于其他盘, 重启 VM 恢复服务")
                self.takeover(remaining) { s in log("拔出后重启: \(s)") }
            }
        }
    }

    // MARK: XPC 暴露的操作接口

    // diskutil info 带缓存 (对 macOS 不认识的文件系统, 每次 info 都会真读盘探测)
    private func infoOf(_ bsd: String) -> [String: Any] {
        lock.lock()
        if let c = infoCache[bsd] { lock.unlock(); return c }
        lock.unlock()
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        t.arguments = ["info", "-plist", bsd]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let obj = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        lock.lock(); infoCache[bsd] = obj; lock.unlock()
        return obj
    }

    // diskutil list -plist 不填 FilesystemType, 用 info 补全 (ntfs/exfat/msdos/ext*)
    private func fsTypeOf(_ bsd: String) -> String {
        let obj = infoOf(bsd)
        return (obj["FilesystemName"] as? String) ?? (obj["FilesystemType"] as? String) ?? ""
    }

    // 整盘型号 (UI 分组标题): MediaName, 如 "RTL9210B-CG";
    // 廉价盒子会上报垃圾 MediaName (JMS583 盒实测上报 "3.2"), 字母数 <2 判为垃圾,
    // 回退 IOKit: USB 树找 "USB Product Name", NVMe (雷电盒) 树找 "Model"
    private var extNameCache: [String: String] = [:]
    private func modelOf(_ wholeBsd: String) -> String {
        let obj = infoOf(wholeBsd)
        let media = (obj["MediaName"] as? String) ?? ""
        if media.filter(\.isLetter).count >= 2 { return media }
        lock.lock(); let cached = extNameCache[wholeBsd]; lock.unlock()
        if let cached { return cached }
        let resolved = externalProductName(for: wholeBsd) ?? (media.isEmpty ? wholeBsd : media)
        lock.lock(); extNameCache[wholeBsd] = resolved; lock.unlock()
        return resolved
    }

    // 沿 IOService 树从 IOMedia (BSD Name 匹配) 向上找型号名:
    // 优先 "USB Product Name" (USB 盒); 整趟找不到则回退首个 "Model" (NVMe 节点)
    private func externalProductName(for wholeBsd: String) -> String? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        while case let obj = IOIteratorNext(it), obj != 0 {
            let name = IORegistryEntryCreateCFProperty(obj, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            if name == wholeBsd {
                var cur = obj
                var result: String? = nil
                var model: String? = nil   // 兜底: NVMe 节点的 Model
                while true {
                    if let pn = IORegistryEntryCreateCFProperty(cur, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String {
                        result = pn
                        if cur != obj { IOObjectRelease(cur) }
                        break
                    }
                    if model == nil, let m = IORegistryEntryCreateCFProperty(cur, "Model" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String {
                        model = m
                    }
                    var parent: io_registry_entry_t = 0
                    let kr = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent)
                    if cur != obj { IOObjectRelease(cur) }
                    guard kr == KERN_SUCCESS, parent != 0 else { break }
                    cur = parent
                }
                IOObjectRelease(obj)
                return result ?? model
            }
            IOObjectRelease(obj)
        }
        return nil
    }

    // 真实卷标 (注入 guest 用; diskutil 读非 ASCII 卷标无乱码问题)
    private func volumeNameOf(_ bsd: String) -> String {
        infoOf(bsd)["VolumeName"] as? String ?? ""
    }

    // guest SMB 共享名的唯一来源 (App 显示/daemon 注入/guest 挂载点三方必须一致):
    // ASCII 卷标用卷标 (空格转下划线, 与 guest init.sh 的 tr 一致),
    // 非 ASCII 或空卷标回退 bsd — mount_smbfs 的 URL 解析器不接受非 ASCII
    // 共享名基础值 (卷标/回退; 不含重名去重后缀)
    private func baseShareName(_ part: String) -> String {
        let diskutilLabel = volumeNameOf(part)
        lock.lock(); let probed = wholeDiskLabels[part] ?? ""; lock.unlock()
        var label = diskutilLabel.isEmpty ? probed : diskutilLabel
        // ext* 分区 macOS 读不了卷标 → 魔数探测超级块 (probeWholeDisk 带缓存)
        if label.isEmpty, let pr = probeWholeDisk(part), !pr.label.isEmpty { label = pr.label }
        guard !label.isEmpty, label.allSatisfy(\.isASCII) else { return part }
        return label.replacingOccurrences(of: " ", with: "_")
    }

    // 共享名 = init.sh 挂载点名: 基础值 + 重名去重 (-2/-3, 按直通顺序确定性生成)
    // 必须与 init.sh 的去重逻辑一致: 遍历 partitions 数组序, 同名第 N 个加 -N
    func shareNameOf(_ part: String) -> String {
        let base = baseShareName(part)
        lock.lock(); let parts = qemu?.partitions ?? []; lock.unlock()
        guard let idx = parts.firstIndex(of: part), idx > 0 else { return base }
        var n = 0
        for j in 0..<idx where baseShareName(parts[j]) == base { n += 1 }
        return n == 0 ? base : "\(base)-\(n + 1)"
    }

    // 枚举外接盘上的可接管分区 (NTFS/exFAT/ext* 等)
    func listAvailable() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        t.arguments = ["list", "-plist", "external"]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let disks = obj["AllDisksAndPartitions"] as? [[String: Any]] else { return out }
        lock.lock(); let active = activeParts; lock.unlock()
        for d in disks {
            let parts = d["Partitions"] as? [[String: Any]] ?? []
            // 整盘文件系统 (superfloppy): 无 Partitions 且 Content 为空 — macOS 无法识别,
            // 读魔数探测; 有分区表的盘 (哪怕分区都不可接管) 不探测, 避免整盘/分区双列
            if parts.isEmpty {
                let dContent = d["Content"] as? String ?? ""
                guard dContent.isEmpty,
                      let bsd = d["DeviceIdentifier"] as? String,
                      let size = d["Size"] as? Int, size > 0,
                      let probe = probeWholeDisk(bsd) else { continue }
                lock.lock()
                if !probe.label.isEmpty { wholeDiskLabels[bsd] = probe.label }
                lock.unlock()
                // 卷标: macOS 认识的整盘 (NTFS/exFAT 会被 fskit 只读自动挂载) 用 diskutil 卷名,
                // 不认识的 (ext4) 用魔数探测出的卷标, 都没有则显示"型号 整盘"
                let volLabel = volumeNameOf(bsd)
                let displayLabel = !volLabel.isEmpty ? volLabel
                    : (!probe.label.isEmpty ? probe.label : "\(modelOf(bsd)) 整盘")
                out.append([
                    "bsd": bsd,
                    "label": displayLabel,
                    "share": shareNameOf(bsd),
                    "fs": probe.fs,
                    "disk": bsd,
                    "model": modelOf(bsd),
                    "sizeGB": String(format: "%.1f", Double(size) / 1e9),
                    "mounted": !((infoOf(bsd)["MountPoint"] as? String) ?? "").isEmpty,
                    "active": active.contains(bsd),
                ])
                continue
            }
            for p in parts {
                guard let bsd = p["DeviceIdentifier"] as? String else { continue }
                let fs = (p["FilesystemType"] as? String ?? "").lowercased()
                let content = p["Content"] as? String ?? ""
                // EFI 系统分区永不列为候选 (macOS 原生可读写, 接管零收益且是引导分区)
                if content == "EFI" { continue }
                // MBR 盘的 Content 命名与 GPT 不同 (Windows_FAT_32 等),
                // 且 list -plist 不填 FilesystemType — 先用 info 拿真实 fs 类型再过滤
                let infoFS = fsTypeOf(bsd)
                let infoMatch = Config.supportedFSTypes.contains(infoFS.lowercased())
                    || infoFS.lowercased().contains("ntfs") || infoFS.lowercased().contains("exfat")
                    || infoFS.lowercased().contains("fat") || infoFS.lowercased().contains("ext")
                guard Config.supportedFSTypes.contains(fs) || Config.supportedContent.contains(content) || infoMatch else { continue }
                let volName = (p["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                // macOS 读不了卷标的分区 (ext* 等) → 魔数探测超级块
                // (与整盘探测同路径, 带缓存; 不限 fs 类型 — diskutil 对 ext4
                // 报 "Linux Filesystem" 不含 ext, 按类型过滤会漏, 一律探)
                var probedLabel: String? = nil
                if volName == nil, let pr = probeWholeDisk(bsd), !pr.label.isEmpty {
                    probedLabel = pr.label
                }
                let parent = parentDisk(of: bsd)
                out.append([
                    "bsd": bsd,
                    "label": volName ?? probedLabel ?? (p["FilesystemName"] as? String) ?? bsd,
                    "share": shareNameOf(bsd),
                    "fs": !infoFS.isEmpty ? infoFS : (fs.isEmpty ? content : fs),
                    "disk": parent,
                    "model": modelOf(parent),
                    "sizeGB": String(format: "%.1f", Double(p["Size"] as? Int ?? 0) / 1e9),
                    "mounted": !((p["MountPoint"] as? String) ?? "").isEmpty,
                    "active": active.contains(bsd),
                ])
            }
        }
        return out
    }

    // 显式接管选中分区. 已在服务且集合不同 → 先干净释放再起新 VM
    func takeover(_ parts: [String], reply: @escaping (String) -> Void) {
        DispatchQueue(label: "takeover").async {
            // 基本校验 (diskNsM 分区 或 diskN 整盘)
            let valid = parts.filter { $0.range(of: #"^disk\d+(s\d+)?$"#, options: .regularExpression) != nil }
            guard !valid.isEmpty, valid.count == parts.count else {
                reply("failed: 分区名不合法 \(parts)")
                return
            }
            self.lock.lock(); let current = self.activeParts; let busy = self.busy; self.lock.unlock()
            guard !busy else { reply("failed: 忙 (上一次操作进行中)"); return }
            if !current.isEmpty {
                if current == Set(parts) {
                    reply("ready (已在服务, 无变化)")
                    return
                }
                log("接管集合变更 \(current.sorted()) -> \(parts), 先干净释放")
                self.releaseInternal()
            }
            self.busy = true
            self.lock.lock()
            self.activeParts = Set(parts)
            self.parentDisks = Set(parts.map { self.parentDisk(of: $0) })
            self.lock.unlock()
            FileManager.default.createFile(atPath: Config.statePath, contents: "taking-over \(parts.joined(separator: ","))\n".data(using: .utf8))

            let q = QEMUManager(partitions: parts)
            // 共享名规则集中在 shareNameOf (与 listAvailable 下发的 "share" 同一来源)
            q.partLabels = Dictionary(uniqueKeysWithValues: parts.map { ($0, self.shareNameOf($0)) })
            self.qemu = q
            do {
                try q.start()
                if q.orchestrate() {
                    FileManager.default.createFile(atPath: Config.statePath, contents: "ready \(parts.joined(separator: ","))\n".data(using: .utf8))
                    reply("ready")
                } else {
                    q.forceTeardown()
                    self.clearActive()
                    FileManager.default.createFile(atPath: Config.statePath, contents: "failed\n".data(using: .utf8))
                    reply("failed: guest 未就绪")
                }
            } catch {
                log("接管失败: \(error.localizedDescription)")
                q.forceTeardown()
                self.clearActive()
                FileManager.default.createFile(atPath: Config.statePath, contents: "failed\n".data(using: .utf8))
                reply("failed: \(error.localizedDescription)")
            }
            self.busy = false
        }
    }

    private func clearActive() {
        qemu = nil
        lock.lock(); activeParts = []; parentDisks = []; lock.unlock()
    }

    private func remountToMacOS(_ parts: [String]) {
        for part in parts {
            // 整盘 (superfloppy) 同样尝试挂回: NTFS/exFAT 整盘 macOS 可只读挂载,
            // ext4 等 macOS 不认识的类型 mount 报错无害
            log("交还 macOS: diskutil mount /dev/\(part)")
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            t.arguments = ["mount", "/dev/\(part)"]
            t.standardOutput = FileHandle.nullDevice
            t.standardError = FileHandle.nullDevice
            try? t.run()
            t.waitUntilExit()
        }
    }

    // returnToMacOS=true 时, 释放后主动把分区挂回给 macOS (NTFS 为原生只读);
    // 接管集合变更的中间释放用 false, 避免刚挂上又卸的无谓抖动
    private func releaseInternal(returnToMacOS: Bool = false) {
        lock.lock(); let parts = activeParts.sorted(); lock.unlock()
        if let q = qemu, q.isRunning { q.shutdown() }
        clearActive()   // 先清空 activeParts 解除 veto, 再挂回
        if returnToMacOS { remountToMacOS(parts) }
        // 清理已卸载的空挂载点目录 (仍是活动挂载点的会删除失败, 无害)
        lock.lock(); let mps = createdMountpoints; lock.unlock()
        for mp in mps { try? FileManager.default.removeItem(atPath: mp) }
        lock.lock(); createdMountpoints.subtract(mps.filter { !FileManager.default.fileExists(atPath: $0) }); lock.unlock()
    }

    // 释放全部接管 (盘还在, 干净退出 VM, 分区挂回 macOS)
    func releaseAll(reply: @escaping (Bool) -> Void) {
        DispatchQueue(label: "release").async {
            self.releaseInternal(returnToMacOS: true)
            FileManager.default.createFile(atPath: Config.statePath, contents: "released\n".data(using: .utf8))
            reply(true)
        }
    }

    // 释放指定分区. 剩余集合非空时 VM 干净重启续上 (v1 不做 QMP 热拔:
    // guest umount 协调失败模式难看, 重启代价 ~15s SMB 中断, 零脏位风险)
    func release(_ parts: [String], reply: @escaping (String) -> Void) {
        DispatchQueue(label: "release").async {
            self.lock.lock(); let current = self.activeParts; let busy = self.busy; self.lock.unlock()
            guard !busy else { reply("failed: 忙 (上一次操作进行中)"); return }
            let valid = parts.filter { current.contains($0) }
            guard !valid.isEmpty, valid.count == parts.count else {
                reply("failed: 未接管 \(parts.filter { !current.contains($0) })")
                return
            }
            let remaining = current.subtracting(valid).sorted()
            if remaining.isEmpty {
                self.releaseInternal(returnToMacOS: true)
                FileManager.default.createFile(atPath: Config.statePath, contents: "released\n".data(using: .utf8))
                reply("released (全部)")
            } else {
                log("部分释放 \(valid), 剩余 \(remaining) 重启 VM")
                self.releaseInternal(returnToMacOS: false)
                self.remountToMacOS(valid.sorted())
                self.takeover(remaining) { s in
                    reply(s == "ready" ? "released \(valid.sorted().joined(separator: ",")), 剩余分区已重启续上" : "released \(valid.sorted().joined(separator: ",")), 但剩余分区重启失败: \(s)")
                }
            }
        }
    }

    // 守护进程退出时调用 (App 退出联动=交还 macOS; 系统关机 SIGTERM=不挂回)
    func shutdownAll(returnToMacOS: Bool = true) {
        releaseInternal(returnToMacOS: returnToMacOS)
    }

    func statusSummary() -> String {
        lock.lock(); let active = activeParts; lock.unlock()
        var s = "active=\(active.isEmpty ? "none" : active.sorted().joined(separator: ","))"
        if let q = qemu {
            s += " qemu=\(q.state)"
            if q.state == "ready" {
                do {
                    let qmp = QMPClient()
                    try qmp.connect(path: Config.qmpPath)
                    let r = try qmp.execute("query-status")
                    s += " qmp=\(r.trimmingCharacters(in: .whitespacesAndNewlines))"
                } catch {
                    s += " qmp=ERR(\(error.localizedDescription))"
                }
            }
        }
        return s
    }

    func trimNow() -> String {
        guard let q = qemu, q.state == "ready" else { return "无活动分区或未就绪" }
        let off = q.serial.length
        q.serial.send("for d in /mnt/*/; do fstrim \"$d\" 2>/dev/null | sed 's|^|TRIM-OK: |'; done; echo TRIM-DONE\n")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if q.serial.containsAfter("TRIM-DONE", offset: off) { return "fstrim 完成 (NTFS 由 -o discard 在线养护, exFAT/ext4 已 fstrim)" }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return "fstrim 超时"
    }

    // 按分区养护 (UI 每行的 🍃 按钮; NTFS 无此按钮 — discard 在线养护)
    // 参数为共享名 (guest 挂载点同名, 已 ASCII 化); 回传 fstrim 的真实输出防"假成功"
    func trimPartition(_ name: String) -> String {
        guard let q = qemu, q.state == "ready" else { return "无活动分区或未就绪" }
        let off = q.serial.length
        q.serial.send("fstrim /mnt/\(name) 2>&1 | sed 's|^|TRIM-PART: |'; echo TRIM-PART-DONE\n")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if q.serial.containsAfter("TRIM-PART-DONE", offset: off) {
                let out = q.serial.substringAfter(off)
                let detail = out.components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("TRIM-PART:") }
                    .last
                    .map { String($0.dropFirst(10)).trimmingCharacters(in: .whitespaces) } ?? ""
                return detail.isEmpty ? "已修剪 \(name)" : "\(name): \(detail)"
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return "fstrim 超时"
    }
    // MARK: - exFAT 原生养护 (不接管, 直发 DKIOCUNMAP)
    // 设计: exFAT macOS 原生可读写, 接管零收益; 养护 = 卸载 → 解析 allocation bitmap
    //       找空闲簇 → 逐段 DKIOCUNMAP → 挂回, 全程不经 VM
    // DKIOCUNMAP 的 Swift shim: 宏因 dk_unmap_t 含指针不被 Clang importer 导入,
    // 按内核稳定 ABI 手工展开 (C 侧打印核对 = 0x8010641F, 两个结构体均 16 字节)
    private struct DKExtent { var offset: UInt64; var length: UInt64 }
    private struct DKUnmap { var extents: UnsafeRawPointer?; var extentsCount: UInt32; var flags: UInt32 }
    private let DKIOCUNMAP_CMD: UInt = 0x80000000 | UInt(16 << 16) | UInt(0x64 << 8) | UInt(31)

    // 裸盘字符设备 pread 要求偏移/长度 512 对齐 (踩过: 不对齐直接 EINVAL)
    private func rawRead(_ fd: Int32, _ off: UInt64, _ len: Int) -> [UInt8]? {
        let sector = UInt64(512)
        let start = off / sector * sector
        let total = Int((off + UInt64(len) + sector - 1) / sector * sector - start)
        var buf = [UInt8](repeating: 0, count: total)
        guard pread(fd, &buf, total, off_t(start)) == total else { return nil }
        let s = Int(off - start)
        return Array(buf[s..<(s + len)])
    }

    private func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o+1]) << 8 | UInt32(b[o+2]) << 16 | UInt32(b[o+3]) << 24
    }
    private func le64(_ b: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(b, o)) | UInt64(le32(b, o+4)) << 32 }

    // exFAT 几何 + allocation bitmap 原文 (原生养护/深度检测共用)
    private struct ExfatGeom {
        let bitmap: [UInt8]
        let heapOff: UInt64
        let clustSize: UInt64
        let clustCount: UInt32
    }

    private func exfatBitmap(_ fd: Int32) -> ExfatGeom? {
        guard let vbr = rawRead(fd, 0, 512),
              String(decoding: vbr[3...10], as: UTF8.self) == "EXFAT   " else { return nil }
        let sectSize = UInt64(1) << vbr[108]
        let clustSize = sectSize << vbr[109]
        guard sectSize >= 512, sectSize <= 4096, clustSize >= sectSize, clustSize <= 32 << 20 else { return nil }
        let fatOff = UInt64(le32(vbr, 80)) * sectSize
        let fatLen = UInt64(le32(vbr, 84)) * sectSize
        let heapOff = UInt64(le32(vbr, 88)) * sectSize
        let clustCount = le32(vbr, 92)
        let rootClust = le32(vbr, 96)
        guard fatLen > 0, fatLen < 1 << 30, clustCount > 0, rootClust >= 2 else { return nil }
        guard let fat = rawRead(fd, fatOff, Int(fatLen)) else { return nil }
        // FAT 链跟踪 (EOC ≥ 0xFFFFFFF8; 0 = 未标记, 按连续分配兜底)
        func fatChain(_ start: UInt32, contiguousLen: UInt64?) -> [UInt32] {
            var out: [UInt32] = []
            var c = start
            while c >= 2 && c < 0xFFFFFFF8 {
                out.append(c)
                let n = le32(fat, Int(c) * 4)
                if n >= 2 && n < 0xFFFFFFF8 { c = n; continue }
                // FAT 未维护此链 (NoFatChain) → 按连续分配补齐到声明长度
                if let need = contiguousLen {
                    let total = Int((need + clustSize - 1) / clustSize)
                    while out.count < total { out.append(out.last! + 1) }
                }
                break
            }
            return out
        }
        func readClusters(_ start: UInt32, _ len: UInt64) -> [UInt8]? {
            var data = [UInt8]()
            for c in fatChain(start, contiguousLen: len) {
                guard let chunk = rawRead(fd, heapOff + UInt64(c - 2) * clustSize, Int(clustSize)) else { return nil }
                data += chunk
            }
            return data
        }
        // 根目录找 allocation bitmap 目录项 (类型 0x81)
        guard let rootDir = readClusters(rootClust, 0) else { return nil }
        var bmpCluster: UInt32 = 0, bmpLen: UInt64 = 0
        var off = 0
        while off + 32 <= rootDir.count {
            let t = rootDir[off]
            if t == 0 { break }
            if t == 0x81 {
                bmpCluster = le32(rootDir, off + 20)
                bmpLen = le64(rootDir, off + 24)
                break
            }
            off += 32
        }
        guard bmpCluster >= 2, bmpLen > 0, bmpLen < 1 << 28 else { return nil }
        guard let bitmap = readClusters(bmpCluster, bmpLen) else { return nil }
        return ExfatGeom(bitmap: bitmap, heapOff: heapOff, clustSize: clustSize, clustCount: clustCount)
    }

    // 解析 exFAT allocation bitmap → 空闲簇的字节区间段 (分区相对偏移, 512 对齐天然满足)
    private func exfatFreeRuns(_ fd: Int32) -> [(UInt64, UInt64)]? {
        guard let g = exfatBitmap(fd) else { return nil }
        // 位图: bit i (字节内 LSB 优先) 对应簇 i+2, 0=空闲
        var runs: [(UInt64, UInt64)] = []
        var runStart: UInt64? = nil
        for i in 0..<Int(g.clustCount) {
            let free = g.bitmap[i / 8] & (1 << (i % 8)) == 0
            if free && runStart == nil { runStart = UInt64(i) }
            if !free, let s = runStart {
                runs.append((g.heapOff + s * g.clustSize, (UInt64(i) - s) * g.clustSize))
                runStart = nil
            }
        }
        if let s = runStart {
            runs.append((g.heapOff + s * g.clustSize, (UInt64(g.clustCount) - s) * g.clustSize))
        }
        return runs
    }

    // guest 串口控制台末尾 N 行 (anyfsctl console 诊断用)
    func consoleTail() -> String {
        guard let q = qemu else { return "(无活动 VM)" }
        return q.serial.tail(60)
    }

    // 向 guest 控制台注入一行命令 (anyfsctl inject; 与启动注入同路径, 免 sudo)
    func inject(_ cmd: String) -> Bool {
        guard let q = qemu, q.state == "ready" else { return false }
        q.serial.send(cmd + "\n")
        return true
    }

    // exFAT 原生养护入口 (XPC): 卸载 → UNMAP 全部空闲段 → 挂回
    func trimNative(_ bsd: String, reply: @escaping (String) -> Void) {
        DispatchQueue(label: "trim-native").async {
            // 失败也要留痕 (教训: 只回传 UI 不写日志 → 事后无法排查)
            func fail(_ s: String) { log("exFAT 原生养护 \(bsd) 失败: \(s)"); reply("failed: \(s)") }
            self.lock.lock()
            let busy = self.busy, active = self.activeParts.contains(bsd)
            self.lock.unlock()
            guard !busy else { reply("failed: 忙 (上一次操作进行中)"); return }
            guard !active else { fail("已由 anyFS 接管, 用 guest 内养护"); return }
            guard bsd.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil else {
                fail("分区名不合法"); return
            }
            self.busy = true
            defer { self.busy = false }

            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            t.arguments = ["unmount", "force", "/dev/\(bsd)"]
            t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
            try? t.run(); t.waitUntilExit()
            // 结束或失败路径都挂回 macOS (defer 保证)
            defer {
                let m = Process()
                m.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                m.arguments = ["mount", "/dev/\(bsd)"]
                m.standardOutput = FileHandle.nullDevice; m.standardError = FileHandle.nullDevice
                try? m.run(); m.waitUntilExit()
            }

            let fd = open("/dev/r\(bsd)", O_RDWR)
            guard fd >= 0 else { fail("打开裸设备失败 (errno=\(errno))"); return }
            defer { close(fd) }
            guard let runs = self.exfatFreeRuns(fd) else {
                fail("不是可识别的 exFAT 分区或元数据损坏"); return
            }
            guard !runs.isEmpty else { reply("无空闲空间可养护"); return }
            var done: UInt64 = 0, failedSegs = 0
            var i = 0
            while i < runs.count {
                let batch = Array(runs[i..<min(i + 256, runs.count)])
                var exts = batch.map { DKExtent(offset: $0.0, length: $0.1) }
                let rc = exts.withUnsafeMutableBufferPointer { bp -> Int32 in
                    var um = DKUnmap(extents: UnsafeRawPointer(bp.baseAddress),
                                     extentsCount: UInt32(batch.count), flags: 0)
                    return ioctl(fd, self.DKIOCUNMAP_CMD, &um)
                }
                if rc != 0 {
                    failedSegs += batch.count
                    if i == 0 {
                        fail("DKIOCUNMAP 被内核/桥拒绝 (errno=\(errno) \(String(cString: strerror(errno)))) — 该桥可能不支持 UNMAP")
                        return
                    }
                } else {
                    done += batch.reduce(UInt64(0)) { $0 + $1.1 }
                }
                i += 256
            }
            log("exFAT 原生养护 \(bsd): \(done / 1_000_000)MB, \(runs.count) 段, 失败 \(failedSegs)")
            reply(failedSegs == 0
                  ? "已养护 \(String(format: "%.1f", Double(done) / 1e9))GB (\(runs.count) 段空闲区)"
                  : "部分失败: \(failedSegs)/\(runs.count) 段被拒")
        }
    }

    // MARK: - TRIM 深度检测 (金标准产品化, 2026-11-11 终案后落地)
    // 判读逻辑见 ntfs-bridge-app-plan.md "排障终案": TRIM 全链路秒级,
    // 检测只需 ~13s; 图案必须 guest 本地生成, 经 SMB 写入会触发
    // macOS smbfs 客户端 deferred close → smbd 持 fd → evict 迟延 16~53s 假象

    // 串口标记等待 (trimNow 同款模式)
    private func waitSerial(_ q: QEMUManager, _ needle: String, _ off: Int, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if q.serial.containsAfter(needle, offset: off) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    // filefrag -e -v 输出 → 首个 ≥1MB 连续 extent 的分区相对字节偏移
    // 行格式: "   0:        0..   65535:  6191072.. 6256607:  65536:  ... flags"
    // 固定列位 toks[3]=physlo("N..") toks[5]=len("N:") (expected 列在 len 之后, 不挪位)
    private func parseFilefrag(_ text: String) -> UInt64? {
        var bs: UInt64 = 0
        for line in text.components(separatedBy: .newlines) {
            if let m = line.range(of: #"blocks of (\d+) bytes"#, options: .regularExpression) {
                bs = UInt64(line[m].split(separator: " ")[2]) ?? 0
                break
            }
        }
        guard bs > 0 else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard toks.count >= 6, toks[0].hasSuffix(":"), toks[1].contains(".."),
                  toks[3].contains("..") else { continue }
            guard let phys = UInt64(toks[3].replacingOccurrences(of: "..", with: "")),
                  let len = UInt64(toks[5].replacingOccurrences(of: ":", with: "")),
                  len * bs >= 1_048_576 else { continue }
            return phys * bs
        }
        return nil
    }

    // 宿主 F_NOCACHE 读 1MB 统计 0x00/0x5A 个数 (off 必须 512 对齐 — FIEMAP 输出天然满足)
    // 教训: 不经 F_NOCACHE 会命中 macOS 缓冲区里的旧图案 → 假阴性 (2026-11-10)
    private func hostVerify(_ fd: Int32, _ off: UInt64) -> (zero: Int, pattern: Int) {
        var buf = [UInt8](repeating: 0, count: 1_048_576)
        guard pread(fd, &buf, buf.count, off_t(off)) == buf.count else { return (-1, -1) }
        var z = 0, p = 0
        for b in buf { if b == 0 { z += 1 } else if b == 0x5A { p += 1 } }
        return (z, p)
    }

    // guest 路径深度检测 (XPC; 接管的分区): dd 埋图案 → filefrag 定位 →
    // 预校验 → rm 触发在线 discard → F_NOCACHE 轮询读回判决, ~13s
    func deepTrim(_ bsd: String, reply: @escaping (String) -> Void) {
        DispatchQueue(label: "deep-trim").async {
            func fail(_ s: String) { log("深度检测 \(bsd) 失败: \(s)"); reply("failed: \(s)") }
            guard let q = self.qemu, q.state == "ready" else { fail("无活动 VM 或未就绪"); return }
            self.lock.lock(); let active = self.activeParts.contains(bsd); self.lock.unlock()
            guard active else { fail("\(bsd) 未由 anyFS 接管"); return }
            // 挂载点按 target(=直通序号) 在 guest 内解析, 不碰卷标 —
            // SCSI 异步探测字母会交换, 且多块盘可能同卷标 (2026-11-11 实踩)
            guard let idx = q.partitions.firstIndex(of: bsd) else { fail("\(bsd) 不在直通列表"); return }
            let offM = q.serial.length
            q.serial.send("MP=; for d in /dev/sd?; do case \"$(readlink /sys/block/${d#/dev/})\" in *target*:0:\(idx)/*) MP=$(grep \"^$d \" /proc/mounts | cut -d' ' -f2);; esac; done; echo DT-MP\"\"=$MP\n")
            guard self.waitSerial(q, "DT-MP=", offM, 15) else { fail("挂载点解析超时"); return }
            let mpSeg = q.serial.substringAfter(offM)
            guard let mp = mpSeg.components(separatedBy: .newlines)
                    .last(where: { $0.hasPrefix("DT-MP=") })
                    .map({ String($0.dropFirst(6)) }), !mp.isEmpty else {
                fail("guest 未找到 target\(idx) 设备的挂载点"); return
            }
            let pat = "\(mp)/.anyfs-deep-pattern"
            let cleanup = { q.serial.send("rm -f \(pat)\n") }

            // ① 埋图案: guest 本地 dd|tr (不经 SMB! 否则 macOS 客户端句柄缓存致假延迟)
            let off0 = q.serial.length
            q.serial.send("dd if=/dev/zero bs=1M count=32 2>/dev/null | tr \"\\000\" \"\\132\" > \(pat); sync; echo DT-PLAN\"\"TED\n")
            guard self.waitSerial(q, "DT-PLANTED", off0, 20) else { fail("埋图案超时"); return }

            // ② FIEMAP 定位 (文件系统无关)
            let off1 = q.serial.length
            q.serial.send("/opt/usr/sbin/filefrag -e -v \(pat); echo DT-LOCA\"\"TED\n")
            guard self.waitSerial(q, "DT-LOCATED", off1, 15) else { cleanup(); fail("定位超时"); return }
            guard let poff = self.parseFilefrag(q.serial.substringAfter(off1)) else {
                cleanup(); fail("filefrag 解析失败 (extent 不足 1MB?)"); return
            }

            // ③ 宿主预校验: 图案确实落在介质上
            let fd = open("/dev/r\(bsd)", O_RDONLY)
            guard fd >= 0 else { cleanup(); fail("打开裸设备失败 (errno=\(errno))"); return }
            fcntl(fd, F_NOCACHE, 1)
            let (_, p0) = self.hostVerify(fd, poff)
            guard p0 > 1_038_000 else {
                close(fd); cleanup(); fail("预校验: 目标区非全图案 (未落盘?)"); return
            }

            // ④ guest 删除 (在线 discard 立即触发)
            let t0 = Date()
            let off2 = q.serial.length
            q.serial.send("rm -f \(pat); sync; echo DT-DELE\"\"TED\n")
            guard self.waitSerial(q, "DT-DELETED", off2, 15) else {
                close(fd); fail("删除超时"); return
            }

            // ⑤ F_NOCACHE 轮询读回判决 (2s×8; 正常 T+0~4s 全零)
            var ok = false
            for i in 0..<9 {
                if i > 0 { Thread.sleep(forTimeInterval: 2) }
                let (z, _) = self.hostVerify(fd, poff)
                if z == 1_048_576 { ok = true; break }
            }
            close(fd)
            let dt = Int(Date().timeIntervalSince(t0))
            if ok {
                log("深度检测 \(bsd): 通过 (\(dt)s 归零)")
                reply("✅ TRIM 通路正常 — 删除后 \(dt)s 物理归零")
            } else {
                fail("16s 未归零 — TRIM 未生效或被吞")
            }
        }
    }

    // MARK: exFAT 原生深度检测 (免接管, 三阶段; 图案文件由 App/CLI 经原生挂载写删)
    // 流程对齐 spike/native-deep-trim.sh: begin(位图A) → [App 写图案+sync] →
    // locate(位图B+diff+预校验, 返回 OFF) → [App 删图案+sync] → execute(卸载→定向UNMAP→读回)
    private var nativeSnap: [String: ExfatGeom] = [:]

    private func openRaw(_ bsd: String, _ flags: Int32) -> Int32? {
        guard bsd.range(of: #"^disk\d+(s\d+)?$"#, options: .regularExpression) != nil else { return nil }
        let fd = open("/dev/r\(bsd)", flags)
        if fd >= 0 { fcntl(fd, F_NOCACHE, 1) }
        return fd >= 0 ? fd : nil
    }

    func deepTrimNativeBegin(_ bsd: String, reply: @escaping (String) -> Void) {
        DispatchQueue(label: "deep-native").async {
            guard let fd = self.openRaw(bsd, O_RDONLY) else {
                reply("failed: 分区名不合法或裸设备打不开 (errno=\(errno))"); return
            }
            defer { close(fd) }
            guard let g = self.exfatBitmap(fd) else {
                reply("failed: 不是可识别的 exFAT 分区"); return
            }
            self.nativeSnap[bsd] = g
            reply("ok")
        }
    }

    func deepTrimNativeLocate(_ bsd: String, reply: @escaping (String) -> Void) {
        DispatchQueue(label: "deep-native").async {
            func fail(_ s: String) { log("原生深度检测 \(bsd) 失败: \(s)"); reply("failed: \(s)") }
            guard let a = self.nativeSnap[bsd] else { fail("未先 begin"); return }
            guard let fd = self.openRaw(bsd, O_RDONLY) else { fail("裸设备打不开"); return }
            defer { close(fd) }
            guard let b = self.exfatBitmap(fd) else { fail("位图 B 读取失败"); return }
            // 位 0→1 = 新分配簇 (即图案文件), 取最长 ≥1MB 段
            var runs: [(UInt64, UInt64)] = []
            var start: Int? = nil
            for i in 0..<Int(b.clustCount) {
                let newly = (b.bitmap[i / 8] >> (i % 8)) & 1 == 1 && (a.bitmap[i / 8] >> (i % 8)) & 1 == 0
                if newly && start == nil { start = i }
                if !newly, let s = start {
                    runs.append((b.heapOff + UInt64(s) * b.clustSize, UInt64(i - s) * b.clustSize))
                    start = nil
                }
            }
            if let s = start {
                runs.append((b.heapOff + UInt64(s) * b.clustSize, UInt64(Int(b.clustCount) - s) * b.clustSize))
            }
            guard let best = runs.filter({ $0.1 >= 1_048_576 }).max(by: { $0.1 < $1.1 }) else {
                fail("位图差分无 ≥1MB 新分配段 (图案未落盘?)"); return
            }
            let (_, p) = self.hostVerify(fd, best.0)
            guard p > 1_038_000 else { fail("预校验: 目标区非全图案 (diff 错位?)"); return }
            reply("OFF=\(best.0)")
        }
    }

    func deepTrimNativeExecute(_ bsd: String, offset: UInt64, reply: @escaping (String) -> Void) {
        DispatchQueue(label: "deep-native").async {
            func fail(_ s: String) { log("原生深度检测 \(bsd) 失败: \(s)"); reply("failed: \(s)") }
            defer { self.nativeSnap.removeValue(forKey: bsd) }
            self.lock.lock(); let busy = self.busy; self.lock.unlock()
            guard !busy else { fail("忙 (上一次操作进行中)"); return }
            self.busy = true
            defer { self.busy = false }
            // 卸载 (定向 UNMAP 需要; defer 保证挂回)
            let t = Process()
            t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            t.arguments = ["unmount", "force", "/dev/\(bsd)"]
            t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
            try? t.run(); t.waitUntilExit()
            defer {
                let m = Process()
                m.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
                m.arguments = ["mount", "/dev/\(bsd)"]
                m.standardOutput = FileHandle.nullDevice; m.standardError = FileHandle.nullDevice
                try? m.run(); m.waitUntilExit()
            }
            guard let fd = self.openRaw(bsd, O_RDWR) else { fail("裸设备打不开"); return }
            defer { close(fd) }
            // 安全闸 (unmap-live 同款): 目标区必须 >99% 0x5A 才动手
            let (_, p) = self.hostVerify(fd, offset)
            guard p > 1_038_000 else { fail("安全闸: 目标区非全图案, 拒绝 UNMAP"); return }
            var ext = DKExtent(offset: offset, length: 1_048_576)
            let rc = withUnsafeMutablePointer(to: &ext) { ep -> Int32 in
                var um = DKUnmap(extents: UnsafeRawPointer(ep), extentsCount: 1, flags: 0)
                return ioctl(fd, self.DKIOCUNMAP_CMD, &um)
            }
            guard rc == 0 else {
                fail("DKIOCUNMAP 被拒 (errno=\(errno) \(String(cString: strerror(errno)))) — 桥可能不支持 UNMAP"); return
            }
            let (z, _) = self.hostVerify(fd, offset)
            if z == 1_048_576 {
                log("原生深度检测 \(bsd): 通过")
                reply("✅ TRIM 通路正常 — 原生 DKIOCUNMAP 读回全零")
            } else {
                fail("UNMAP 已受理但读回非零 — 桥疑似吞 TRIM")
            }
        }
    }

    // TRIM 通道灯 (XPC): QMP query-blockstats 汇总 usbdisk* 的 unmap 计数
    private func qmpUnmapOps() -> (ops: UInt64, failed: UInt64)? {
        guard qemu?.state == "ready" else { return nil }
        do {
            let qmp = QMPClient()
            try qmp.connect(path: Config.qmpPath)
            let resp = try qmp.execute("query-blockstats")
            guard let data = resp.data(using: .utf8),
                  let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = j["return"] as? [[String: Any]] else { return nil }
            var ops: UInt64 = 0, failed: UInt64 = 0
            for e in arr {
                guard let dev = e["device"] as? String, dev.hasPrefix("usbdisk"),
                      let st = e["stats"] as? [String: Any] else { continue }
                ops += (st["unmap_operations"] as? NSNumber)?.uint64Value ?? 0
                failed += (st["failed_unmap_operations"] as? NSNumber)?.uint64Value ?? 0
            }
            return (ops, failed)
        } catch { return nil }
    }

    // 通道灯文案: ✅ 有流量 / ❌ 有被拒 / ● 未观察 (无流量或无 VM)
    func trimStats() -> String {
        guard let r = qmpUnmapOps() else { return "inactive" }
        return "ops=\(r.ops) failed=\(r.failed)"
    }
}

// MARK: - XPC 服务
@objc(AnyFSDaemonProtocol) protocol AnyFSDaemonProtocol {
    func status(withReply reply: @escaping (NSString) -> Void)
    func listAvailable(withReply reply: @escaping (NSArray) -> Void)
    func takeover(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void)
    func release(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void)
    func prepareMountpoint(_ name: NSString, withReply reply: @escaping (NSString) -> Void)
    func releaseAll(withReply reply: @escaping (NSNumber) -> Void)
    func trimNow(withReply reply: @escaping (NSString) -> Void)
    func trimPartition(_ label: NSString, withReply reply: @escaping (NSString) -> Void)
    func trimNative(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrim(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeBegin(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeLocate(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeExecute(_ bsd: NSString, offset: NSNumber, withReply reply: @escaping (NSString) -> Void)
    func trimStats(withReply reply: @escaping (NSString) -> Void)
    func consoleTail(withReply reply: @escaping (NSString) -> Void)
    func inject(_ cmd: NSString, withReply reply: @escaping (NSNumber) -> Void)
    func shareName(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func appQuit(withReply reply: @escaping (NSNumber) -> Void)
}

final class XPCService: NSObject, AnyFSDaemonProtocol, NSXPCListenerDelegate {
    func start() {
        let l = NSXPCListener(machServiceName: Config.xpcName)
        l.delegate = self
        l.resume()
        log("XPC 服务已监听 \(Config.xpcName)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: AnyFSDaemonProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    func status(withReply reply: @escaping (NSString) -> Void) {
        reply(DiskManager.shared.statusSummary() as NSString)
    }
    func listAvailable(withReply reply: @escaping (NSArray) -> Void) {
        reply(DiskManager.shared.listAvailable().map { $0 as NSDictionary } as NSArray)
    }
    func takeover(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void) {
        let parts = partitions.compactMap { $0 as? String }
        DiskManager.shared.takeover(parts) { s in reply(s as NSString) }
    }
    func release(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void) {
        let parts = partitions.compactMap { $0 as? String }
        DiskManager.shared.release(parts) { s in reply(s as NSString) }
    }
    func prepareMountpoint(_ name: NSString, withReply reply: @escaping (NSString) -> Void) {
        reply(DiskManager.shared.prepareMountpoint(name as String) as NSString)
    }
    func releaseAll(withReply reply: @escaping (NSNumber) -> Void) {
        DiskManager.shared.releaseAll { ok in reply(NSNumber(value: ok)) }
    }
    func trimNow(withReply reply: @escaping (NSString) -> Void) {
        DispatchQueue(label: "xpc-trim").async {
            reply(DiskManager.shared.trimNow() as NSString)
        }
    }
    func trimPartition(_ label: NSString, withReply reply: @escaping (NSString) -> Void) {
        DispatchQueue(label: "xpc-trim-part").async {
            reply(DiskManager.shared.trimPartition(label as String) as NSString)
        }
    }
    // exFAT 原生养护 (卸载→DKIOCUNMAP→挂回, 不经 VM)
    func trimNative(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void) {
        DiskManager.shared.trimNative(bsd as String) { s in reply(s as NSString) }
    }
    // TRIM 深度检测: guest 路径 (接管的分区, ~13s 物理判决)
    func deepTrim(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void) {
        DiskManager.shared.deepTrim(bsd as String) { s in reply(s as NSString) }
    }
    // exFAT 原生深度检测三阶段 (图案文件由 App/CLI 经原生挂载写删)
    func deepTrimNativeBegin(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void) {
        DiskManager.shared.deepTrimNativeBegin(bsd as String) { s in reply(s as NSString) }
    }
    func deepTrimNativeLocate(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void) {
        DiskManager.shared.deepTrimNativeLocate(bsd as String) { s in reply(s as NSString) }
    }
    func deepTrimNativeExecute(_ bsd: NSString, offset: NSNumber, withReply reply: @escaping (NSString) -> Void) {
        DiskManager.shared.deepTrimNativeExecute(bsd as String, offset: offset.uint64Value) { s in reply(s as NSString) }
    }
    // TRIM 通道灯: QMP unmap_ops 汇总 (✅流量/❌被拒/●未观察; 受理≠执行, 物理判决看深度检测)
    func trimStats(withReply reply: @escaping (NSString) -> Void) {
        DispatchQueue(label: "xpc-trimstats").async {
            reply(DiskManager.shared.trimStats() as NSString)
        }
    }
    // guest 串口控制台末尾输出 (诊断: 控制台是否掉回登录态/卡死, 一眼定位)
    func consoleTail(withReply reply: @escaping (NSString) -> Void) {
        let tail = DiskManager.shared.consoleTail()
        reply(tail as NSString)
    }
    // 串口注入 (诊断/脚本用; 与启动注入同路径, 免 sudo)
    func inject(_ cmd: NSString, withReply reply: @escaping (NSNumber) -> Void) {
        reply(NSNumber(value: DiskManager.shared.inject(cmd as String)))
    }
    // 分区的 guest 共享名/挂载点名 (脚本用: 卷标大小写敏感, 不能靠猜)
    func shareName(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void) {
        reply(DiskManager.shared.shareNameOf(bsd as String) as NSString)
    }
    // App 退出联动: 干净收尸完成后才回话 (App 端显示"正在关闭…"等待), 然后 daemon 自毁
    func appQuit(withReply reply: @escaping (NSNumber) -> Void) {
        DispatchQueue(label: "xpc-quit").async {
            log("App 退出联动: 干净收尸后 daemon 自毁")
            DiskManager.shared.shutdownAll()
            reply(true)
            // 留时间让 XPC 回话送达再退出
            DispatchQueue(label: "xpc-exit").asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
}

// MARK: - main
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termSrc.setEventHandler {
    log("收到 SIGTERM, 开始干净退出")
    DiskManager.shared.shutdownAll(returnToMacOS: false)
    exit(0)
}
termSrc.resume()
let intSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
intSrc.setEventHandler {
    log("收到 SIGINT, 开始干净退出")
    DiskManager.shared.shutdownAll(returnToMacOS: false)
    exit(0)
}
intSrc.resume()

log("anyfsd 启动 (S5.1 分区级直通)")
Config.loadOverrides()
DiskManager.shared.start()
let xpcService = XPCService()
xpcService.start()
log("anyfsd 常驻运行中 (按需启动, 等待 XPC 指令)")
RunLoop.main.run()
