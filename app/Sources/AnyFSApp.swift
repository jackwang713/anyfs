// AnyFSApp.swift — anyFS 菜单栏 App (S5c, v0.3)
// 设计原则: 无全局状态概念, 分区行自表达; 顶部只在有任务时显示活动指示
// 纯状态栏形态: LSUIElement 无 Dock 无主窗口; App 退出 → daemon 收尸自毁
// 构建: build-app.sh (CLT swiftc 直编, 无需 Xcode)
import SwiftUI
import AppKit

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
    func appQuit(withReply reply: @escaping (NSNumber) -> Void)
}

struct PartInfo: Identifiable, Equatable {
    let id: String        // bsd, 如 disk3s3
    let label: String
    let fs: String
    let sizeGB: String
    let mounted: Bool     // macOS 原生挂载中
    let active: Bool      // anyFS 接管中
    let disk: String      // 父盘, 如 disk3
    let model: String     // 盘型号, 如 RTL9210B-CG
    // guest SMB 共享名 (daemon 下发, 与 guest 挂载点/smb.conf 一致);
    // 非 ASCII 卷标回退为 bsd — mount_smbfs URL 解析器不接受非 ASCII
    let shareName: String
    // 三态文案: 回答"我现在能不能往里拷东西"
    // 注意: macOS 原生挂载的读写性因文件系统而异 — NTFS 只读, FAT32/exFAT 原生可读写
    var stateText: String {
        if active { return "可读写" }
        if mounted { return fs.lowercased().contains("ntfs") ? "macOS 只读" : "macOS 读写" }
        return "未挂载"
    }
    var stateColor: Color { active ? .green : (mounted ? .blue : .gray) }
    // NTFS 由 discard 在线养护, 无按钮; exFAT/ext* 需要手动 fstrim
    var needsManualTrim: Bool {
        let f = fs.lowercased()
        return f.contains("exfat") || f.contains("ext") || f.contains("fat") || f.contains("msdos")
    }
    // exFAT: macOS 原生可读写, 接管零收益 — 不给接管开关, 养护走 daemon 原生 DKIOCUNMAP
    var isExFAT: Bool { fs.lowercased().contains("exfat") }
}

struct DiskGroup: Identifiable {
    let id: String        // 父盘 bsd
    let model: String
    var parts: [PartInfo]
}

@MainActor
final class DaemonClient: ObservableObject {
    @Published var parts: [PartInfo] = []
    @Published var pending: Set<String> = []       // 接管/释放在途的分区
    @Published var trimming: Set<String> = []      // 养护在途的分区
    @Published var quitting = false                // 退出流程在途 (等 VM 关闭)
    @Published var lastError = ""
    @Published var notice = ""                     // 中性提示 (养护结果等)

