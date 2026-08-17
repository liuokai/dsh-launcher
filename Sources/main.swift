// DSH — DeepSeek Harness Mac 端启动器
//
// 双击启动 App 后自动完成：
//   1. 检查 http://127.0.0.1:<port> 是否已有 dsh web 服务（有则直接连接）
//   2. 否则自动运行 `npx --yes @deepseek-ai/dsh web --port <port>`
//   3. 等待服务就绪后在内嵌 WKWebView 中打开 DeepSeek Harness GUI
//
// 命令行参数：
//   --selftest [--port <port>]   无头自测：启动服务→探测就绪→停止→退出

import AppKit
import WebKit
import ServiceManagement
import Foundation
import Darwin

// MARK: - 工具函数

struct LaunchError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 同步执行命令并返回 stdout（带超时，防止 shell 配置脚本卡死）
func runCapture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 12) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = arguments
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe() // 丢弃 stderr
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if p.isRunning { p.terminate(); p.waitUntilExit() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

// MARK: - 日志缓冲（线程安全，环形）

final class LogBuffer {
    private let lock = NSLock()
    private var lines: [String] = []
    /// 追加后回调（已在主线程）
    var onAppend: (() -> Void)?

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        let parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append(contentsOf: parts)
        if lines.count > 4000 { lines.removeFirst(lines.count - 4000) }
        DispatchQueue.main.async { [weak self] in self?.onAppend?() }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }

    func lastLines(_ n: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        return lines.suffix(n).joined(separator: "\n")
    }
}

// MARK: - 服务管理

final class ServerManager {
    static let shared = ServerManager()

    let log = LogBuffer()

    /// 用户配置的端口（默认 3080，可在「服务器 → 端口设置…」修改）
    var port: Int {
        let v = UserDefaults.standard.integer(forKey: "port")
        return v > 0 ? v : 3080
    }

