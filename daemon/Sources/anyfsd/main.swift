// anyfsd — anyFS privileged daemon (S5.1: 分区级直通 + 显式接管)
// 职责: 枚举外接盘分区 → 按 App/XPC 指令接管选中分区(启VM) → 释放/退出时干净收尸
// 运行方式: root (launchd, /Library/LaunchDaemons/com.anyfs.daemon.plist)
// 设计: 不再自动接管 (DA 只用于枚举刷新和拔盘保护); 接管粒度=分区 (/dev/rdiskXsY);
//       单 VM 挂多个分区设备; 同盘未选中的分区 (如 APFS) 留给 macOS 原生使用
import Foundation
import DiskArbitration
import SystemConfiguration   // SCDynamicStoreCopyConsoleUser: 取当前登录用户 uid

// MARK: - 配置 (打包形态: /usr/local/etc/anyfsd.conf 覆盖 dev 默认路径)
struct Config {
    static let confPath    = "/usr/local/etc/anyfsd.conf"
    static let spikeDir    = "/Users/jack/anyfs/spike"
    static var qemu        = "\(spikeDir)/qemu-11.1.2/build/qemu-system-x86_64"
    static var kernel      = "\(spikeDir)/alpine/vmlinuz-virt"
    static var initrd      = "\(spikeDir)/alpine/initramfs-virt"
    static var iso         = "\(spikeDir)/alpine/alpine-virt.iso"
    static var bundle      = "\(spikeDir)/bundle/bundle.img"
    static let guestMemMB  = 128
    static let guestSMP    = 2
    static let serialBase  = "/tmp/anyfsd-serial"
    static let qmpPath     = "/tmp/anyfsd.qmp"
    static let xpcName     = "com.anyfs.daemon"
    static let logPath     = "/var/log/anyfsd.log"
    static let statePath   = "/tmp/anyfsd.state"
    // 可接管的文件系统 (diskutil list -plist 的字段值)
    static let supportedFSTypes: Set<String> = ["ntfs","exfat","msdos","vfat","ext4","ext3","ext2"]
    static let supportedContent: Set<String> = ["Microsoft Basic Data","Basic Data","Linux","Linux Filesystem"]

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
    private var process: Process?
    private(set) var state = "stopped"
    let serial = SerialPipe(base: Config.serialBase)
    private var stderrBuf = ""

    init(partitions: [String]) { self.partitions = partitions }

    // 只卸选中的分区 (不可用 unmountDisk 整盘 — 会波及留给 macOS 的 APFS 等分区)
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
            var args = [
                "-machine", "q35,accel=hvf",
                "-cpu", "host", "-smp", "\(Config.guestSMP)", "-m", "\(Config.guestMemMB)",
                "-kernel", Config.kernel,
                "-initrd", Config.initrd,
                "-append", "console=ttyS0",
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
            log("QEMU 已启动 pid=\(p.processIdentifier) (第\(attempt)次) 分区=\(partitions.joined(separator: ","))")
            Thread.sleep(forTimeInterval: 3)
            if p.isRunning {
                process = p
                state = "running"
                return
            }
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
        serial.send("ip link set eth0 up && udhcpc -i eth0 -q\n")
        Thread.sleep(forTimeInterval: 2)
        serial.send("mount -t ext2 -o ro /dev/vdb /opt\n")
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
        log("干净退出: 通知 guest umount + poweroff ...")
        serial.send("sync; for d in /mnt/*/; do umount \"$d\" 2>/dev/null; done\n")
        Thread.sleep(forTimeInterval: 2)
        serial.send("poweroff\n")
        let deadline = Date().addingTimeInterval(graceSeconds)
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

    private func wholeUSBDiskBSD(_ disk: DADisk) -> String? {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any],
              let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String,
              (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true,
              (desc[kDADiskDescriptionDeviceProtocolKey as String] as? String) == "USB"
        else { return nil }
        return bsd
    }

    // disk3s3 → disk3 (用于判断拔出事件是否波及已接管分区)
    private func parentDisk(of part: String) -> String {
        if let r = part.range(of: #"s\d+$"#, options: .regularExpression) {
            return String(part[..<r.lowerBound])
        }
        return part
    }

    private func onAppear(_ disk: DADisk) {
        guard let bsd = wholeUSBDiskBSD(disk) else { return }
        log("DiskArb: 外接盘插入 \(bsd) (等待 App 指令, 不自动接管)")
    }

    private func onDisappear(_ disk: DADisk) {
        guard let bsd = wholeUSBDiskBSD(disk) else { return }
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

    // diskutil list -plist 不填 FilesystemType, 用 info 补全 (ntfs/exfat/msdos/ext*)
    private func fsTypeOf(_ bsd: String) -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        t.arguments = ["info", "-plist", bsd]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return "" }
        return (obj["FilesystemName"] as? String) ?? (obj["FilesystemType"] as? String) ?? ""
    }

    // 整盘型号 (UI 分组标题): MediaName, 如 "RTL9210B-CG"
    private func modelOf(_ wholeBsd: String) -> String {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        t.arguments = ["info", "-plist", wholeBsd]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return wholeBsd }
        return (obj["MediaName"] as? String) ?? wholeBsd
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
            guard let parts = d["Partitions"] as? [[String: Any]] else { continue }
            for p in parts {
                guard let bsd = p["DeviceIdentifier"] as? String else { continue }
                let fs = (p["FilesystemType"] as? String ?? "").lowercased()
                let content = p["Content"] as? String ?? ""
                guard Config.supportedFSTypes.contains(fs) || Config.supportedContent.contains(content) else { continue }
                let volName = (p["VolumeName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let infoFS = fsTypeOf(bsd)
                let parent = parentDisk(of: bsd)
                out.append([
                    "bsd": bsd,
                    "label": volName ?? (p["FilesystemName"] as? String) ?? bsd,
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
            // 基本校验
            let valid = parts.filter { $0.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil }
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
    func trimPartition(_ label: String) -> String {
        guard let q = qemu, q.state == "ready" else { return "无活动分区或未就绪" }
        let name = label.replacingOccurrences(of: " ", with: "_")
        let off = q.serial.length
        q.serial.send("fstrim /mnt/\(name) 2>&1 | sed 's|^|TRIM-PART: |'; echo TRIM-PART-DONE\n")
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if q.serial.containsAfter("TRIM-PART-DONE", offset: off) { return "已修剪 \(label)" }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return "fstrim 超时"
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
