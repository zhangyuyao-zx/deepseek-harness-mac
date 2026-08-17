import AppKit

// MARK: - 数据模型

struct UsageRow {
    let title: String
    let inputTokens: Int64
    let outputTokens: Int64
    let cacheReadTokens: Int64
}

// MARK: - 数据获取:本地 token 用量 + DeepSeek API 余额

enum UsageFetcher {
    /// 从 dsh 的 session_projcache.json 聚合每个会话的 token 用量
    static func loadLocalUsage() -> [UsageRow] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/storages/session_projcache.json")
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tables = root["tables"] as? [String: Any],
              let sessions = tables["sessions"] as? [String: Any] else { return [] }
        var rows: [UsageRow] = []
        for (_, rawSession) in sessions {
            guard let session = rawSession as? [String: Any],
                  let tableRows = session["rows"] as? [String: Any] else { continue }
            let title = (tableRows["title"] as? [String: Any])?["val"] as? String ?? "（未命名会话）"
            guard let usage = (tableRows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any],
                  let totals = usage["totals"] as? [String: Any] else { continue }
            let input = totals["uncachedInputTokens"] as? Int64 ?? 0
            let output = totals["outputTokens"] as? Int64 ?? 0
            let cacheRead = totals["cacheReadTokens"] as? Int64 ?? 0
            if input == 0 && output == 0 && cacheRead == 0 { continue }
            rows.append(UsageRow(title: title, inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead))
        }
        rows.sort { $0.inputTokens + $0.outputTokens > $1.inputTokens + $1.outputTokens }
        return rows
    }

    /// 查找 DeepSeek API Key:环境变量 → 常见 .env → shell 配置文件 → 应用内保存的值
    static func discoverAPIKey(savedKey: String?) -> String? {
        if let key = savedKey, !key.isEmpty { return key }
        let env = ProcessInfo.processInfo.environment
        if let key = env["DEEPSEEK_API_KEY"], !key.isEmpty { return key }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".dsh/.env"),
            home.appendingPathComponent("Desktop/deepseek/.env"),
            home.appendingPathComponent(".env"),
        ]
        for file in candidates {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("DEEPSEEK_API_KEY=") {
                        let value = trimmed.dropFirst("DEEPSEEK_API_KEY=".count)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty { return value }
                    }
                }
            }
        }
        for profile in [".zshrc", ".zprofile", ".bash_profile"] {
            let file = home.appendingPathComponent(profile)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("DEEPSEEK_API_KEY") else { continue }
                if let range = trimmed.range(of: "DEEPSEEK_API_KEY\\s*=\\s*[\"']?([^\"'\\n]+)", options: .regularExpression),
                   let match = trimmed[range].split(separator: "=").last {
                    let value = match.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    /// 查询 DeepSeek 官方余额接口
    static func fetchBalance(apiKey: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
            completion(.failure(NSError(domain: "balance", code: 1, userInfo: [NSLocalizedDescriptionKey: "余额接口地址无效"])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "balance", code: 2, userInfo: [NSLocalizedDescriptionKey: "无响应"]))) }
                return
            }
            guard http.statusCode == 200, let data else {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "balance", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)：请检查 API Key 是否正确"]))) }
                return
            }
            do {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NSError(domain: "balance", code: 1)
                }
                let available = obj["is_available"] as? Bool ?? false
                guard available else {
                    DispatchQueue.main.async { completion(.failure(NSError(domain: "balance", code: 4, userInfo: [NSLocalizedDescriptionKey: "账户余额不可用"]))) }
                    return
                }
                let infos = obj["balance_infos"] as? [[String: Any]] ?? []
                let parts = infos.compactMap { info -> String? in
                    guard let currency = info["currency"] as? String,
                          let total = info["total_balance"] as? String else { return nil }
                    return "\(currency) \(total)"
                }
                let text = parts.isEmpty ? "可用（暂无余额明细）" : parts.joined(separator: "  ")
                DispatchQueue.main.async { completion(.success(text)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(NSError(domain: "balance", code: 5, userInfo: [NSLocalizedDescriptionKey: "余额数据解析失败"]))) }
            }
        }.resume()
    }
}

// MARK: - 用量与余额窗口