    /// 当前托管的服务进程（仅当本 App 启动它时非 nil）
    private(set) var process: Process?
    /// 服务进程是否由本 App 启动（决定退出/重启时是否杀进程）
    var ownsProcess = false
    /// 退出时是否保留服务进程
    var keepServerOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: "keepServerOnQuit") }
        set { UserDefaults.standard.set(newValue, forKey: "keepServerOnQuit") }
    }
    /// 自测模式使用的 HOME（隔离存储，避免影响真实 profile）
    var homeOverride: String?
    /// 服务进程意外退出时回调（主线程）
    var onProcessExit: (() -> Void)?

    private var cachedNpx: String?
    private var cachedShellPath: String?

    var serverURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    // MARK: 定位 npx

    /// Finder 启动的 App PATH 很干净（/usr/bin:/bin:…），必须从登录 shell 补全
    func resolveNpx() -> String? {
        if let c = cachedNpx { return c }
        var candidates: [String] = []
        if let p = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: p.split(separator: ":").map { "\($0)/npx" })
        }
        let shells: [(String, [String])] = [
            ("/bin/zsh", ["-l", "-c", "command -v npx 2>/dev/null || true"]),
            ("/bin/zsh", ["-i", "-c", "command -v npx 2>/dev/null || true"]),
            ("/bin/bash", ["-lc", "command -v npx 2>/dev/null || true"]),
        ]
        for (shell, args) in shells {
            if let out = runCapture(shell, args),
               let s = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last,
               !s.isEmpty {
                candidates.insert(String(s), at: 0)
            }
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/npx",
            "/usr/local/bin/npx",
            NSHomeDirectory() + "/.local/bin/npx",
            NSHomeDirectory() + "/.hermes/node/bin/npx",
            NSHomeDirectory() + "/.volta/bin/npx",
            NSHomeDirectory() + "/.fnm/current/bin/npx",
        ])
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            cachedNpx = c
            return c
        }
        return nil
    }

    /// 登录 shell 的 PATH
    func loginShellPath() -> String? {
        if let c = cachedShellPath { return c }
        let shells: [(String, [String])] = [
            ("/bin/zsh", ["-l", "-c", "printf %s \"$PATH\""]),
            ("/bin/zsh", ["-i", "-c", "printf %s \"$PATH\""]),
            ("/bin/bash", ["-lc", "printf %s \"$PATH\""]),
        ]
        for (shell, args) in shells {
            if let out = runCapture(shell, args) {
                let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { cachedShellPath = s; return s }
            }
        }
        return nil
    }

    // MARK: 端口探测

    enum ProbeResult { case unreachable, dshRunning, otherServer }

    /// 探测端口上是否已有 DeepSeek Harness 服务（回调线程不保证）
    func probe(port: Int, completion: @escaping (ProbeResult) -> Void) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!,
                             cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: 2.5)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard resp is HTTPURLResponse else {
                completion(.unreachable)
                return
            }
            if let data, let body = String(data: data, encoding: .utf8)?.lowercased(),
               body.contains("__dsh_boot__") || body.contains("deepseek harness") {
                completion(.dshRunning)
            } else {
                completion(.otherServer)
            }
        }.resume()
    }

    // MARK: 启动 / 停止

    /// 启动 `npx --yes @deepseek-ai/dsh web --port <port>` 服务进程（同步返回）
    func spawn(npx: String, port: Int) -> Result<Void, LaunchError> {
        if let p = process, p.isRunning { return .success(()) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: npx)
        var args = ["--yes", "@deepseek-ai/dsh", "web", "--port", String(port)]
        if let extra = UserDefaults.standard.string(forKey: "extraArgs"), !extra.isEmpty {
            args.append(contentsOf: extra.split(separator: " ").map(String.init))
        }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        let home = homeOverride ?? NSHomeDirectory()
        env["HOME"] = home
        if let lp = loginShellPath() { env["PATH"] = lp }
        if homeOverride != nil { env["npm_config_cache"] = NSHomeDirectory() + "/.npm" }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: home)

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) { self?.log.append(s) }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onProcessExit?() }
        }
        do {
            try p.run()
        } catch {
            return .failure(LaunchError(message: "无法启动进程：\(error.localizedDescription)"))
        }
        process = p
        ownsProcess = true
        log.append("$ \(npx) \(args.joined(separator: " "))\n")
        return .success(())
    }

    /// 轮询直到服务可访问（回调在内部串行队列，调用方自行切主线程）
    func waitUntilReady(port: Int, timeout: TimeInterval,
                        progress: @escaping (Int) -> Void,
                        completion: @escaping (Bool) -> Void) {
        let queue = DispatchQueue(label: "dsh.wait-ready")
        let start = Date()
        queue.async {
            func tick() {
                if Date().timeIntervalSince(start) > timeout { completion(false); return }
                if let p = self.process, !p.isRunning { completion(false); return }
                self.probe(port: port) { r in
                    switch r {
                    case .dshRunning:
                        completion(true)
                    case .otherServer:
                        completion(false)
                    case .unreachable:
                        progress(Int(Date().timeIntervalSince(start)))
                        queue.asyncAfter(deadline: .now() + 0.5) { tick() }
                    }
                }
            }
            tick()
        }
    }

    /// 停止服务进程（SIGTERM，2.5s 后 SIGKILL）
    func stopServer() {
        guard let p = process, p.isRunning else {
            process = nil
            ownsProcess = false
            return
        }
        p.terminate()
        let deadline = Date().addingTimeInterval(2.5)
        while p.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
        ownsProcess = false
    }
}

// MARK: - 工具栏标识

extension NSToolbarItem.Identifier {
    static let reloadID = NSToolbarItem.Identifier("dsh.reload")
    static let browserID = NSToolbarItem.Identifier("dsh.browser")
    static let restartID = NSToolbarItem.Identifier("dsh.restart")
    static let logID = NSToolbarItem.Identifier("dsh.log")
    static let urlID = NSToolbarItem.Identifier("dsh.url")
}

// MARK: - 页面配色（取自 DSH 前端 CSS 设计变量，深色主题）

