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
    func deepTrim(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeBegin(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeLocate(_ bsd: NSString, withReply reply: @escaping (NSString) -> Void)
    func deepTrimNativeExecute(_ bsd: NSString, offset: NSNumber, withReply reply: @escaping (NSString) -> Void)
    func trimStats(withReply reply: @escaping (NSString) -> Void)
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
    let link: String      // 接口类型+协商速率, 如 "USB 3.x · 10 Gb/s"
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
    // guest 内全部文件系统都带 -o discard 挂载 (init.sh): 删除即在线 TRIM;
    // 手工全量养护 (fstrim 全盘空闲区) 对所有已接管分区开放
    var canManualTrim: Bool { active }
    // exFAT: macOS 原生可读写, 接管零收益 — 不给接管开关, 养护走 daemon 原生 DKIOCUNMAP
    var isExFAT: Bool { fs.lowercased().contains("exfat") }
    // 深度检测可用性: 接管的分区走 guest 链路; 未接管的 exFAT 走原生链路;
    // NTFS/ext* 未接管无通路 (macOS 写不了), 按钮置灰
    var canDeepTest: Bool { active || (isExFAT && mounted) }
}

struct DiskGroup: Identifiable {
    let id: String        // 父盘 bsd
    let model: String
    let link: String      // 接口类型+协商速率 (全盘整链相同, 取首个分区)
    var parts: [PartInfo]
}

@MainActor
final class DaemonClient: ObservableObject {
    @Published var parts: [PartInfo] = []
    @Published var loadedOnce = false               // 首次扫描完成前, 空态显示"加载中"而非"无盘"
    @Published var pending: Set<String> = []       // 接管/释放在途的分区
    @Published var trimming: Set<String> = []      // 养护在途的分区
    @Published var quitting = false                // 退出流程在途 (等 VM 关闭)
    @Published var lastError = ""
    @Published var notice = ""                     // 中性提示 (全局操作结果)
    @Published var trimResults: [String: String] = [:]  // 分区级养护结果 (bsd → 文案, 自动消失)

    // MARK: 展开详情 (状态放 Client: 面板关闭重开不丢)
    @Published var expanded: Set<String> = []          // 展开中的分区
    @Published var freeSpace: [String: String] = [:]   // bsd → 可用空间文案
    @Published var trimLights: [String: String] = [:]  // bsd → TRIM 通道灯文案
    @Published var deepTesting: Set<String> = []       // 深度检测在途
    @Published var deepResults: [String: String] = [:] // bsd → 判决文案 (不自动消失)

    // 详情懒加载: 展开时取一次, refresh 时若仍展开顺带刷新
    func toggleExpand(_ p: PartInfo) {
        if expanded.contains(p.id) {
            expanded.remove(p.id)
        } else {
            expanded.insert(p.id)
            loadDetails(p)
        }
    }

    func loadDetails(_ p: PartInfo) {
        guard !quitting else { return }
        // 可用空间: statfs 挂载点 (接管→SMB 挂载点; 未接管→macOS 原生挂载点)
        let mp = p.active ? "/Volumes/\(p.shareName)" : "/Volumes/\(p.label)"
        func statfsString() -> String? {
            guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: mp),
                  let free = attrs[.systemFreeSize] as? Int64 else { return nil }
            return String(format: "%.1fGB", Double(free) / 1e9)
        }
        if let s = statfsString() {
            freeSpace[p.id] = s
        } else if p.active {
            // SMB 共享未挂载 → 静默挂载后重试 (不在 Finder 打开)
            freeSpace[p.id] = "挂载中…"
            mountShare(p, open: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.freeSpace[p.id] = statfsString() ?? "未挂载共享"
            }
        } else {
            freeSpace[p.id] = "未挂载"
        }
        // TRIM 通道灯 (仅接管的分区有 QMP 计数可查)
        if p.active {
            proxy?.trimStats { [weak self] s in
                Task { @MainActor in
                    let r = s as String
                    self?.trimLights[p.id] = r
                }
            }
        } else {
            trimLights.removeValue(forKey: p.id)
        }
    }

    // 深度检测 (金标准产品化): 接管 → daemon guest 链路 (~2s/负向 ~19s);
    // 未接管 exFAT → 原生三阶段 (App 写删图案, daemon 位图 diff/UNMAP/读回)
    func deepTrim(_ p: PartInfo) {
        guard !quitting, p.canDeepTest, !deepTesting.contains(p.id) else { return }
        deepTesting.insert(p.id)
        deepResults.removeValue(forKey: p.id)
        if p.active {
            proxy?.deepTrim(p.id as NSString) { [weak self] s in
                Task { @MainActor in
                    self?.deepTesting.remove(p.id)
                    self?.deepResults[p.id] = s as String
                }
            }
            return
        }
        // 原生三阶段 (对齐 anyfsctl deeptrimnative 流程)
        let probe = "/Volumes/\(p.label)/.anyfs-trim-probe"
        proxy?.deepTrimNativeBegin(p.id as NSString) { [weak self] s in
            Task { @MainActor in
                guard let self else { return }
                guard (s as String) == "ok" else {
                    self.deepTesting.remove(p.id); self.deepResults[p.id] = s as String; return
                }
                do {
                    try Data(repeating: 0x5A, count: 32 * 1024 * 1024)
                        .write(to: URL(fileURLWithPath: probe))
                } catch {
                    self.deepTesting.remove(p.id)
                    self.deepResults[p.id] = "failed: 写图案失败 (可移动卷权限?)"
                    return
                }
                Darwin.sync()
                self.proxy?.deepTrimNativeLocate(p.id as NSString) { [weak self] s2 in
                    Task { @MainActor in
                        guard let self else { return }
                        let loc = s2 as String
                        guard loc.hasPrefix("OFF="), let off = UInt64(loc.dropFirst(4)) else {
                            try? FileManager.default.removeItem(atPath: probe)
                            self.deepTesting.remove(p.id)
                            self.deepResults[p.id] = loc
                            return
                        }
                        try? FileManager.default.removeItem(atPath: probe)
                        Darwin.sync()
                        self.proxy?.deepTrimNativeExecute(p.id as NSString,
                                                          offset: NSNumber(value: off)) { [weak self] s3 in
                            Task { @MainActor in
                                self?.deepTesting.remove(p.id)
                                self?.deepResults[p.id] = s3 as String
                            }
                        }
                    }
                }
            }
        }
    }

    // 通道灯文案解释: ops>0 有流量 / failed>0 被拒 / ● 未观察; 受理≠执行, 物理判决看深度检测
    func trimLightText(_ p: PartInfo) -> String {
        guard let r = trimLights[p.id] else { return p.active ? "查询中…" : "—" }
        if r == "inactive" { return "● 未观察" }
        let failed = Int(r.components(separatedBy: "failed=").last ?? "") ?? 0
        let ops = Int(r.components(separatedBy: "ops=").last?.components(separatedBy: " ").first ?? "") ?? 0
        if failed > 0 { return "❌ UNMAP 被拒 (\(failed))" }
        if ops > 0 { return "✅ 有 TRIM 流量 (\(ops) 次, 受理≠执行)" }
        return "● 未观察"
    }

    // 消息自动消失: 代次守卫, 新消息挤掉旧的计时 (成功 6s / 错误 8s)
    private var errorGen = 0, noticeGen = 0, trimGen: [String: Int] = [:]
    func setError(_ s: String) {
        lastError = s; errorGen += 1
        let g = errorGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.errorGen == g else { return }
            self.lastError = ""
        }
    }
    func setNotice(_ s: String) {
        notice = s; noticeGen += 1
        let g = noticeGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.noticeGen == g else { return }
            self.notice = ""
        }
    }
    private func setTrimResult(_ bsd: String, _ s: String) {
        trimResults[bsd] = s
        let g = (trimGen[bsd] ?? 0) + 1
        trimGen[bsd] = g
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.trimGen[bsd] == g else { return }
            self.trimResults.removeValue(forKey: bsd)
        }
    }

    var busy: Bool { !pending.isEmpty || !trimming.isEmpty || quitting }
    var anyActive: Bool { parts.contains(where: \.active) }
    var groups: [DiskGroup] {
        Dictionary(grouping: parts, by: \.disk)
            .map { DiskGroup(id: $0.key, model: $0.value.first?.model ?? $0.key,
                             link: $0.value.first?.link ?? "",
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
            Task { @MainActor in self?.setError("daemon 连接中断, 重连中") }
        }
        c.resume()
        conn = c
        proxy = c.remoteObjectProxyWithErrorHandler { [weak self] err in
            Task { @MainActor in self?.setError(err.localizedDescription) }
        } as? AnyFSDaemonProtocol
    }

    func refresh() {
        // 退出流程中冻结轮询: 否则收尸窗口内 (SMB 已卸但 activeParts 未清)
        // 会把 daemon 重新拉起并触发 mountShare 挂向将死 VM (2026-11-13 实踩:
        // mount_smbfs 卡 TCP 超时堵死主线程, NSApp.terminate 排不进来)
        guard !quitting else { return }
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
                                    link: d["link"] as? String ?? "",
                                    shareName: share)
                }
                // 展开中的分区顺带刷新详情 (3s 轮询驱动, 通道灯/可用空间保持新鲜)
                if let self {
                    self.loadedOnce = true
                    for id in self.expanded {
                        if let p = self.parts.first(where: { $0.id == id }) { self.loadDetails(p) }
                    }
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
                        self?.setError(s as String)
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
                    if !r.hasPrefix("released") { self?.setError(r) }
                    self?.refresh()
                    // 部分释放后 daemon 已卸所有 anyFS SMB 挂载, 静默重挂剩余分区
                    for part in remaining { self?.mountShare(part, open: false) }
                }
            }
        }
    }

    // 按分区养护 (所有已接管分区, 含 NTFS; guest 内 fstrim 全盘空闲区)
    // 注意: 必须传 shareName (guest 挂载点同名), 显示 label 可能是非 ASCII
    func trim(_ p: PartInfo) {
        guard !busy else { return }
        trimming.insert(p.id)
        proxy?.trimPartition(p.shareName as NSString) { [weak self] s in
            Task { @MainActor in
                self?.trimming.remove(p.id)
                self?.setTrimResult(p.id, s as String)
                self?.refresh()
            }
        }
    }

    // exFAT 手动养护 (宿主直发) (不接管; daemon 卸载→DKIOCUNMAP→挂回, 不经 VM)
    func trimNative(_ p: PartInfo) {
        guard !busy else { return }
        trimming.insert(p.id)
        proxy?.trimNative(p.id as NSString) { [weak self] s in
            Task { @MainActor in
                self?.trimming.remove(p.id)
                let r = s as String
                self?.setTrimResult(p.id, r)
                self?.refresh()
            }
        }
    }

    // 挂载 SMB 共享 (open=true 时在 Finder 打开)
    // 挂载点由 daemon (root) 预建并 chown 给当前用户 — /Volumes 普通用户不可建目录
    // mount_smbfs 的等待必须离开主线程: 挂向将死/未就绪的 VM 会卡到 TCP 超时,
    // 在主线程 waitUntilExit 会堵死 UI 和退出流程 (2026-11-13 实踩)
    func mountShare(_ p: PartInfo, open: Bool) {
        guard !quitting else { return }
        proxy?.prepareMountpoint(p.shareName as NSString) { [weak self] path in
            let mp = path as String
            guard mp.hasPrefix("/") else {
                Task { @MainActor in self?.setError(mp) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/sbin/mount_smbfs")
                t.arguments = ["//GUEST@anyFS.local/\(p.shareName)", mp]
                let err = Pipe()
                t.standardError = err
                try? t.run()
                t.waitUntilExit()
                let status = t.terminationStatus
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                Task { @MainActor in
                    guard let self, !self.quitting else { return }
                    // EEXIST (已挂载) 不算错误
                    if status != 0 && !e.contains("File exists") {
                        self.setError("SMB 挂载失败: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                    if open { NSWorkspace.shared.open(URL(fileURLWithPath: mp)) }
                }
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
                if client.loadedOnce {
                    Text("插入含 NTFS / exFAT / ext4 的外接盘\n分区会自动出现在这里")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                } else {
                    // 首次扫描的过渡态: 与"真无盘"区分开
                    HStack(spacing: 8) {
                        ArcSpinner(size: 14)
                        Text("正在扫描外接盘…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
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
                if !g.link.isEmpty {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(g.link)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                if p.active {
                    Text("· 在线养护").foregroundStyle(.secondary)
                }
                if p.isExFAT && !p.active {
                    // macOS exFAT 驱动自己从不发 TRIM (Ti600 掉速的根因);
                    // 这里的养护是 anyFS 手动触发: daemon 卸载 → 解析位图 → 直发 DKIOCUNMAP → 挂回
                    Text("· 手动养护").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .animation(.easeInOut(duration: 0.3), value: p.stateText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func partRow(_ p: PartInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    Button { client.trim(p) } label: {
                        Image(systemName: "leaf")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("立即养护 (fstrim 全盘空闲区)")
                    Button { client.mountShare(p, open: true) } label: {
                        Image(systemName: "folder.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help("挂载并在 Finder 打开")
                }
            } else if p.isExFAT {
                // 手动养护 (不经 VM): daemon 卸载 → 解析位图找空闲簇 → 直发 DKIOCUNMAP → 挂回
                Button { client.trimNative(p) } label: {
                    Image(systemName: "leaf")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(client.busy)
                .help("立即养护 (anyFS 直发 UNMAP 全盘空闲区, 期间卷会短暂卸载)")
            }
            // 展开详情 chevron (所有分区行都有; 深度检测可用性在详情内判定)
            Button { client.toggleExpand(p) } label: {
                Image(systemName: client.expanded.contains(p.id) ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("详细信息")
        }
            // 养护结果挂在分区行下方, 自动消失
            if let r = client.trimResults[p.id] {
                Text(r)
                    .font(.caption)
                    .foregroundStyle(r.hasPrefix("failed") ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            // 展开详情: 格式/大小/可用空间/TRIM 通道灯 + 深度检测 (金标准, 不持久化状态)
            if client.expanded.contains(p.id) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(p.fs) · 容量 \(p.sizeGB)GB · 可用 \(client.freeSpace[p.id] ?? "…")")
                    HStack(spacing: 8) {
                        Text("TRIM 通道: \(client.trimLightText(p))")
                            .lineLimit(1)
                        Spacer()
                        if client.deepTesting.contains(p.id) {
                            ArcSpinner(size: 12)
                            Text("检测中…")
                        } else {
                            Button("深度检测") { client.deepTrim(p) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(p.canDeepTest ? Color.accentColor : Color.secondary)
                                .disabled(!p.canDeepTest)
                                .help(p.canDeepTest
                                      ? "埋图案→删除→物理读回判决 (~2s/负向~19s)"
                                      : "接管后可用 (NTFS/ext* 未接管 macOS 写不了)")
                        }
                    }
                    if let r = client.deepResults[p.id] {
                        Text(r)
                            .foregroundStyle(r.hasPrefix("failed") || r.contains("未生效")
                                             ? Color.red : Color.green)
                            .lineLimit(3)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .padding(10)
        // 每分区一个浅底色框: 标签/开关/按钮/结果/展开详情全部收敛在框内
        // (primary 低透明度: 深/浅模式自适应, 比面板底色略浅的浮起卡片感)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
