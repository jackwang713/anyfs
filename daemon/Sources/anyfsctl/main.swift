// anyfsctl — anyfsd 的命令行测试客户端 (XPC)
// 用法: anyfsctl status | list | takeover <分区...> | release [分区...] | trim | quit
//       release 不带参数=全部释放; 带参数=释放指定分区, 剩余集合重启 VM 续上
import Foundation

@objc(AnyFSDaemonProtocol) protocol AnyFSDaemonProtocol {
    func status(withReply reply: @escaping (NSString) -> Void)
    func listAvailable(withReply reply: @escaping (NSArray) -> Void)
    func takeover(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void)
    func release(_ partitions: NSArray, withReply reply: @escaping (NSString) -> Void)
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

let cmd = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "status"

let conn = NSXPCConnection(machServiceName: "com.anyfs.daemon", options: .privileged)
conn.remoteObjectInterface = NSXPCInterface(with: AnyFSDaemonProtocol.self)
conn.resume()

guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
    FileHandle.standardError.write("XPC 错误: \(err.localizedDescription)\n".data(using: .utf8)!)
}) as? AnyFSDaemonProtocol else {
    FileHandle.standardError.write("无法获取 XPC 代理\n".data(using: .utf8)!)
    exit(1)
}

let sem = DispatchSemaphore(value: 0)
switch cmd {
case "status":
    proxy.status { s in print("status: \(s)"); sem.signal() }
case "list":
    proxy.listAvailable { arr in
        if arr.count == 0 { print("(无可接管分区: 未插入外接盘或无 NTFS/exFAT/ext* 分区)") }
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            let active = (d["active"] as? Bool) == true
            let mounted = (d["mounted"] as? Bool) == true
            let state = active ? "anyFS接管中" : (mounted ? "macOS挂载" : "空闲")
            let mark = active ? "*" : " "
            print("\(mark) \(d["bsd"] ?? "?")  \(d["label"] ?? "?")  \(d["fs"] ?? "?")  \(d["sizeGB"] ?? "?")GB  \(state)")
        }
        sem.signal()
    }
case "takeover":
    let parts = Array(CommandLine.arguments.dropFirst(2))
    guard !parts.isEmpty else {
        print("用法: anyfsctl takeover disk3s3 [disk3s4 ...]")
        exit(2)
    }
    print("接管 \(parts.joined(separator: ", ")) (约10-20秒)...")
    proxy.takeover(parts as NSArray) { s in print("takeover: \(s)"); sem.signal() }
case "release":
    let parts = Array(CommandLine.arguments.dropFirst(2))
    if parts.isEmpty {
        proxy.releaseAll { ok in print("release: \(ok.boolValue ? "已释放 (VM 干净退出)" : "失败")"); sem.signal() }
    } else {
        print("释放 \(parts.joined(separator: ", ")) (剩余分区将重启 VM, 约15-25秒)...")
        proxy.release(parts as NSArray) { s in print("release: \(s)"); sem.signal() }
    }
case "trim":
    if CommandLine.arguments.count > 2 {
        let name = CommandLine.arguments[2]
        print("fstrim /mnt/\(name) (按分区养护)...")
        proxy.trimPartition(name as NSString) { s in print("trim: \(s)"); sem.signal() }
    } else {
        print("fstrim 执行中 (全部已挂载分区, 可能需数秒~数分钟)...")
        proxy.trimNow { s in print("trim: \(s)"); sem.signal() }
    }
case "console":
    // guest 串口控制台末尾 60 行 (诊断控制台活性/卡死)
    proxy.consoleTail { s in print(s as String); sem.signal() }
case "inject":
    // 向 guest 控制台注入一行命令 (走 daemon 同路径, 免 sudo)
    let cmdline = CommandLine.arguments.dropFirst(2).joined(separator: " ")
    guard !cmdline.isEmpty else { print("用法: anyfsctl inject <命令>"); exit(2) }
    proxy.inject(cmdline as NSString) { ok in
        print(ok.boolValue ? "inject: 已注入" : "inject: 失败 (无就绪 VM)")
        sem.signal()
    }