/// 页面基础底色 `--dsw-static-neutral-bluish-950: rgb(21,21,23)`
let guiBgColor = NSColor(calibratedRed: 21/255.0, green: 21/255.0, blue: 23/255.0, alpha: 1)
/// 页面上浮层级色 `--dsw-static-neutral-bluish-900: rgb(27,27,28)`
let guiLayerColor = NSColor(calibratedRed: 27/255.0, green: 27/255.0, blue: 28/255.0, alpha: 1)

/// 将图片重着色（保留 alpha 形状，替换颜色）
func tinted(_ img: NSImage, with color: NSColor) -> NSImage {
    let out = NSImage(size: img.size)
    out.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         NSToolbarDelegate, WKNavigationDelegate {

    enum State { case starting, connecting, ready, failed, stopped }

    private let server = ServerManager.shared
    private var window: NSWindow!
    private var webView: WKWebView!
    private var panel: NSView!
    private var panelTop: NSLayoutConstraint!
    private var panelLeading: NSLayoutConstraint!
    private var panelTrailing: NSLayoutConstraint!
    private var panelBottom: NSLayoutConstraint!
    private var overlay: NSView!
    private var spinner: NSProgressIndicator!
    private var messageLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var logScroll: NSScrollView!
    private var logView: NSTextView!
    private var whaleView: NSImageView!
    private var restartButton: NSButton!
    private var openBrowserButton: NSButton!
    private var statusDot: NSImageView!
    private var statusLabel: NSTextField!
    private var statusBar: NSView!

    private var state: State = .starting
    private var starting = false
    private var quitting = false
    private var logShown = true

    private var openInBrowserItem: NSMenuItem?
    private var reloadPageItem: NSMenuItem?
    private var restartServerItem: NSMenuItem?
    private var keepOnQuitItem: NSMenuItem?
    private var loginItem: NSMenuItem?

    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例：已有实例则激活它并退出
        if let existing = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0 != .current
        }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        server.onProcessExit = { [weak self] in self?.handleServerExit() }
        buildMenu()
        buildWindow()
        startPipeline()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        if server.ownsProcess && !server.keepServerOnQuit {
            server.stopServer()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        if server.ownsProcess {
            server.stopServer()
        }
    }

    // MARK: 菜单

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 DSH", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 DSH", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 DSH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
        editItem.submenu = editMenu

        let serverItem = NSMenuItem()
        main.addItem(serverItem)
        let serverMenu = NSMenu(title: "服务器")
        openInBrowserItem = serverMenu.addItem(withTitle: "在浏览器中打开", action: #selector(openInBrowser), keyEquivalent: "o")
        openInBrowserItem?.target = self
        reloadPageItem = serverMenu.addItem(withTitle: "刷新页面", action: #selector(reloadPage), keyEquivalent: "r")
        reloadPageItem?.target = self
        restartServerItem = serverMenu.addItem(withTitle: "重新启动服务", action: #selector(restartServer), keyEquivalent: "R")
        restartServerItem?.target = self
        serverMenu.addItem(.separator())
        keepOnQuitItem = serverMenu.addItem(withTitle: "退出时保留服务进程", action: #selector(toggleKeepOnQuit), keyEquivalent: "")
        keepOnQuitItem?.target = self
        keepOnQuitItem?.state = server.keepServerOnQuit ? .on : .off
        serverMenu.addItem(withTitle: "端口设置…", action: #selector(portSettings), keyEquivalent: "")
            .target = self
        if #available(macOS 13.0, *) {
            loginItem = serverMenu.addItem(withTitle: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
            loginItem?.target = self
            refreshLoginItemState()
        }
        serverItem.submenu = serverMenu

        NSApp.mainMenu = main
    }

    // MARK: 窗口

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "DeepSeek Harness"
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("DSHLauncherMainWindow")

        // 原生深色外观 + 页面同款底色：DSH 页面强制暗色主题（#151517），
        // 窗口底色与页面对齐后，圆角面板看起来与页面无缝融合
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = guiBgColor
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none

        let content = window.contentView!

        // 圆角浮层面板：页面悬浮在窗口内（Arc / Warp 风格）
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        self.panel = panel

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(webView)

        // 底部状态栏（面板内 footer，页面层级色 + 发丝分隔线）
        let statusBar = NSView()
        statusBar.wantsLayer = true
        statusBar.layer?.backgroundColor = guiLayerColor.cgColor
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(statusBar)
        self.statusBar = statusBar

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(hairline)

        statusDot = NSImageView()
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.contentTintColor = .systemOrange
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusDot)

        statusLabel = NSTextField(labelWithString: "正在启动…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

        // 图标化日志按钮
        let logBtn = NSButton()
        logBtn.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "日志")
        logBtn.imagePosition = .imageOnly
        logBtn.bezelStyle = .inline
        logBtn.controlSize = .small
        logBtn.contentTintColor = .secondaryLabelColor
        logBtn.toolTip = "显示或隐藏日志 (⌘L)"
        logBtn.target = self
        logBtn.action = #selector(toggleLog)
        logBtn.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(logBtn)

        panelTop = panel.topAnchor.constraint(equalTo: content.topAnchor, constant: 8)
        panelLeading = panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10)
        panelTrailing = panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10)
        panelBottom = panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)

        NSLayoutConstraint.activate([
            panelTop, panelLeading, panelTrailing, panelBottom,

            webView.topAnchor.constraint(equalTo: panel.topAnchor),
            webView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 30),

            hairline.topAnchor.constraint(equalTo: statusBar.topAnchor),
            hairline.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),

            statusDot.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusDot.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 10),
            statusDot.heightAnchor.constraint(equalToConstant: 10),

            statusLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: logBtn.leadingAnchor, constant: -12),

            logBtn.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            logBtn.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            logBtn.widthAnchor.constraint(equalToConstant: 26),
        ])

        buildOverlay()

        let toolbar = NSToolbar(identifier: "DSHMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // 紧凑型 unified 工具栏：图标与红绿灯同一高度、同样原生质感（Safari/邮件风格）
        window.toolbarStyle = .unifiedCompact

        // 全屏时收起面板边距，满屏无边框观感
        NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.setPanelFloating(false)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                               object: window, queue: .main) { [weak self] _ in
            self?.setPanelFloating(true)
        }

        server.log.onAppend = { [weak self] in self?.refreshLog() }
        refreshLog()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setPanelFloating(_ floating: Bool) {
        panelTop.constant = floating ? 8 : 0
        panelLeading.constant = floating ? 10 : 0
        panelTrailing.constant = floating ? -10 : 0
        panelBottom.constant = floating ? -10 : 0
        panel.layer?.cornerRadius = floating ? 10 : 0
        panel.layer?.borderWidth = floating ? 1 : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func buildOverlay() {
        let ov = NSView()
        ov.wantsLayer = true
        ov.layer?.backgroundColor = guiBgColor.cgColor
        ov.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(ov, positioned: .above, relativeTo: webView)
        overlay = ov

        // 品牌鲸鱼（白色，从打包的 whale.svg 矢量渲染）
        whaleView = NSImageView()
        whaleView.imageScaling = .scaleProportionallyUpOrDown
        whaleView.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(whaleView)
        if let url = Bundle.main.url(forResource: "whale", withExtension: "svg"),
           let whale = NSImage(contentsOf: url) {
            whale.size = NSSize(width: 64, height: 64)
            whaleView.image = tinted(whale, with: .white)
        }

        messageLabel = NSTextField(labelWithString: "正在启动 DeepSeek Harness 服务…")
        messageLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(messageLabel)

        detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(detailLabel)

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .large
        spinner.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(spinner)

        openBrowserButton = NSButton(title: "在浏览器中打开", target: self, action: #selector(openInBrowser))
        restartButton = NSButton(title: "重新启动服务", target: self, action: #selector(restartServer))
        let btnRow = NSStackView(views: [openBrowserButton, restartButton])
        btnRow.orientation = .horizontal
        btnRow.spacing = 12
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(btnRow)

        // 圆角日志卡片
        let logCard = NSView()
        logCard.wantsLayer = true
        logCard.layer?.cornerRadius = 8
        logCard.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        logCard.layer?.borderWidth = 1
        logCard.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        logCard.translatesAutoresizingMaskIntoConstraints = false
        ov.addSubview(logCard)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logCard.addSubview(scroll)
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 160))
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textColor = .secondaryLabelColor
        tv.backgroundColor = .clear
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 200, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 10, height: 8)
        scroll.documentView = tv
        logView = tv
        logScroll = scroll

        let cardTop = logCard.topAnchor.constraint(greaterThanOrEqualTo: btnRow.bottomAnchor, constant: 20)
        cardTop.priority = NSLayoutConstraint.Priority(999)
        let cardHeight = logCard.heightAnchor.constraint(equalToConstant: 170)
        cardHeight.priority = NSLayoutConstraint.Priority(750)

        NSLayoutConstraint.activate([
            ov.topAnchor.constraint(equalTo: panel.topAnchor),
            ov.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            ov.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            ov.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            whaleView.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            whaleView.centerYAnchor.constraint(equalTo: ov.centerYAnchor, constant: -64),
            whaleView.widthAnchor.constraint(equalToConstant: 64),
            whaleView.heightAnchor.constraint(equalToConstant: 64),

            messageLabel.topAnchor.constraint(equalTo: whaleView.bottomAnchor, constant: 14),
            messageLabel.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ov.leadingAnchor, constant: 40),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: ov.trailingAnchor, constant: -40),

            spinner.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 18),
            spinner.centerXAnchor.constraint(equalTo: ov.centerXAnchor),

            detailLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            detailLabel.centerXAnchor.constraint(equalTo: ov.centerXAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ov.leadingAnchor, constant: 60),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: ov.trailingAnchor, constant: -60),

            btnRow.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 16),
            btnRow.centerXAnchor.constraint(equalTo: ov.centerXAnchor),

            cardTop,
            logCard.leadingAnchor.constraint(equalTo: ov.leadingAnchor, constant: 16),
            logCard.trailingAnchor.constraint(equalTo: ov.trailingAnchor, constant: -16),
            logCard.bottomAnchor.constraint(equalTo: ov.bottomAnchor, constant: -16),
            logCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            cardHeight,

            scroll.topAnchor.constraint(equalTo: logCard.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: logCard.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: logCard.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: logCard.bottomAnchor),
        ])
    }

    // MARK: 启动管线

    private func startPipeline() {
        guard !starting else { return }
        starting = true
        state = .starting
        overlay.isHidden = false
        spinner.startAnimation(nil)
        messageLabel.stringValue = "正在启动 DeepSeek Harness 服务…"
        detailLabel.stringValue = "正在检查 http://127.0.0.1:\(server.port) …"
        setStatus(.starting, text: "正在启动…")
        server.log.append("\n—— 启动 ——\n")

        let port = server.port
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var result: ServerManager.ProbeResult = .unreachable
            let sem = DispatchSemaphore(value: 0)
            self.server.probe(port: port) { result = $0; sem.signal() }
            sem.wait()
            DispatchQueue.main.async {
                switch result {
                case .dshRunning:
                    self.server.ownsProcess = false
                    self.attachExisting()
                case .otherServer:
                    self.fail("端口 \(port) 已被其他程序占用，请更换端口（服务器 → 端口设置…）。")
                case .unreachable:
                    self.spawnServer()
                }
            }
        }
    }

    private func spawnServer() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            guard let npx = self.server.resolveNpx() else {
                DispatchQueue.main.async {
                    self.fail("未找到 npx。请先安装 Node.js（推荐 brew install node），然后重新启动本 App。")
                }
                return
            }
            self.server.log.append("使用 npx：\(npx)\n")
            let port = self.server.port
            let result = self.server.spawn(npx: npx, port: port)
            DispatchQueue.main.async {
                switch result {
                case .failure(let err):
                    self.fail(err.message)
                case .success:
                    self.state = .connecting
                    self.messageLabel.stringValue = "服务进程已启动，正在等待就绪…"
                    self.detailLabel.stringValue = "首次运行可能需要下载 dsh 包，请稍候。"
                    self.setStatus(.connecting, text: "正在连接 http://127.0.0.1:\(port) …")
                    self.server.waitUntilReady(port: port, timeout: 150,
                        progress: { sec in
                            DispatchQueue.main.async {
                                self.detailLabel.stringValue = "等待服务就绪… \(sec)s"
                            }
                        },
                        completion: { ready in
                            DispatchQueue.main.async {
                                if ready { self.attachStarted() }
                                else { self.fail("服务启动失败或超时，请点击「日志」查看详情。") }
                            }
                        })
                }
            }
        }
    }

    private func attachStarted() {
        starting = false
        state = .ready
        overlay.isHidden = true
        spinner.stopAnimation(nil)
        setStatus(.ready, text: "服务运行中 · http://127.0.0.1:\(server.port)")
        loadWeb()
    }

    private func attachExisting() {
        starting = false
        state = .ready
        overlay.isHidden = true
        spinner.stopAnimation(nil)
        setStatus(.ready, text: "已连接运行中的服务 · http://127.0.0.1:\(server.port)")
        loadWeb()
    }

    private func loadWeb() {
        webView.load(URLRequest(url: server.serverURL))
    }

    private func fail(_ msg: String) {
        starting = false
        state = .failed
        spinner.stopAnimation(nil)
        messageLabel.stringValue = "启动失败"
        detailLabel.stringValue = msg
        setStatus(.failed, text: msg)
        updateButtons()
    }

    private func handleServerExit() {
        guard !starting, !quitting else { return }
        guard state == .ready || state == .connecting else { return }
        state = .stopped
        overlay.isHidden = false
        spinner.stopAnimation(nil)
        messageLabel.stringValue = "服务已停止"
        detailLabel.stringValue = "dsh web 进程已退出。点击「重新启动服务」恢复，或先在终端排查。"
        setStatus(.stopped, text: "服务已停止")
    }

    // MARK: 状态 UI

    private func setStatus(_ s: State, text: String) {
        state = s
        statusLabel.stringValue = text
        switch s {
        case .ready: statusDot.contentTintColor = .systemGreen
        case .starting, .connecting: statusDot.contentTintColor = .systemOrange
        case .failed, .stopped: statusDot.contentTintColor = .systemRed
        }
        updateButtons()
    }

    private func updateButtons() {
        let ready = state == .ready
        let busy = state == .starting || state == .connecting
        restartButton.isEnabled = !busy
        openBrowserButton.isEnabled = ready
        restartServerItem?.isEnabled = !busy
        openInBrowserItem?.isEnabled = ready
        reloadPageItem?.isEnabled = ready
        toolbarItem(.reloadID)?.isEnabled = ready
        toolbarItem(.browserID)?.isEnabled = ready
        toolbarItem(.restartID)?.isEnabled = !busy
    }

    private func toolbarItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        window?.toolbar?.items.first { $0.itemIdentifier == id }
    }

    private func refreshLog() {
        logView.string = server.log.text
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: 动作

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func reloadPage() {
        webView.reload()
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(server.serverURL)
    }

    @objc private func restartServer() {
        guard !starting else { return }
        starting = true
        webView.stopLoading()
        server.stopServer()
        startPipeline()
    }

    @objc private func toggleLog() {
        logShown.toggle()
        logScroll.isHidden = !logShown
    }

    @objc private func copyURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(server.serverURL.absoluteString, forType: .string)
    }

    @objc private func toggleKeepOnQuit() {
        server.keepServerOnQuit.toggle()
        keepOnQuitItem?.state = server.keepServerOnQuit ? .on : .off
    }

    @available(macOS 13.0, *)
    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            do {
                try SMAppService.mainApp.register()
            } catch {
                let a = NSAlert()
                a.messageText = "无法设置登录时自动启动"
                a.informativeText = "登录启动要求 App 位于 /Applications 目录。请把 DSH.app 移到 /Applications 后重试。\n\n\(error.localizedDescription)"
                a.runModal()
            }
        }
        refreshLoginItemState()
    }

    @available(macOS 13.0, *)
    private func refreshLoginItemState() {
        loginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func portSettings() {
        let alert = NSAlert()
        alert.messageText = "服务端口"
        alert.informativeText = "dsh web 监听的端口（默认 3080），修改后立即重启服务。"
        let field = NSTextField(string: String(server.port))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Int(trimmed), (1...65535).contains(v) else {
            let a = NSAlert()
            a.messageText = "端口无效"
            a.informativeText = "请输入 1–65535 之间的数字。"
            a.runModal()
            return
        }
        if v != server.port {
            UserDefaults.standard.set(v, forKey: "port")
            restartServer()
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard state == .ready else { return }
        if server.ownsProcess, let p = server.process, !p.isRunning {
            handleServerExit()
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.reloadID, .browserID, .restartID, .logID, .urlID, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.reloadID, .browserID, .restartID, .flexibleSpace, .logID, .urlID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .reloadID:
            item.label = "刷新"
            item.toolTip = "刷新页面 (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新页面")
            item.action = #selector(reloadPage)
        case .browserID:
            item.label = "浏览器打开"
            item.toolTip = "在系统浏览器中打开 (⌘O)"
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "在浏览器中打开")
            item.action = #selector(openInBrowser)
        case .restartID:
            item.label = "重启服务"
            item.toolTip = "重新启动服务 (⇧⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.counterclockwise.circle", accessibilityDescription: "重新启动服务")
            item.action = #selector(restartServer)
        case .logID:
            item.label = "日志"
            item.toolTip = "显示或隐藏日志 (⌘L)"
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "显示或隐藏日志")
            item.action = #selector(toggleLog)
        case .urlID:
            item.label = "复制地址"
            item.toolTip = "复制服务地址"
            item.image = NSImage(systemSymbolName: "link", accessibilityDescription: "复制服务地址")
            item.action = #selector(copyURL)
        default:
            return nil
        }
        item.target = self
        item.isNavigational = false
        return item
    }
}

