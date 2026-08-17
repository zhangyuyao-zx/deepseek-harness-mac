import AppKit
import Carbon
import Darwin
import ServiceManagement
import UserNotifications
import WebKit

// MARK: - 常量

var kPort: UInt16 = 3080
var kServerURL: URL { URL(string: "http://127.0.0.1:\(kPort)/")! }
let kAppName = "DeepSeek 助手"

/// 端口解析：命令行 --port N > bundle Resources/port.conf > 环境变量 DSH_PORT > UserDefaults 的 port > 默认 3080
func resolvePort() -> UInt16 {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count,
       let p = UInt16(args[i + 1]), p > 0 {
        return p
    }
    if let url = Bundle.main.url(forResource: "port", withExtension: "conf"),
       let content = try? String(contentsOf: url, encoding: .utf8),
       let p = UInt16(content.trimmingCharacters(in: .whitespacesAndNewlines)), p > 0 {
        return p
    }
    if let s = ProcessInfo.processInfo.environment["DSH_PORT"], let p = UInt16(s), p > 0 {
        return p
    }
    let ud = UserDefaults.standard.integer(forKey: "port")
    if ud > 0 && ud < 65536 { return UInt16(ud) }
    return 3080
}

let kDSHBinaryCandidates: [String] = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [
        "/opt/homebrew/bin/dsh",
        "/usr/local/bin/dsh",
        home + "/.npm-global/bin/dsh",
    ]
}()

let kLogDirURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs")
    .appendingPathComponent("DeepSeek助手")

let kUserDefaultsWorkspaceKey = "workspacePath"
let kAppPidFile = kLogDirURL.appendingPathComponent("app.pid")