final class UsagePanelController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private var window: NSWindow?
    private var rows: [UsageRow] = []
    private let tableView = NSTableView()
    private let balanceLabel = NSTextField(labelWithString: "未查询")
    private let totalLabel = NSTextField(labelWithString: "")
    private let keyField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let kSavedKey = "deepseekAPIKey"

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshUsage()
        refreshBalance()
    }

    private func buildWindow() {
        let rect = NSRect(x: 0, y: 0, width: 640, height: 520)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "用量与余额"
        win.center()
        win.isReleasedWhenClosed = false
        window = win

        let content = NSView(frame: win.contentView!.bounds)
        win.contentView = content

        let title = NSTextField(labelWithString: "DeepSeek API 余额")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        balanceLabel.font = .systemFont(ofSize: 15, weight: .medium)
        balanceLabel.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "刷新余额", target: self, action: #selector(refreshBalance))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let platformLink = NSButton(title: "打开 DeepSeek 平台 ↗", target: self, action: #selector(openPlatform))
        platformLink.bezelStyle = .inline
        platformLink.controlSize = .small
        platformLink.translatesAutoresizingMaskIntoConstraints = false

        keyField.placeholderString = "未找到 API Key 时，可在此粘贴 sk-... 后点保存"
        keyField.font = .systemFont(ofSize: 11)
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.delegate = nil

        let saveKeyButton = NSButton(title: "保存 Key", target: self, action: #selector(saveKey))
        saveKeyButton.bezelStyle = .rounded
        saveKeyButton.controlSize = .small
        saveKeyButton.translatesAutoresizingMaskIntoConstraints = false

        let usageTitle = NSTextField(labelWithString: "本地 Token 用量（全部会话）")
        usageTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        usageTitle.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let columns: [(String, CGFloat)] = [("会话", 260), ("输入", 90), ("输出", 90), ("缓存读取", 100)]
        for (name, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            col.title = name
            col.width = width
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        totalLabel.font = .systemFont(ofSize: 12, weight: .medium)
        totalLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(balanceLabel)
        content.addSubview(refreshButton)
        content.addSubview(platformLink)
        content.addSubview(keyField)
        content.addSubview(saveKeyButton)
        content.addSubview(divider)
        content.addSubview(usageTitle)
        content.addSubview(statusLabel)
        content.addSubview(scroll)
        content.addSubview(totalLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            balanceLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            balanceLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            refreshButton.centerYAnchor.constraint(equalTo: balanceLabel.centerYAnchor),
            refreshButton.leadingAnchor.constraint(equalTo: balanceLabel.trailingAnchor, constant: 16),
            platformLink.centerYAnchor.constraint(equalTo: balanceLabel.centerYAnchor),
            platformLink.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
            keyField.topAnchor.constraint(equalTo: balanceLabel.bottomAnchor, constant: 8),
            keyField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            keyField.trailingAnchor.constraint(equalTo: saveKeyButton.leadingAnchor, constant: -8),
            saveKeyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            saveKeyButton.centerYAnchor.constraint(equalTo: keyField.centerYAnchor),
            divider.topAnchor.constraint(equalTo: keyField.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            usageTitle.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            usageTitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: usageTitle.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: usageTitle.trailingAnchor, constant: 12),
            scroll.topAnchor.constraint(equalTo: usageTitle.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: totalLabel.topAnchor, constant: -8),
            totalLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            totalLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        let saved = UserDefaults.standard.string(forKey: kSavedKey)
        if let saved { keyField.stringValue = saved }
    }

    // MARK: 刷新

    func refreshUsage() {
        rows = UsageFetcher.loadLocalUsage()
        tableView.reloadData()
        let totalInput = rows.reduce(0) { $0 + $1.inputTokens }
        let totalOutput = rows.reduce(0) { $0 + $1.outputTokens }
        let totalCache = rows.reduce(0) { $0 + $1.cacheReadTokens }
        totalLabel.stringValue = "总计：\(rows.count) 个会话 · 输入 \(Self.fmt(totalInput)) · 输出 \(Self.fmt(totalOutput)) · 缓存读取 \(Self.fmt(totalCache))"
        statusLabel.stringValue = "数据来自本机 dsh 会话缓存（~/.dsh/storages）"
    }

    @objc func refreshBalance() {
        let saved = UserDefaults.standard.string(forKey: kSavedKey)
        guard let key = UsageFetcher.discoverAPIKey(savedKey: saved) else {
            balanceLabel.stringValue = "未找到 API Key"
            statusLabel.stringValue = "请在下方粘贴 DeepSeek API Key（sk-...）并保存"
            return
        }
        balanceLabel.stringValue = "查询中…"
        statusLabel.stringValue = "正在请求 api.deepseek.com/user/balance"
        UsageFetcher.fetchBalance(apiKey: key) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                self.balanceLabel.stringValue = text
                self.statusLabel.stringValue = "余额来自 DeepSeek 官方接口"
            case .failure(let error):
                self.balanceLabel.stringValue = "查询失败"
                self.statusLabel.stringValue = error.localizedDescription
            }
        }
    }

    @objc func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusLabel.stringValue = "请输入 API Key"
            return
        }
        UserDefaults.standard.set(key, forKey: kSavedKey)
        statusLabel.stringValue = "Key 已保存，正在查询余额…"
        refreshBalance()
    }

    @objc func openPlatform() {
        if let url = URL(string: "https://platform.deepseek.com/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 表格

    static func fmt(_ n: Int64) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let id = NSUserInterfaceItemIdentifier("cell")
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "会话": text = entry.title
        case "输入": text = Self.fmt(entry.inputTokens)
        case "输出": text = Self.fmt(entry.outputTokens)
        case "缓存读取": text = Self.fmt(entry.cacheReadTokens)
        default: text = ""
        }
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView,
           let existing = reused.textField {
            field = existing
        } else {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            field = label
        }
        field.stringValue = text
        field.alignment = tableColumn?.identifier.rawValue == "会话" ? .left : .right
        return field.superview
    }
}
