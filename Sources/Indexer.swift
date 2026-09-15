import Foundation

/// 扫描 ~/.claude/projects 并把会话正文灌进 SQLite。
///
/// 增量策略以**文件字节数**为准，不依赖 mtime：
///   size == indexed_bytes  → 无新内容，连文件都不打开
///   size >  indexed_bytes  → 从偏移量续读（追加写的常态）
///   size <  indexed_bytes  → 文件被重写过，该会话整体重建
final class Indexer {

    struct Progress {
        var scanned: Int
        var total: Int
        var currentFile: String
        var newMessages: Int
    }

    struct Stats {
        var projects = 0
        var sessions = 0
        var subagents = 0
        var newMessages = 0
        var skipped = 0
        var pruned = 0
        var rebuilt = false
        var failed: [(path: String, error: String)] = []
        var elapsed: TimeInterval = 0
    }

    let store: Store
    let root: URL

    static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
    }

    init(store: Store, root: URL = Indexer.defaultRoot) {
        self.store = store
        self.root = root
    }

    /// 是不是这个 app 自己查用量时产生的会话目录。
    /// 用后缀匹配而不是全等 —— 扁平化目录名的规则（`/`、`.`、`_` 全变 `-`）
    /// 是 Claude Code 定的，路径里带 `.` 的用户名之类会让全等匹配失效。
    static func isOwnProbe(_ dir: URL) -> Bool {
        dir.lastPathComponent.hasSuffix("ClaudeSessionSearch-probe")
    }

    // MARK: - 全量扫描

    /// - Parameter rebuild: 丢弃已索引的正文重新解析。解析逻辑变更后必须这样做，
    ///   否则未变的文件会被当成「无新内容」跳过，改动看不到效果。
    func indexAll(rebuild: Bool = false, onProgress: ((Progress) -> Void)? = nil) throws -> Stats {
        let started = Date()
        var stats = Stats()

        // 库里的格式版本比代码旧，说明解析逻辑变过，自动重建
        let auto = (try? store.needsRebuild()) ?? false
        if rebuild || auto {
            try store.resetAllSessions()
            stats.rebuilt = true
        }

        // 跳过自己探测用量时留下的会话目录，否则 app 会把自己产生的
        // 会话索引进列表（见 UsageProbe 的说明）
        let projectDirs = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) ?? [])
            .filter { !Self.isOwnProbe($0) }

        // 先解析出每个项目的真实 cwd，才能算出无歧义的显示名
        var cwdByDir: [URL: String] = [:]
        for dir in projectDirs {
            cwdByDir[dir] = firstCwd(in: dir) ?? ""
        }
        let displayNames = Self.disambiguate(cwdByDir.mapValues { $0 })

        var units: [(project: URL, projectId: Int64, file: URL, parent: String?)] = []
        for dir in projectDirs {
            let cwd = cwdByDir[dir] ?? ""
            let pid = try store.upsertProject(dirName: dir.lastPathComponent, cwd: cwd,
                                              displayName: displayNames[dir] ?? dir.lastPathComponent)
            stats.projects += 1

            for file in mainSessionFiles(in: dir) {
                units.append((dir, pid, file, nil))
                // 同名目录下的子 agent 记录
                let parentId = file.deletingPathExtension().lastPathComponent
                let subDir = dir.appendingPathComponent(parentId).appendingPathComponent("subagents")
                for sub in agentFiles(in: subDir) {
                    units.append((dir, pid, sub, parentId))
                }
            }
        }

        var liveIds = Set<String>()
        for (i, unit) in units.enumerated() {
            let sid = Self.sessionId(for: unit.file, parent: unit.parent)
            liveIds.insert(sid)
            do {
                let added = try indexFile(unit.file, sessionId: sid, projectId: unit.projectId,
                                          parentSessionId: unit.parent)
                if added < 0 { stats.skipped += 1 } else { stats.newMessages += added }
                if unit.parent == nil { stats.sessions += 1 } else { stats.subagents += 1 }
            } catch {
                stats.failed.append((unit.file.path, String(describing: error)))
            }
            onProgress?(Progress(scanned: i + 1, total: units.count,
                                 currentFile: unit.file.lastPathComponent,
                                 newMessages: stats.newMessages))
        }

        stats.pruned = (try? store.pruneMissingSessions(keeping: liveIds)) ?? 0
        // 无条件跑：即使这轮没有会话要清，之前留下的空项目行也该走。
        // 放在清会话之后 —— 清掉最后一个会话的项目正好在这一步变空。
        try? store.pruneEmptyProjects()
        try? store.markSchemaVersion()
        stats.elapsed = Date().timeIntervalSince(started)
        return stats
    }

    // MARK: - 单文件（FSEvents 也走这里）

    /// - Returns: 新增消息条数；`-1` 表示文件无变化被跳过。
    @discardableResult
    func indexFile(_ file: URL, sessionId: String, projectId: Int64,
                   parentSessionId: String?) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        let state = try store.indexState(sessionId: sessionId)
        var offset: UInt64 = 0
        var startSeq = 0

        if let state {
            if size == state.bytes { return -1 }              // 无新内容
            if size < state.bytes {                            // 被重写，全量重建
                try store.resetSession(sessionId)
            } else {
                offset = state.bytes
                startSeq = state.msgCount
            }
        }

        let parsed = try JSONLParser.parse(path: file.path, fromOffset: offset, startSeq: startSeq)

        var meta = parsed.meta
        if meta.sessionId.isEmpty { meta.sessionId = sessionId }
        if parentSessionId != nil { meta.isSidechain = true }

        if offset == 0 {
            // 只有从头读时，「第一条正文」才真的是会话的第一条
            meta.firstAnyText = parsed.messages.first { $0.kind == .text }?.text
        } else {
            // 增量续读读到的是文件尾部：这一批的「首条消息」其实是会话中段的内容，
            // 拿它当标题会让会话名漂成某条中间消息。清掉，让 Store 保留已存标题。
            meta.firstPrompt = nil
            meta.firstAnyText = nil
        }

        let agentMeta = parentSessionId == nil ? nil : loadAgentMeta(for: file)

        return try store.transaction {
            try store.insertMessages(parsed.messages, sessionId: sessionId)
            try store.upsertSession(id: sessionId, projectId: projectId, filePath: file.path,
                                    meta: meta, parentSessionId: parentSessionId,
                                    agentMeta: agentMeta,
                                    indexedBytes: parsed.consumedBytes,
                                    msgCount: startSeq + parsed.messages.count,
                                    mtime: mtime)
            return parsed.messages.count
        }
    }

    /// 供 FSEvents 使用：只知道路径，自己推断出会话归属。
    @discardableResult
    func indexPath(_ path: String) throws -> Int {
        let file = URL(fileURLWithPath: path)
        guard file.pathExtension == "jsonl" else { return -1 }

        // .../projects/<projectDir>/<uuid>.jsonl
        // .../projects/<projectDir>/<uuid>/subagents/agent-xxx.jsonl
        let parts = file.pathComponents
        guard let projectsIdx = parts.lastIndex(of: "projects"),
              projectsIdx + 1 < parts.count else { return -1 }

        let projectDir = root.appendingPathComponent(parts[projectsIdx + 1])
        let isSubagent = parts.contains("subagents")
        let parent: String? = isSubagent ? parts[projectsIdx + 2] : nil

        let pid = try store.upsertProject(dirName: projectDir.lastPathComponent,
                                          cwd: firstCwd(in: projectDir) ?? "",
                                          displayName: "")
        let sid = Self.sessionId(for: file, parent: parent)
        return try indexFile(file, sessionId: sid, projectId: pid, parentSessionId: parent)
    }

    // MARK: - 辅助

    /// 主会话用文件名里的 uuid；子 agent 文件里没有 sessionId 字段，
    /// 用「父会话 id + agent 文件名」合成一个稳定主键。
    static func sessionId(for file: URL, parent: String?) -> String {
        let base = file.deletingPathExtension().lastPathComponent
        if let parent { return "\(parent):\(base)" }
        return base
    }

    private func mainSessionFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func agentFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("agent-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 子 agent 的 agent-xxx.meta.json，提供 agentType / description
    private func loadAgentMeta(for file: URL) -> AgentMeta? {
        let metaPath = file.deletingPathExtension().appendingPathExtension("meta.json")
        guard let data = try? Data(contentsOf: metaPath) else { return nil }
        return try? JSONDecoder().decode(AgentMeta.self, from: data)
    }

    /// 目录名（`-Users-alice-code-my-project`）无法可靠反解出原路径，
    /// 因为 `.` `_` `-` 都被压成了 `-`。所以直接从任一会话记录里读 `cwd` 字段。
    /// 扫多远还找不到 cwd 就放弃。实测有文件的第一个 cwd 落在 **304 KB** 处 ——
    /// 会话开头可能先堆十几条 `file-history-snapshot`，单条就能几十 KB。
    /// 原来只读 64 KB，于是整个项目的 cwd 取不到，侧栏那一行就是空白。
    private static let cwdScanLimit = 8 * 1024 * 1024

    private func firstCwd(in dir: URL) -> String? {
        for file in mainSessionFiles(in: dir).reversed() {   // 新文件更可能带完整字段
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            var carry = Data()
            var scanned = 0
            while scanned < Self.cwdScanLimit,
                  let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                scanned += chunk.count
                carry.append(chunk)
                var lines = carry.split(separator: 0x0A, omittingEmptySubsequences: false)
                // 最后一段多半是被切断的半行，留到下一轮拼上；
                // 只有一段说明整块都还没凑够一整行（单条记录能有 186 KB）
                guard lines.count > 1 else { continue }
                carry = Data(lines.removeLast())
                for line in lines {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       let cwd = obj["cwd"] as? String, !cwd.isEmpty {
                        return cwd
                    }
                }
            }
        }
        return nil
    }

    /// 生成人类可读且互不重复的项目名。
    /// 实测存在同名叶子目录（github_dev/tlp-admin-backend 与 github_master/tlp-admin-backend），
    /// 重名时逐级往上补父目录直到唯一。
    static func disambiguate(_ cwdByDir: [URL: String]) -> [URL: String] {
        var result: [URL: String] = [:]
        var depth = 1

        var pending = Set(cwdByDir.keys)
        while !pending.isEmpty && depth <= 4 {
            var byName: [String: [URL]] = [:]
            for dir in pending {
                let name = Self.tailPath(Self.basis(for: dir, cwd: cwdByDir[dir]), depth: depth)
                byName[name, default: []].append(dir)
            }
            for (name, dirs) in byName where dirs.count == 1 {
                result[dirs[0]] = name
                pending.remove(dirs[0])
            }
            depth += 1
        }
        // 还有冲突就退回完整路径
        for dir in pending { result[dir] = Self.basis(for: dir, cwd: cwdByDir[dir]) }
        return result
    }

    /// 拿什么来起名。
    ///
    /// 取不到 cwd 时**不能返回空串** —— 调用方存的是 `firstCwd(...) ?? ""`，
    /// 空串会一路走到底，侧栏那一行就什么都不显示（实测踩到过）。
    /// 退而用扁平化目录名，去掉 home 前缀让它短一些：丑，但至少能认出是哪个项目。
    static func basis(for dir: URL, cwd: String?) -> String {
        if let cwd, !cwd.isEmpty { return cwd }
        var flat = dir.lastPathComponent
        var homePrefix = NSHomeDirectory()
        for ch in ["/", ".", "_", " "] {
            homePrefix = homePrefix.replacingOccurrences(of: ch, with: "-")
        }
        if flat.hasPrefix(homePrefix) { flat.removeFirst(homePrefix.count) }
        return flat.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func tailPath(_ path: String, depth: Int) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return path }
        return parts.suffix(depth).joined(separator: "/")
    }
}