case "share":
    // 分区的 guest 共享名 (含真实大小写, 脚本定位 guest 挂载点用)
    guard CommandLine.arguments.count > 2 else { print("用法: anyfsctl share <分区>"); exit(2) }
    proxy.shareName(CommandLine.arguments[2] as NSString) { s in print(s); sem.signal() }
case "deeptrim":
    // TRIM 深度检测 (guest 路径; 分区须已接管; ~13s 物理判决)
    guard CommandLine.arguments.count > 2 else { print("用法: anyfsctl deeptrim <分区>"); exit(2) }
    print("深度检测 \(CommandLine.arguments[2]) (guest 链路, ~13s)...")
    proxy.deepTrim(CommandLine.arguments[2] as NSString) { s in print("deeptrim: \(s)"); sem.signal() }
case "deeptrimnative":
    // exFAT 原生深度检测 (免接管; 图案由本 CLI 经原生挂载写删, ~5s)
    guard CommandLine.arguments.count > 2 else { print("用法: anyfsctl deeptrimnative <分区>"); exit(2) }
    let bsd = CommandLine.arguments[2]
    // 找原生挂载点 (必须已由 macOS 挂载)
    let mt = Process(); mt.executableURL = URL(fileURLWithPath: "/sbin/mount")
    let mp = Pipe(); mt.standardOutput = mp
    try? mt.run(); mt.waitUntilExit()
    let mout = String(data: mp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let mline = mout.split(separator: "\n").first(where: { $0.hasPrefix("/dev/\(bsd) on ") }),
          let r = mline.range(of: " on "), let r2 = mline.range(of: " (", range: r.upperBound..<mline.endIndex) else {
        print("deeptrimnative: \(bsd) 未被 macOS 原生挂载"); exit(1)
    }
    let mnt = String(mline[r.upperBound..<r2.lowerBound])
    let probe = "\(mnt)/.anyfs-trim-probe"
    print("深度检测 \(bsd) (原生链路)...")
    proxy.deepTrimNativeBegin(bsd as NSString) { s in
        guard (s as String) == "ok" else { print("begin: \(s)"); sem.signal(); return }
        // 经原生挂载埋 32MB 0x5A 图案 + 落盘
        let data = Data(repeating: 0x5A, count: 32 * 1024 * 1024)
        do {
            try data.write(to: URL(fileURLWithPath: probe))
        } catch {
            print("写图案失败: \(error.localizedDescription) (可移动卷权限?)"); sem.signal(); return
        }
        Darwin.sync()
        proxy.deepTrimNativeLocate(bsd as NSString) { s2 in
            let loc = s2 as String
            guard loc.hasPrefix("OFF="), let off = UInt64(loc.dropFirst(4)) else {
                print("locate: \(loc)")
                try? FileManager.default.removeItem(atPath: probe)
                sem.signal(); return
            }
            print("定位: 偏移 \(off) — 删除图案并执行定向 UNMAP...")
            try? FileManager.default.removeItem(atPath: probe)
            Darwin.sync()
            proxy.deepTrimNativeExecute(bsd as NSString, offset: NSNumber(value: off)) { s3 in
                print("deeptrimnative: \(s3)")
                sem.signal()
            }
        }
    }
case "trimstats":
    // TRIM 通道灯: QMP unmap_ops 汇总 (受理≠执行, 物理判决看 deeptrim)
    proxy.trimStats { s in print("trimstats: \(s)"); sem.signal() }
case "quit":
    proxy.appQuit { _ in print("quit: 已通知 daemon 收尸自毁"); sem.signal() }
default:
    print("用法: anyfsctl status|list|takeover <分区...>|release|trim|deeptrim <分区>|deeptrimnative <分区>|trimstats|console|inject <命令>|share <分区>|quit")
    exit(2)
}
sem.wait()
conn.invalidate()