    var busy: Bool { !pending.isEmpty || !trimming.isEmpty || quitting }
    var anyActive: Bool { parts.contains(where: \.active) }
    var groups: [DiskGroup] {
        Dictionary(grouping: parts, by: \.disk)
            .map { DiskGroup(id: $0.key, model: $0.value.first?.model ?? $0.key,
                             parts: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.id < $1.id }
    }

    private var conn: NSXPCConnection?
    private var proxy: AnyFSDaemonProtocol?

    init() { connect() }

    func connect() {
        let c = NSXPCConnection(machServiceName: "com.anyfs.daemon", options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: AnyFSDaemonProtocol.self)
        c.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.lastError = "daemon 连接中断, 重连中" }
        }
        c.resume()
        conn = c
        proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in self?.lastError = err.localizedDescription }
        } as? AnyFSDaemonProtocol
    }

    func refresh() {
        proxy?.listAvailable { [weak self] arr in
            Task { @MainActor in
                self?.parts = arr.compactMap { item -> PartInfo? in
                    guard let d = item as? [String: Any],
                          let bsd = d["bsd"] as? String else { return nil }
                    let label = d["label"] as? String ?? bsd
                    // 老版本 daemon 无 "share" 字段时按旧规则本地推导
                    let share = (d["share"] as? String)
                        ?? ((!label.isEmpty && label.allSatisfy(\.isASCII))
                            ? label.replacingOccurrences(of: " ", with: "_") : bsd)
                    return PartInfo(id: bsd,
                                    label: label,
                                    fs: d["fs"] as? String ?? "",
                                    sizeGB: d["sizeGB"] as? String ?? "?",
                                    mounted: d["mounted"] as? Bool ?? false,
                                    active: d["active"] as? Bool ?? false,
                                    disk: d["disk"] as? String ?? bsd,
                                    model: d["model"] as? String ?? (d["disk"] as? String ?? ""),
                                    shareName: share)
                }
            }
        }
    }

    // 开关分区: on=接管, off=释放
    func setPartition(_ p: PartInfo, on: Bool) {
        guard !busy else { return }
        if on {
            pending.insert(p.id)
            let newSet = parts.filter(\.active).map(\.id) + [p.id]
            proxy?.takeover(newSet as NSArray) { [weak self] s in
                Task { @MainActor in
                    self?.pending.remove(p.id)
                    if (s as String).hasPrefix("ready") {
                        self?.mountShare(p, open: true)
                    } else {
                        self?.lastError = s as String
                    }
                    self?.refresh()
                }
            }
        } else {
            // 释放触发 VM 重启: 所有活动分区都会短暂中断, 全部置为在途态
            let affected = parts.filter(\.active).map(\.id)
            pending.formUnion(affected)
            let remaining = parts.filter { $0.active && $0.id != p.id }
            proxy?.release([p.id] as NSArray) { [weak self] s in
                Task { @MainActor in
                    self?.pending.subtract(affected)
                    let r = s as String
                    if !r.hasPrefix("released") { self?.lastError = r }
                    self?.refresh()
                    // 部分释放后 daemon 已卸所有 anyFS SMB 挂载, 静默重挂剩余分区
                    for part in remaining { self?.mountShare(part, open: false) }
                }
            }
        }
    }

    // 按分区养护 (exFAT/ext*; NTFS 无此按钮)
    // 注意: 必须传 shareName (guest 挂载点同名), 显示 label 可能是非 ASCII
    func trim(_ p: PartInfo) {
        guard !busy else { return }
        trimming.insert(p.id)
        proxy?.trimPartition(p.shareName as NSString) { [weak self] _ in
            Task { @MainActor in self?.trimming.remove(p.id); self?.refresh() }
        }
    }

    // exFAT 原生养护 (不接管; daemon 卸载→DKIOCUNMAP→挂回, 不经 VM)
    func trimNative(_ p: PartInfo) {
        guard !busy else { return }
        trimming.insert(p.id)
        proxy?.trimNative(p.id as NSString) { [weak self] s in
            Task { @MainActor in
                self?.trimming.remove(p.id)
                let r = s as String
                if r.hasPrefix("failed") { self?.lastError = r } else { self?.notice = r }
                self?.refresh()
            }
        }
    }

    // 挂载 SMB 共享 (open=true 时在 Finder 打开)
    // 挂载点由 daemon (root) 预建并 chown 给当前用户 — /Volumes 普通用户不可建目录
    func mountShare(_ p: PartInfo, open: Bool) {
        proxy?.prepareMountpoint(p.shareName as NSString) { [weak self] path in
            Task { @MainActor in
                let mp = path as String
                guard mp.hasPrefix("/") else { self?.lastError = mp; return }
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
                t.arguments = ["//GUEST@anyFS.local/\(p.shareName)", mp]
                let err = Pipe()
                t.standardError = err
                try? t.run()
                t.waitUntilExit()
                if t.terminationStatus != 0 {
                    let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    // EEXIST (已挂载) 不算错误
                    if !e.contains("File exists") {
                        self?.lastError = "SMB 挂载失败: \(e.trimmingCharacters(in: .whitespacesAndNewlines))"
                    }
                }
                if open { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
            }
        }
    }

    // 退出: 面板显示"正在关闭…", daemon 收尸完成 (VM 关闭) 回话后才真正退出
    func quitApp() {
        guard !quitting else { return }
        quitting = true
        proxy?.appQuit { _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
        // 兜底: 收尸最长 ~15s, 留余量到 20s; daemon 无响应也保证 App 能退
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
    }
}

// MARK: - 动画组件
// 科技感旋转弧线 (雷达扫掠), 替代系统 ProgressView
struct ArcSpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.6
    @State private var spinning = false
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                spinning = true
            }
        }
    }
}