// MARK: - 无头自测（--selftest）

func runSelfTest() -> Never {
    let args = CommandLine.arguments
    var port = 3199
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let v = Int(args[i + 1]) {
        port = v
    }
    let sm = ServerManager.shared
    print("SELFTEST port=\(port)")

    guard let npx = sm.resolveNpx() else {
        print("SELFTEST FAIL: npx not found")
        exit(1)
    }
    print("SELFTEST npx=\(npx)")

    var probeResult: ServerManager.ProbeResult = .unreachable
    let sem0 = DispatchSemaphore(value: 0)
    sm.probe(port: port) { probeResult = $0; sem0.signal() }
    sem0.wait()
    switch probeResult {
    case .dshRunning:
        print("SELFTEST OK: server already running on port \(port)")
        exit(0)
    case .otherServer:
        print("SELFTEST FAIL: port \(port) occupied by another server")
        exit(1)
    case .unreachable:
        break
    }

    // 隔离 HOME，避免影响真实 profile；npm 缓存仍指向真实目录避免重新下载
    let tmp = NSTemporaryDirectory() + "dsh-selftest-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    sm.homeOverride = tmp
    defer { sm.homeOverride = nil }

    switch sm.spawn(npx: npx, port: port) {
    case .failure(let e):
        print("SELFTEST FAIL: spawn failed: \(e)")
        exit(1)
    case .success:
        break
    }

    let sem = DispatchSemaphore(value: 0)
    var ready = false
    sm.waitUntilReady(port: port, timeout: 150, progress: { sec in
        if sec % 5 == 0 { print("SELFTEST waiting \(sec)s…") }
    }) { ready = $0; sem.signal() }
    sem.wait()

    guard ready else {
        print("SELFTEST FAIL: server not ready. log tail:\n" + sm.log.lastLines(40))
        sm.stopServer()
        exit(1)
    }
    print("SELFTEST READY http://127.0.0.1:\(port)")

    sm.stopServer()
    print("SELFTEST STOPPED OK")
    exit(0)
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
