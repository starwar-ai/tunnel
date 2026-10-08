// IntranetTunnel — macOS 菜单栏应用
// 状态栏图标实时显示隧道状态，支持一键开关、原生配置窗口、日志窗口、开机自启。
// 隧道本体由 app 以子进程方式运行: python3 run_client.py --config <用户目录>/client.json
import SwiftUI
import AppKit
import ServiceManagement

// MARK: - 配置模型（与 client.json 对应）

struct TunnelEntry: Codable, Equatable {
    var remote_port: Int
    var local_host: String
    var local_port: Int
}

struct ClientConfig: Codable {
    var server: String
    var token: String
    var tunnels: [String: TunnelEntry]
}

// MARK: - 状态

enum TunnelState: Equatable {
    case off            // 已关闭
    case starting       // 正在连接
    case connected      // 已连接
    case reconnecting   // 断线重连中
}

// MARK: - 隧道进程管理

final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var state: TunnelState = .off
    @Published private(set) var desiredOn = false
    @Published private(set) var logLines: [String] = []

    /// 隧道应保持运行（用于配置保存后自动重启、崩溃自动拉起）
    private var process: Process?
    private var respawnItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "intranet-tunnel.reader")

    static let pythonCandidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    static let legacyConfig = URL(fileURLWithPath: "/Library/Application Support/intranet-tunnel/client.json")

    let configDir: URL
    let configPath: URL
    private var resources: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = home.appendingPathComponent("Library/Application Support/intranet-tunnel")
        configPath = configDir.appendingPathComponent("client.json")
        prepareConfig()
    }

    // MARK: 配置文件

    private func prepareConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: configPath.path) else { return }
        // 旧版 pkg（LaunchDaemon）的配置优先迁移，其次用内置模板
        let template = fm.fileExists(atPath: Self.legacyConfig.path)
            ? Self.legacyConfig
            : resources.appendingPathComponent("client.template.json")
        if fm.fileExists(atPath: template.path) {
            try? fm.copyItem(at: template, to: configPath)
        } else {
            let def = ClientConfig(server: "SERVER_IP:7000", token: "CHANGE_ME",
                                   tunnels: ["web": TunnelEntry(remote_port: 8080, local_host: "127.0.0.1", local_port: 80)])
            if let data = try? JSONEncoder().encode(def) {
                try? data.write(to: configPath)
            }
        }
    }

    func loadConfig() -> ClientConfig? {
        guard let data = try? Data(contentsOf: configPath) else { return nil }
        return try? JSONDecoder().decode(ClientConfig.self, from: data)
    }

    /// 配置保存后调用：运行中则平滑重启使新配置生效
    func applyRestart() {
        if process != nil {
            desiredOn = true
            state = .starting
            process?.terminate()   // 退出后由 terminationHandler 自动重启
        }
    }

    // MARK: 开关

    func toggle() { desiredOn ? stop() : start() }

    func start() {
        guard process == nil else { return }
        desiredOn = true
        state = .starting
        appendLog("启动隧道客户端…")
        spawn()
    }

    func stop() {
        desiredOn = false
        respawnItem?.cancel()
        if let p = process {
            appendLog("停止隧道客户端。")
            p.terminate()
        } else {
            state = .off
        }
    }

    private func spawn() {
        let py = Self.pythonCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let py else {
            appendLog("错误: 未找到 python3，请先安装 Xcode 命令行工具（xcode-select --install）")
            state = .off
            desiredOn = false
            return
        }
        let script = resources.appendingPathComponent("run_client.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            appendLog("错误: 未找到 \(script.path)")
            state = .off
            desiredOn = false
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [script.path, "--config", configPath.path]
        p.environment = ["PYTHONUNBUFFERED": "1", "PYTHONIOENCODING": "utf-8",
                         "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                         "HOME": FileManager.default.homeDirectoryForCurrentUser.path]

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        readLines(out.fileHandleForReading)
        readLines(err.fileHandleForReading)

        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                if self.desiredOn {
                    self.state = .reconnecting
                    self.appendLog("客户端进程退出（code \(proc.terminationStatus)），3 秒后自动重启…")
                    self.scheduleRespawn()
                } else {
                    self.state = .off
                }
            }
        }

        do {
            try p.run()
            process = p
        } catch {
            appendLog("错误: 启动失败 \(error.localizedDescription)")
            state = .off
            desiredOn = false
        }
    }

    private func scheduleRespawn() {
        respawnItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.desiredOn, self.process == nil else { return }
            self.spawn()
        }
        respawnItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
    }

    /// 把管道字节流按行送回主线程解析
    private func readLines(_ handle: FileHandle) {
        var buffer = Data()
        handle.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            self?.queue.async {
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: Data(lineData), encoding: .utf8), !line.isEmpty {
                        DispatchQueue.main.async { self?.handle(line) }
                    }
                }
            }
        }
    }

    /// 解析 client.py 的日志行，更新菜单栏状态
    private func handle(_ line: String) {
        appendLog(line)
        guard desiredOn else { return }
        if line.contains("已连接服务器") {
            state = .connected
        } else if line.contains("就绪") {
            state = .connected
        } else if line.contains("连接失败") || line.contains("秒后重连") || line.contains("服务端错误") {
            state = .reconnecting
        }
    }

    private func appendLog(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logLines.append("[\(stamp)] \(line)")
        if logLines.count > 2000 { logLines.removeFirst(logLines.count - 2000) }
    }

    /// 供 UI 写入日志（如开机自启设置失败）
    func note(_ line: String) { appendLog(line) }

    // MARK: 展示

    var iconName: String {
        switch state {
        case .connected:                return "arrow.up.arrow.down.circle.fill"
        case .starting, .reconnecting:  return "arrow.up.arrow.down.circle"
        case .off:                      return "pause.circle"
        }
    }

    var statusText: String {
        switch state {
        case .off:
            return "隧道已关闭"
        case .starting:
            return "正在连接服务器…"
        case .connected:
            return "已连接 \(loadConfig()?.server ?? "")"
        case .reconnecting:
            return "连接断开，自动重连中…"
        }
    }
}

