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
    print("fstrim 执行中 (exFAT/ext4 分区, 可能需数秒~数分钟)...")
    proxy.trimNow { s in print("trim: \(s)"); sem.signal() }
case "quit":
    proxy.appQuit { _ in print("quit: 已通知 daemon 收尸自毁"); sem.signal() }
default:
    print("用法: anyfsctl status|list|takeover <分区...>|release|trim|quit")
    exit(2)
}
sem.wait()
conn.invalidate()
