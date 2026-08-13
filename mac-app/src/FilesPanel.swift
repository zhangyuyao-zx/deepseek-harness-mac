import AppKit

// MARK: - 数据模型

struct FileEntry {
    let url: URL
    let relativePath: String
    let size: Int64
    let modifiedAt: Date
}

// MARK: - dsh 路径编码与活跃会话追踪

/// dsh 的项目目录编码(与 dsh-session-persistence-jsonl 的 projectKey 一致)
func dshProjectKey(_ cwd: String) -> String {
    var readable = ""
    var separatorRun = false
    for ch in cwd {
        let ascii = ch.unicodeScalars.first?.value ?? 0
        if ch == "/" || ch == "\\" || ch == ":" {
            if !separatorRun { readable.append("-") }
            separatorRun = true
        } else if ascii >= 0x30 && ascii <= 0x39
            || ascii >= 0x41 && ascii <= 0x5A
            || ascii >= 0x61 && ascii <= 0x7A
            || ch == "." || ch == "_" || ch == "-" {
            readable.append(ch)
            separatorRun = false
        } else {
            readable.append(String(format: "~%04X", ascii))
            separatorRun = false
        }
    }
    let trimmed = readable.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return "--" + String((trimmed.isEmpty ? "root" : trimmed).prefix(251)) + "--"
}

struct ActiveSessionInfo {
    let sessionId: String
    let logURL: URL
    let createdAt: Date
}

/// 定位当前活跃会话(最新写入的会话日志)
final class ActiveSessionTracker {
    private var cached: ActiveSessionInfo?
    private var cachedAt: Date?

    func activeSession() -> ActiveSessionInfo? {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < 5 {
            return cached
        }
        cached = derive()
        cachedAt = Date()
        return cached
    }

    /// 按会话 id 定位会话目录(目录名=id;编码不一致时按 header 匹配)
    func directoryURL(for sessionId: String) -> URL? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions")
            .appendingPathComponent(dshProjectKey(configuredWorkspaceURL().path))
        let direct = sessionsDir.appendingPathComponent(sessionId)
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("session.jsonl.zstd").path) {
            return direct
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for dir in entries {
            let log = dir.appendingPathComponent("session.jsonl.zstd")
            guard FileManager.default.fileExists(atPath: log.path),
                  let line = SessionLogReader.readFirstZstdLine(log),
                  let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["id"] as? String == sessionId else { continue }
            return dir
        }
        return nil
    }

    /// 按会话 id 定位日志文件
    func logURL(for sessionId: String) -> URL? {
        directoryURL(for: sessionId)?.appendingPathComponent("session.jsonl.zstd")
    }

    private func derive() -> ActiveSessionInfo? {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/sessions")
            .appendingPathComponent(dshProjectKey(configuredWorkspaceURL().path))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (dir: URL, date: Date)?
        for dir in entries {
            let log = dir.appendingPathComponent("session.jsonl.zstd")
            guard let vals = try? log.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = vals.contentModificationDate else { continue }
            if best == nil || mtime > best!.date { best = (dir, mtime) }
        }
        guard let dir = best?.dir,
              let logURL = URL(string: dir.appendingPathComponent("session.jsonl.zstd").path),
              let line = SessionLogReader.readFirstZstdLine(logURL),
              let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let createdMs = obj["createdAt"] as? Double else { return nil }
        return ActiveSessionInfo(
            sessionId: dir.lastPathComponent,
            logURL: logURL,
            createdAt: Date(timeIntervalSince1970: createdMs / 1000)
        )
    }
}

// MARK: - zstd 会话日志读取

enum SessionLogReader {
    static func findZstdBinary() -> String? {
        ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 逐行遍历会话日志(解压 JSONL),每行回调一次
    static func forEachLine(_ url: URL, onLine: @escaping (String) -> Void, completion: @escaping () -> Void) {
        guard let zstd = findZstdBinary() else {
            completion()
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstd)
        proc.arguments = ["-dc", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        var buffer = Data()
        var finished = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if finished { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                finished = true
                if !buffer.isEmpty {
                    if let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                        onLine(line)
                    }
                    buffer = Data()
                }
                completion()
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                if let line = String(data: buffer[..<newline], encoding: .utf8), !line.isEmpty {
                    onLine(line)
                }
                buffer = buffer[(buffer.index(after: newline))...]
            }
        }
        do {
            try proc.run()
        } catch {
            completion()
        }
    }