// MARK: - 菜单栏

struct StatusBarIcon: View {
    @ObservedObject private var m = TunnelManager.shared
    var body: some View { Image(systemName: m.iconName) }
}

struct MenuContent: View {
    @ObservedObject private var m = TunnelManager.shared
    @Environment(\.openWindow) private var openWindow

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { on in
                do {
                    if on { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    m.note("设置开机自启失败: \(error.localizedDescription)")
                }
            })
    }

    var body: some View {
        Text(m.statusText)
        Divider()
        Button(m.desiredOn ? "关闭隧道" : "开启隧道") { m.toggle() }
        Button("配置…") { openWindow(id: "config"); NSApp.activate(ignoringOtherApps: true) }
        Button("查看日志…") { openWindow(id: "log"); NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Toggle("开机自启", isOn: launchAtLogin)
        Divider()
        Button("退出") {
            m.stop()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - 配置窗口

private struct TunnelRow: Identifiable {
    let id = UUID()
    var name: String
    var remotePort: String
    var localHost: String
    var localPort: String
}

/// 隧道编辑行：与列头固定同宽，端口字段只允许数字
private struct TunnelRowView: View {
    @Binding var row: TunnelRow
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("名称", text: $row.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 108)
            TextField("如 8080", text: $row.remotePort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .onChange(of: row.remotePort) { row.remotePort = String($0.filter { $0.isNumber }.prefix(5)) }
            TextField("如 127.0.0.1", text: $row.localHost)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120)
            TextField("如 80", text: $row.localPort)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .onChange(of: row.localPort) { row.localPort = String($0.filter { $0.isNumber }.prefix(5)) }
            Button(action: onDelete) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .frame(width: 24)
            .help("删除这条隧道")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
    }
}

struct ConfigView: View {
    @ObservedObject private var m = TunnelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var server: String
    @State private var token: String
    @State private var rows: [TunnelRow]
    @State private var error: String?

    init() {
        let c = TunnelManager.shared.loadConfig()
        _server = State(initialValue: c?.server ?? "")
        _token = State(initialValue: c?.token ?? "")
        _rows = State(initialValue: c?.tunnels.map {
            TunnelRow(name: $0.key, remotePort: String($0.value.remote_port),
                      localHost: $0.value.local_host, localPort: String($0.value.local_port))
        } ?? [])
    }

    /// 与 TunnelRowView 各列严格同宽的列头
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("名称").frame(width: 108, alignment: .leading)
            Text("公网端口").frame(width: 78, alignment: .leading)
            Text("本地地址").frame(minWidth: 120, alignment: .leading)
            Text("本地端口").frame(width: 78, alignment: .leading)
            Color.clear.frame(width: 24, height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("服务器") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("地址").frame(width: 60, alignment: .leading)
                        TextField("例如 1.2.3.4:7000", text: $server)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        Text("令牌").frame(width: 60, alignment: .leading)
                        SecureField("访问令牌", text: $token)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("隧道规则（公网端口 → 本地服务）") {
                VStack(alignment: .leading, spacing: 8) {
                    columnHeader
                    ForEach($rows) { $row in
                        TunnelRowView(row: $row) {
                            rows.removeAll { $0.id == row.id }
                        }
                    }
                    Button {
                        rows.append(TunnelRow(name: "tunnel\(rows.count + 1)",
                                              remotePort: "", localHost: "127.0.0.1", localPort: ""))
                    } label: {
                        Label("添加隧道", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                if m.desiredOn {
                    Text("隧道运行中，保存后自动重启")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存并应用") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 580, minHeight: 460)
    }

    private func save() {
        error = nil
        let hostPort = server.split(separator: ":")
        guard hostPort.count == 2, let port = Int(hostPort[1]), (1...65535).contains(port) else {
            error = "服务器地址格式应为 host:port，例如 1.2.3.4:7000"; return
        }
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = "访问令牌不能为空"; return
        }
        guard !rows.isEmpty else { error = "至少保留一条隧道规则"; return }

        var tunnels: [String: TunnelEntry] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { error = "隧道名称不能为空"; return }
            guard tunnels[name] == nil else { error = "隧道名称重复：\(name)"; return }
            guard let rp = Int(row.remotePort.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(rp) else { error = "公网端口无效：\(name)"; return }
            guard !row.localHost.trimmingCharacters(in: .whitespaces).isEmpty else {
                error = "本地地址不能为空：\(name)"; return
            }
            guard let lp = Int(row.localPort.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(lp) else { error = "本地端口无效：\(name)"; return }
            tunnels[name] = TunnelEntry(remote_port: rp, local_host: row.localHost.trimmingCharacters(in: .whitespaces), local_port: lp)
        }

        let cfg = ClientConfig(server: server.trimmingCharacters(in: .whitespaces),
                               token: token.trimmingCharacters(in: .whitespaces), tunnels: tunnels)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(cfg)
            try data.write(to: m.configPath, options: .atomic)
            m.applyRestart()
            // 保存成功后关闭配置窗口（校验失败时不关闭）
            dismiss()
            NSApp.keyWindow?.performClose(nil)
        } catch {
            self.error = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 日志窗口

private struct LogTextView: NSViewRepresentable {
    @ObservedObject private var m = TunnelManager.shared
    private let tv = NSTextView()

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .textBackgroundColor
        tv.autoresizingMask = [.width]
        tv.isRichText = false
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let co = context.coordinator
        if m.logLines.count > co.rendered {
            let chunk = m.logLines[co.rendered...].joined(separator: "\n")
            co.rendered = m.logLines.count
            tv.textStorage?.append(NSAttributedString(string: chunk + "\n"))
            tv.scrollToEndOfDocument(nil)
        } else if m.logLines.count < co.rendered {
            co.rendered = 0
            tv.string = ""
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var rendered = 0 }
}

struct LogView: View {
    var body: some View { LogTextView() }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.object(forKey: "autoStartTunnel") == nil {
            UserDefaults.standard.set(true, forKey: "autoStartTunnel")   // 默认开启
        }
        if CommandLine.arguments.contains("--show-config") {
            // 调试/预览：直接弹出配置窗口
            let win = NSWindow(contentViewController: NSHostingController(rootView: ConfigView()))
            win.title = "配置"
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else if UserDefaults.standard.bool(forKey: "autoStartTunnel") {
            TunnelManager.shared.start()
        }
    }
}

@main
struct IntranetTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            StatusBarIcon()
        }
        Window("配置", id: "config") { ConfigView() }
        Window("运行日志", id: "log") { LogView().frame(minWidth: 560, minHeight: 380) }
    }
}