/// 应用自身日志（写到 ~/Library/Logs/DeepSeek助手/app.log，便于排查）
func appLog(_ message: String) {
    let logURL = kLogDirURL.appendingPathComponent("app.log")
    try? FileManager.default.createDirectory(at: kLogDirURL, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(message)\n"
    if let data = line.data(using: .utf8) {
        if let fh = try? FileHandle(forWritingTo: logURL) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

func defaultWorkspaceURL() -> URL {
    var url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/deepseek")
    if !FileManager.default.fileExists(atPath: url.path) {
        url = FileManager.default.homeDirectoryForCurrentUser
    }
    return url
}

func configuredWorkspaceURL() -> URL {
    if let p = UserDefaults.standard.string(forKey: kUserDefaultsWorkspaceKey),
       !p.isEmpty {
        return URL(fileURLWithPath: p)
    }
    return defaultWorkspaceURL()
}

// MARK: - dsh 服务生命周期管理

final class ServerManager {
    private(set) var process: Process?
    private(set) var startedByUs = false
    var onChildExit: ((Int32) -> Void)?

    func findDSHBinary() -> String? {
        for p in kDSHBinaryCandidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["dsh"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    /// 服务器是否真的能响应 HTTP（任何状态码都算）。
    func isResponding(timeout: TimeInterval = 3.0, completion: @escaping (Bool) -> Void) {
        var req = URLRequest(url: kServerURL)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let task = URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse) != nil
            DispatchQueue.main.async { completion(ok) }
        }
        task.resume()
    }

    func listenerPIDs() -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
        proc.arguments = ["-ti", ":\(kPort)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 定位 node 可执行文件（GUI 启动的 app 没有完整 PATH，dsh 的 shebang 依赖它）
    func findNodeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            home + "/.npm-global/bin/node",
        ]
        // nvm / fnm 安装的 node
        let nvmDir = home + "/.nvm/versions/node"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            for entry in entries.sorted(by: >) {
                candidates.append(nvmDir + "/" + entry + "/bin/node")
            }
        }
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    @discardableResult
    func start(workspace: URL) -> Bool {
        guard let dsh = findDSHBinary() else { return false }
        stop()

        let proc = Process()
        // 优先用解析出的 node 直接执行 dsh 的 bin.js，绕开 shebang 对 PATH 的依赖
        if let node = findNodeBinary() {
            proc.executableURL = URL(fileURLWithPath: node)
            proc.arguments = [dsh, "web", "--port", "\(kPort)"]
        } else {
            proc.executableURL = URL(fileURLWithPath: dsh)
            proc.arguments = ["web", "--port", "\(kPort)"]
        }
        var env = ProcessInfo.processInfo.environment
        // 清掉其他 App（如 WorkBuddy）注入的拦截器，保证干净环境
        env.removeValue(forKey: "NODE_OPTIONS")
        env.removeValue(forKey: "BASH_ENV")
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        // 丰富 PATH，保证 dsh 内部再 spawn 的 node 工具可用
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                         home + "/.npm-global/bin"]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraDirs + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        proc.environment = env
        proc.currentDirectoryURL = workspace

        try? FileManager.default.createDirectory(at: kLogDirURL, withIntermediateDirectories: true)
        let logURL = kLogDirURL.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        // stdout/stderr 直接落到日志文件:服务进程完全独立于应用生命周期,
        // 应用退出后任务(含子代理)继续在后台运行
        if let logFH = try? FileHandle(forWritingTo: logURL) {
            logFH.seekToEndOfFile()
            proc.standardOutput = logFH
            proc.standardError = logFH
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                if let self, self.process === p {
                    self.startedByUs = false
                    self.onChildExit?(p.terminationStatus)
                }
            }
        }

        do {
            try proc.run()
        } catch {
            return false
        }
        process = proc
        startedByUs = true
        appLog("spawned dsh pid=\(proc.processIdentifier), workspace=\(workspace.path)")
        return true
    }

    func stop() {
        if let p = process, startedByUs, p.isRunning {
            p.terminate()
        }
        startedByUs = false
        process = nil
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    let server = ServerManager()
    var readinessTimer: Timer?
    var statusItem: NSStatusItem?
    var launchAtLoginItem: NSMenuItem?
    var hotKeyHandlerRef: EventHandlerRef?
    var hotKeyRef: EventHotKeyRef?
    var spawnedReadyNotified = false
    var fullShutdown = false
    let usagePanel = UsagePanelController()
    // MARK: 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例:基于 PID 文件判断(不依赖 LaunchServices 注册,避免残留导致新实例秒退)
        let myPid = ProcessInfo.processInfo.processIdentifier
        if let data = try? Data(contentsOf: kAppPidFile),
           let text = String(data: data, encoding: .utf8),
           let otherPid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           otherPid != myPid,
           kill(otherPid, 0) == 0 {
            // 已有实例存活:激活它并退出
            NSRunningApplication(processIdentifier: otherPid)?.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        try? FileManager.default.createDirectory(at: kLogDirURL, withIntermediateDirectories: true)
        try? String(myPid).write(to: kAppPidFile, atomically: true, encoding: .utf8)
        appLog("launch, workspace=" + configuredWorkspaceURL().path)
        buildMenu()
        buildWindow()
        setupNotifications()
        installGlobalHotKey()
        buildStatusItem()
        startOrAttach()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 关闭窗口 = 收进菜单栏,保持服务和会话在线
        NSApp.hide(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLog("will terminate, fullShutdown=\(fullShutdown) (startedByUs=\(server.startedByUs))")
        if !fullShutdown {
            appLog("server kept running in background (tasks continue)")
        } else {
            server.stop()
        }
        // 清理 PID 文件(仅当它还指向自己)
        if let data = try? Data(contentsOf: kAppPidFile),
           let text = String(data: data, encoding: .utf8),
           pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) == ProcessInfo.processInfo.processIdentifier {
            try? FileManager.default.removeItem(at: kAppPidFile)
        }
        server.stop()
        if let ref = hotKeyHandlerRef { RemoveEventHandler(ref) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // MARK: 窗口

    func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 860)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = kAppName
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 940, height: 620)
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.center()
        window.setFrameAutosaveName("DeepSeekAssistantMainWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: window.contentView!.bounds)
        window.contentView = content

        // 顶部通栏（透明标题栏下的视觉条）
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        let title = NSTextField(labelWithString: kAppName)
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(title)

        // WebView
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(web)
        webView = web

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 38),
            title.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            web.topAnchor.constraint(equalTo: bar.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        showLoadingPage()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 菜单

    func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 DeepSeek 助手",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let usageItem = NSMenuItem(title: "用量与余额…", action: #selector(showUsagePanel), keyEquivalent: "")
        usageItem.target = self
        appMenu.addItem(usageItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 DeepSeek 助手",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(NSMenuItem.separator())
        let quitSoft = NSMenuItem(title: "退出 DeepSeek 助手（服务继续后台运行）",
                                 action: #selector(quitKeepingServer), keyEquivalent: "q")
        quitSoft.target = self
        appMenu.addItem(quitSoft)
        let quitFull = NSMenuItem(title: "退出并停止服务（终止所有进行中的任务）",
                                 action: #selector(quitStoppingServer), keyEquivalent: "")
        quitFull.target = self
        appMenu.addItem(quitFull)

        // 编辑菜单:WKWebView 的 ⌘C/⌘V/⌘X/⌘A/⌘Z 快捷键需要菜单项路由
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "视图")
        viewItem.submenu = viewMenu
        viewMenu.addItem(menuItem("重新载入", #selector(reloadPage), "r"))
        viewMenu.addItem(menuItem("后退", #selector(goBack), "["))
        viewMenu.addItem(menuItem("前进", #selector(goForward), "]"))
        viewMenu.addItem(menuItem("实际大小", #selector(resetZoom), "0"))

        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "前往")
        goItem.submenu = goMenu
        goMenu.addItem(menuItem("重新连接服务", #selector(reconnect), "", []))
        goMenu.addItem(menuItem("在浏览器中打开", #selector(openInBrowser), "o",
                                NSEvent.ModifierFlags.command.union(.shift)))
        goMenu.addItem(menuItem("打开服务器日志", #selector(openServerLog), "", []))

        let settingsItem = NSMenuItem()
        mainMenu.addItem(settingsItem)
        let settingsMenu = NSMenu(title: "设置")
        settingsItem.submenu = settingsMenu
        settingsMenu.addItem(menuItem("更改工作目录…", #selector(chooseWorkspace), "", []))

        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        winMenu.addItem(menuItem("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"))
        winMenu.addItem(menuItem("缩放", #selector(NSWindow.performZoom(_:)), "", []))
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    func menuItem(_ title: String, _ action: Selector, _ key: String,
                  _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: 原生体验:全局热键 / 菜单栏 / 通知 / 开机自启

    func installGlobalHotKey() {
        // ⌥Space 唤起/隐藏窗口(与 Codex 一致)
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, _, _ in
            DispatchQueue.main.async { delegate.toggleWindow() }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventSpec, nil, &hotKeyHandlerRef)
        let hotKeyID = EventHotKeyID(signature: OSType(0x44534831), id: 1) // 'DSH1'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr {
            appLog("global hotkey registered: option+space")
        } else {
            appLog("global hotkey registration failed: \(status)")
        }
    }

    @objc func showUsagePanel() {
        usagePanel.show()
    }

    @objc func quitKeepingServer() {
        fullShutdown = false
        NSApp.terminate(nil)
    }

    @objc func quitStoppingServer() {
        fullShutdown = true
        NSApp.terminate(nil)
    }

    @objc func toggleWindow() {
        guard let window else { return }
        if window.isVisible && NSApp.isActive {
            NSApp.hide(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = statusIcon()
        }
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "显示/隐藏窗口  ⌥Space", action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem("重新载入", #selector(reloadPage), "r"))
        menu.addItem(menuItem("在浏览器中打开", #selector(openInBrowser), "", []))
        menu.addItem(NSMenuItem.separator())
        let launch = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = launchAtLoginEnabled() ? .on : .off
        menu.addItem(launch)
        menu.addItem(NSMenuItem.separator())
        let usageItem = NSMenuItem(title: "用量与余额…", action: #selector(showUsagePanel), keyEquivalent: "")
        usageItem.target = self
        menu.addItem(usageItem)
        menu.addItem(NSMenuItem.separator())
        let quitSoft = NSMenuItem(title: "退出（服务继续后台运行）", action: #selector(quitKeepingServer), keyEquivalent: "q")
        quitSoft.target = self
        menu.addItem(quitSoft)
        let quitFull = NSMenuItem(title: "退出并停止服务（终止进行中的任务）", action: #selector(quitStoppingServer), keyEquivalent: "")
        quitFull.target = self
        menu.addItem(quitFull)
        item.menu = menu
        statusItem = item
        launchAtLoginItem = launch
    }

    func statusIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18))
        img.lockFocus()
        NSColor.black.setFill()
        let whale = NSBezierPath()
        whale.move(to: NSPoint(x: 3, y: 10))
        whale.curve(to: NSPoint(x: 4.5, y: 7.5), controlPoint1: NSPoint(x: 2.5, y: 8.5), controlPoint2: NSPoint(x: 3.5, y: 7.5))
        whale.curve(to: NSPoint(x: 11, y: 5.5), controlPoint1: NSPoint(x: 6.5, y: 6), controlPoint2: NSPoint(x: 9, y: 5))
        whale.curve(to: NSPoint(x: 14.8, y: 6.8), controlPoint1: NSPoint(x: 13, y: 5.4), controlPoint2: NSPoint(x: 14.4, y: 6))
        whale.line(to: NSPoint(x: 16.8, y: 5.2))
        whale.line(to: NSPoint(x: 15.1, y: 7.9))
        whale.line(to: NSPoint(x: 16.4, y: 10.8))
        whale.line(to: NSPoint(x: 13.7, y: 9.4))
        whale.curve(to: NSPoint(x: 4.5, y: 12), controlPoint1: NSPoint(x: 10.5, y: 11.6), controlPoint2: NSPoint(x: 7, y: 12.6))
        whale.curve(to: NSPoint(x: 3, y: 10), controlPoint1: NSPoint(x: 3.5, y: 11.8), controlPoint2: NSPoint(x: 2.7, y: 11))
        whale.close()
        whale.fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            appLog("notification permission granted=\(granted)")
        }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func launchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                appLog("launch-at-login disabled")
            } else {
                try SMAppService.mainApp.register()
                appLog("launch-at-login enabled")
            }
        } catch {
            appLog("launch-at-login toggle failed: \(error)")
            let alert = NSAlert()
            alert.messageText = "开机自启设置失败"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
        launchAtLoginItem?.state = launchAtLoginEnabled() ? .on : .off
    }

    // MARK: 启动 / 连接流程

    func startOrAttach() {
        showLoadingPage()
        // 连续探测 3 次（间隔 2s），避免把只是暂时繁忙的服务误判为僵尸
        probeServer { [weak self] alive in
            guard let self else { return }
            if alive {
                appLog("server already running, attach")
                self.finishAttach()
                return
            }
            self.handleDeadServer()
        }
    }

    func probeServer(_ completion: @escaping (Bool) -> Void) {
        // 长探测窗口(5 次 × 3s 超时 + 3s 间隔):宁可多等,不抢别人的服务
        var attempt = 0
        func next() {
            attempt += 1
            server.isResponding { ok in
                if ok {
                    completion(true)
                    return
                }
                if attempt >= 5 {
                    completion(false)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { next() }
            }
        }
        next()
    }

    func handleDeadServer() {
        let pids = server.listenerPIDs()
        if !pids.isEmpty {
            // 端口上有进程但无响应:绝不强制终止——它可能正在写会话日志
            appLog("port \(kPort) held by unresponsive pids \(pids); refuse to kill")
            showPortBlockedAlert()
            return
        }
        spawnServer()
    }

    func spawnServer() {
        let ws = configuredWorkspaceURL()
        appLog("spawning dsh, workspace=" + ws.path)
        if !server.start(workspace: ws) {
            showNoDSHAlert()
            return
        }
        server.onChildExit = { [weak self] status in
            self?.childExited(status)
        }
        pollUntilReady()
    }

    func pollUntilReady() {
        readinessTimer?.invalidate()
        var attempts = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { return }
            attempts += 1
            self.server.isResponding { ok in
                guard self.readinessTimer === t else { return }
                if ok {
                    t.invalidate()
                    self.readinessTimer = nil
                    self.finishAttach()
                } else if attempts >= 60 {
                    t.invalidate()
                    self.readinessTimer = nil
                    self.showLoadError()
                }
            }
        }
        readinessTimer = timer
    }

    func finishAttach() {
        appLog("attached, loading " + kServerURL.absoluteString)
        webView.load(URLRequest(url: kServerURL))
        // 只有「自己拉起服务并首次就绪」才通知,复用已有服务不打扰
        if server.startedByUs && !spawnedReadyNotified {
            spawnedReadyNotified = true
            notify("DeepSeek 助手已就绪", "服务已在本机启动，可以开始对话了。")
        }
    }

    func childExited(_ status: Int32) {
        notify("DeepSeek 服务已停止", "后台服务意外退出（退出码 \(status)）。")
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = "DeepSeek 服务已停止"
        alert.informativeText = "后台服务意外退出（退出码 \(status)）。\n\n最近日志：\n\(serverLogTail())"
        alert.addButton(withTitle: "重新启动")
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "退出")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startOrAttach()
        case .alertSecondButtonReturn:
            openServerLog()
        default:
            NSApp.terminate(nil)
        }
    }

    func serverLogTail(_ maxLen: Int = 1500) -> String {
        let logURL = kLogDirURL.appendingPathComponent("server.log")
        guard let data = try? Data(contentsOf: logURL), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return "（暂无日志）"
        }
        return String(text.suffix(maxLen))
    }

    func showPortBlockedAlert() {
        let pids = server.listenerPIDs().map(String.init).joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "端口 \(kPort) 被占用且无法自动清理"
        alert.informativeText = "该端口上的进程没有响应且未退出。\n\n请手动关闭占用进程（PID：\(pids)），或为应用配置其他端口（port.conf / UserDefaults 的 port）。"
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "退出")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            startOrAttach()
        case .alertSecondButtonReturn:
            openServerLog()
        default:
            NSApp.terminate(nil)
        }
    }

    func showNoDSHAlert() {
        let alert = NSAlert()
        alert.messageText = "未找到 dsh"
        alert.informativeText = "请先安装 DeepSeek Harness：\n\nnpm install -g @deepseek-ai/dsh\n\n或确认 dsh 位于 /opt/homebrew/bin、/usr/local/bin 或 ~/.npm-global/bin"
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: 页面状态

    func showLoadingPage() {
        let icon = loadingIconBase64()
        let iconHTML = icon.isEmpty
            ? "<div class=\"spinner\"></div>"
            : "<img class=\"logo\" src=\"data:image/png;base64,\(icon)\" alt=\"DeepSeek 助手\" />"
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;background:#10131c;display:flex;align-items:center;justify-content:center;height:100vh;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#8a93a8}
        .wrap{text-align:center}
        .logo{width:96px;height:96px;border-radius:24px;box-shadow:0 10px 36px rgba(0,0,0,.5);animation:pulse 1.6s ease-in-out infinite}
        .spinner{width:44px;height:44px;margin:0 auto 18px;border:3px solid rgba(120,140,255,.2);border-top-color:#5b7fff;border-radius:50%;animation:spin 1s linear infinite}
        @keyframes pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.07)}}
        @keyframes spin{to{transform:rotate(360deg)}}
        .t{margin-top:22px;font-size:16px;font-weight:600;color:#dbe2f0}
        .s{margin-top:6px;font-size:13px}
        </style></head><body><div class="wrap">
        \(iconHTML)
        <div class="t">正在启动 DeepSeek 助手…</div>
        <div class="s">首次启动需要几秒钟，请稍候</div>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// 从应用图标生成 base64 PNG(加载页展示)
    func loadingIconBase64() -> String {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png.base64EncodedString()
        }
        return ""
    }

    func showLoadError() {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;background:#10131c;display:flex;align-items:center;justify-content:center;height:100vh;font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#8a93a8;text-align:center}
        .t{font-size:16px;font-weight:600;color:#dbe2f0}
        .s{margin-top:8px;font-size:13px;line-height:1.7}
        </style></head><body><div>
        <div class="t">DeepSeek 服务启动超时</div>
        <div class="s">可在菜单「前往 → 重新连接服务」重试，<br>或「前往 → 打开服务器日志」查看原因。</div>
        </div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: WKWebView 代理

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        showLoadError()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = kAppName
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = kAppName
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    // MARK: 菜单动作

    @objc func reloadPage() { webView.reload() }
    @objc func goBack() { if webView.canGoBack { webView.goBack() } }
    @objc func goForward() { if webView.canGoForward { webView.goForward() } }
    @objc func resetZoom() { webView.setMagnification(1.0, centeredAt: .zero) }
    @objc func reconnect() { startOrAttach() }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(webView.url ?? kServerURL)
    }

    @objc func openServerLog() {
        let logURL = kLogDirURL.appendingPathComponent("server.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.open(kLogDirURL)
        }
    }

    @objc func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择 DeepSeek 助手的工作目录（当前：\(configuredWorkspaceURL().path)）"
        panel.directoryURL = configuredWorkspaceURL()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: kUserDefaultsWorkspaceKey)
        let alert = NSAlert()
        alert.messageText = "工作目录已更新"
        alert.informativeText = "新的工作目录将在下次启动助手时生效：\n\(url.path)"
        alert.runModal()
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
// 声明应用语言为简体中文:WKWebView 据此向网页报告 navigator.language,
// dsh GUI 的初始界面语言由此决定(否则默认跟随英文系统)
UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
UserDefaults.standard.set("zh-Hans", forKey: "AppleLocale")
kPort = resolvePort()
appLog("start, port=\(kPort), pid=\(ProcessInfo.processInfo.processIdentifier)")

// 优雅退出：收到 SIGTERM/SIGINT 时走正常终止流程（回收自启的 dsh 服务）
signal(SIGTERM) { _ in DispatchQueue.main.async {
    delegate.fullShutdown = true
    NSApp.terminate(nil)
} }
signal(SIGINT) { _ in DispatchQueue.main.async {
    delegate.fullShutdown = true
    NSApp.terminate(nil)
} }

app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