    static func readFirstZstdLine(_ url: URL) -> String? {
        guard let zstd = findZstdBinary() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: zstd)
        proc.arguments = ["-dc", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        let sema = DispatchSemaphore(value: 0)
        var buffer = Data()
        var done = false
        var result: String?
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if done { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                done = true
                sema.signal()
                return
            }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: 10) {
                done = true
                result = String(data: buffer[..<newline], encoding: .utf8)
                sema.signal()
            }
        }
        do { try proc.run() } catch { return nil }
        _ = sema.wait(timeout: .now() + 10)
        proc.terminate()
        pipe.fileHandleForReading.readabilityHandler = nil
        return result
    }
}

// MARK: - 交付清单读取(交付登记制)

/// 会话交付清单 delivered.json:{"files":["相对或绝对路径", ...]}
/// 只有清单里的文件才算「交付物」;面板不猜测、不按类型推断
final class DeliveredFilesReader {
    func read(sessionDir: URL, workspace: URL) -> [FileEntry] {
        let ledger = sessionDir.appendingPathComponent("delivered.json")
        guard let data = try? Data(contentsOf: ledger),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = obj["files"] as? [String] else { return [] }
        var entries: [FileEntry] = []
        for raw in files {
            let url: URL
            if raw.hasPrefix("/") {
                url = URL(fileURLWithPath: raw)
            } else {
                url = workspace.appendingPathComponent(raw)
            }
            guard let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]),
                  vals.isDirectory == false,
                  let mtime = vals.contentModificationDate else { continue }
            entries.append(FileEntry(url: url.standardizedFileURL,
                                     relativePath: raw,
                                     size: Int64(vals.fileSize ?? 0),
                                     modifiedAt: mtime))
        }
        entries.sort { $0.modifiedAt > $1.modifiedAt }
        return entries
    }
}

// MARK: - 表格单元格

final class FileCellView: NSTableCellView {
    let subLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let img = NSImageView()
        img.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: "")
        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(img)
        addSubview(name)
        addSubview(subLabel)
        imageView = img
        textField = name

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            img.centerYAnchor.constraint(equalTo: centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 20),
            img.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            subLabel.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            subLabel.trailingAnchor.constraint(equalTo: name.trailingAnchor),
            subLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - 右侧「对话文件」面板

final class FilesPanel: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [FileEntry] = []
    var onOpenFile: ((URL) -> Void)?
    var onRevealFile: ((URL) -> Void)?

    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "打开文件", target: nil, action: nil)
    private let revealButton = NSButton(title: "在访达中显示", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildUI() {
        let title = NSTextField(labelWithString: "交付文件")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 42
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.allowsEmptySelection = true

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        openButton.target = self
        openButton.action = #selector(openSelected)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(revealSelected)
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .small

        let buttonRow = NSStackView(views: [openButton, revealButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(countLabel)
        addSubview(scroll)
        addSubview(buttonRow)

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            countLabel.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -8),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            buttonRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    // MARK: 数据展示

    /// 展示本次对话交付的文件(来自会话日志提取)
    func show(entries newEntries: [FileEntry]) {
        entries = newEntries
        tableView.reloadData()
        countLabel.stringValue = entries.isEmpty ? "本次对话暂无交付文件" : "\(entries.count) 个交付文件"
    }

    // MARK: 选中项

    var selectedURL: URL? {
        let row = tableView.selectedRow
        guard row >= 0, row < entries.count else { return nil }
        return entries[row].url
    }

    @objc func openSelected() {
        if let url = selectedURL { onOpenFile?(url) }
    }

    @objc func revealSelected() {
        if let url = selectedURL { onRevealFile?(url) }
    }

    @objc func doubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        onOpenFile?(entries[row].url)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell: FileCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? FileCellView {
            cell = reused
        } else {
            cell = FileCellView(frame: .zero)
            cell.identifier = id
        }
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        cell.textField?.stringValue = (entry.relativePath as NSString).lastPathComponent
        let sizeText = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        let timeText = formatter.string(from: entry.modifiedAt)
        let dir = (entry.relativePath as NSString).deletingLastPathComponent
        cell.subLabel.stringValue = dir.isEmpty ? "\(sizeText) · \(timeText)" : "\(dir) · \(sizeText) · \(timeText)"
        return cell
    }
}