// MARK: - 面板
struct MenuPanel: View {
    @ObservedObject var client: DaemonClient
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if client.busy {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                    .transition(.opacity)
            }
            Divider()
            if client.parts.isEmpty {
                Text("插入含 NTFS / exFAT / ext4 的外接盘\n分区会自动出现在这里")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(client.groups) { g in
                    diskSection(g)
                }
            }
            if !client.lastError.isEmpty {
                Text(client.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if !client.notice.isEmpty {
                Text(client.notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
        // 不透明底色: window 样式的 MenuBarExtra 窗口默认透明, 下层浅色时白字看不清
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: client.busy)
        .onAppear { client.refresh() }
        .onReceive(timer) { _ in client.refresh() }
    }

    // 顶部: 品牌 + 仅在有任务时出现的活动指示 (无全局状态概念)
    private var header: some View {
        HStack(spacing: 8) {
            if let img = NSImage(named: "menubar") {
                Image(nsImage: img)
                    .resizable()
                    .renderingMode(.template)
                    .frame(width: 26, height: 26)
                    .foregroundStyle(
                        LinearGradient(colors: [Color(red: 0.38, green: 0.68, blue: 1.0),
                                                Color(red: 0.18, green: 0.45, blue: 0.95)],
                                       startPoint: .top, endPoint: .bottom)
                    )
            }
            Text("anyFS").font(.headline)
            Spacer()
            if client.busy {
                ArcSpinner(size: 14)
                Text(client.quitting ? "正在关闭…" : (!client.trimming.isEmpty ? "养护中…" : "处理中…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .frame(height: 20)
    }

    private func diskSection(_ g: DiskGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(g.model)
                    .font(.body)
                    .fontWeight(.semibold)
                Text(g.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(g.parts) { p in
                partRow(p)
            }
        }
    }

    // 分区标签 (卷标 + 状态行), Toggle 和裸行两种形态共用
    private func partLabel(_ p: PartInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(p.label).font(.body)
            HStack(spacing: 4) {
                Text("\(p.fs) · \(p.sizeGB)GB")
                Text("·")
                Text(p.stateText).foregroundStyle(p.stateColor)
                if p.active && !p.needsManualTrim {
                    Text("· 在线养护").foregroundStyle(.secondary)
                }
                if p.isExFAT && !p.active {
                    Text("· 原生养护").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.3), value: p.stateText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func partRow(_ p: PartInfo) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if p.isExFAT && !p.active {
                // exFAT: macOS 原生可读写, 接管零收益 — 无开关, 只给养护按钮
                partLabel(p)
            } else {
                Toggle(isOn: Binding(
                    get: { p.active },
                    set: { client.setPartition(p, on: $0) }
                )) {
                    partLabel(p)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(client.busy)
            }
            if client.pending.contains(p.id) {
                ArcSpinner(size: 14)
            } else if client.trimming.contains(p.id) {
                ArcSpinner(size: 14)
            } else if p.active {
                HStack(spacing: 10) {
                    if p.needsManualTrim {
                        Button { client.trim(p) } label: {
                            Image(systemName: "leaf")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .help("立即养护 (fstrim)")
                    }
                    Button { client.mountShare(p, open: true) } label: {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("挂载并在 Finder 打开")
                }
            } else if p.isExFAT {
                // 原生养护: daemon 卸载 → DKIOCUNMAP → 挂回, 不经 VM
                Button { client.trimNative(p) } label: {
                    Image(systemName: "leaf")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(client.busy)
                .help("立即养护 (原生 TRIM, 期间卷会短暂卸载)")
            }
        }
        .padding(.leading, 4)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button { client.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.body)
            }
            .buttonStyle(.borderless)
            .help("刷新")
            Button { client.quitApp() } label: {
                Label("退出", systemImage: "power")
            }
        }
        .font(.callout)
    }
}

// MARK: - App 入口 (自定义菜单栏图标, 模板图自动适配深浅色)
@main
struct AnyFSApp: App {
    @StateObject private var client = DaemonClient()

    private static let menuBarIcon: NSImage? = {
        let i = NSImage(named: "menubar")
        i?.isTemplate = true
        return i
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(client: client)
        } label: {
            if let img = Self.menuBarIcon {
                Image(nsImage: img)
            } else {
                Image(systemName: "externaldrive.connected.to.line.below")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
