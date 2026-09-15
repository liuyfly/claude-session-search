import Foundation
import SQLite3

/// 命中高亮用的哨兵字符 —— 正文里不可能出现，UI 按它切分着色。
let hlOpen = "\u{1}"
let hlClose = "\u{2}"

struct SearchFilter: Sendable {
    var projectId: Int64?
    /// 只搜我键入的内容（role=user 且 kind=text）
    var humanOnly = false
    /// 只搜 Claude 的回复正文
    var assistantOnly = false
    /// 是否把 thinking / 工具调用 / 工具输出也算进来。
    /// 默认关闭：实测搜「git」全库 37677 条命中里只有 2165 条是真实对话，
    /// 其余都是被读进上下文的文件内容和命令输出，会把真正想找的对话淹没。
    var includeToolNoise = false
    /// 是否包含子 agent 会话
    var includeSubagents = true
    var since: Date?
    var until: Date?
    /// true = 按命中数排序，false = 按时间倒序
    var sortByRelevance = false
}

extension Store {

    /// trigram 分词器对不足 3 个字符的查询会**静默返回 0 命中**，
    /// 是最容易踩的坑（搜「迁移」「部署」「PR」全查不到）。
    /// 这类查询降级为 LIKE 子串扫描 —— 29.5 MB 正文上实测约 28 ms。
    static let trigramMinChars = 3

    func search(query rawQuery: String, filter: SearchFilter) throws -> SearchOutcome {
        let started = Date()
        let terms = rawQuery
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return SearchOutcome() }

        let needsFallback = terms.contains { $0.count < Store.trigramMinChars }
        let hits = needsFallback
            ? try searchBySubstring(terms: terms, filter: filter)
            : try searchByFTS(terms: terms, filter: filter)

        var outcome = groupBySession(hits, filter: filter)
        outcome.strategy = needsFallback ? .substring : .fts
        outcome.totalHits = hits.count
        outcome.truncated = hits.count >= Store.hitLimit
        outcome.elapsedMs = Date().timeIntervalSince(started) * 1000
        return outcome
    }

    // MARK: - FTS5 路径

    private func searchByFTS(terms: [String], filter: SearchFilter) throws -> [Hit] {
        // 每个词作为独立 phrase 用 AND 连接：多个词可以出现在同一条消息的任意位置。
        // 内部的双引号要按 FTS5 规则翻倍转义。
        let match = terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " AND ")

        let clause = FilterClause(filter, startIndex: 2)
        let sql = """
        SELECT m.id, m.session_id, m.seq, m.role, m.kind, m.ts,
               snippet(messages_fts, 0, '\(hlOpen)', '\(hlClose)', '…', 20)
        FROM messages_fts
        JOIN messages m ON m.id = messages_fts.rowid
        JOIN sessions s ON s.id = m.session_id
        WHERE messages_fts MATCH ?1\(clause.sql)
        ORDER BY m.id DESC LIMIT \(Store.hitLimit)
        """
        // 按 rowid 倒序而非 bm25：trigram 下每个三字组都是一个 token，
        // bm25 打出的「相关度」并无实际意义，却要扫完全部命中才能排序。
        // 倒序取最新，命中数撞上限时砍掉的也是最旧的记录。
        let stmt = try prepare(sql)
        stmt.bind(1, match)
        clause.bind(to: stmt)
        return collectHits(stmt, snippetColumn: 6, fallbackTerms: nil)
    }

    // MARK: - LIKE 兜底路径

    private func searchBySubstring(terms: [String], filter: SearchFilter) throws -> [Hit] {
        // LIKE 在 SQLite 里对 ASCII 默认不区分大小写，中文本身无大小写之分。
        // 为了让英文短词（如 pr / ui）也大小写无关，两侧统一转小写。
        let likeConds = terms.indices
            .map { " AND lower(m.text) LIKE ?\($0 + 1) ESCAPE '\\'" }
            .joined()
        let clause = FilterClause(filter, startIndex: Int32(terms.count + 1))
        let sql = """
        SELECT m.id, m.session_id, m.seq, m.role, m.kind, m.ts, m.text
        FROM messages m
        JOIN sessions s ON s.id = m.session_id
        WHERE 1=1\(likeConds)\(clause.sql)
        ORDER BY m.id DESC LIMIT \(Store.hitLimit)
        """
        let stmt = try prepare(sql)
        for (i, term) in terms.enumerated() {
            stmt.bind(Int32(i + 1), "%\(Self.escapeLike(term.lowercased()))%")
        }
        clause.bind(to: stmt)
        return collectHits(stmt, snippetColumn: 6, fallbackTerms: terms)
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 结果装配

    private func collectHits(_ stmt: Statement, snippetColumn: Int32, fallbackTerms: [String]?) -> [Hit] {
        var out: [Hit] = []
        while stmt.step() {
            let raw = stmt.text(snippetColumn) ?? ""
            let snippet = fallbackTerms == nil ? raw : Self.makeSnippet(raw, terms: fallbackTerms!)
            out.append(Hit(id: stmt.int64(0), sessionId: stmt.text(1) ?? "",
                           seq: stmt.int(2), role: stmt.text(3) ?? "",
                           kind: stmt.text(4) ?? "", timestamp: stmt.text(5),
                           snippet: snippet))
        }
        return out
    }

    /// LIKE 路径没有 snippet()，自己在第一个命中词周围裁一段并打标记。
    static func makeSnippet(_ text: String, terms: [String], radius: Int = 60) -> String {
        let lower = text.lowercased()
        guard let first = terms.compactMap({ lower.range(of: $0.lowercased()) })
            .min(by: { $0.lowerBound < $1.lowerBound }) else {
            return String(text.prefix(radius * 2))
        }
        let start = text.index(first.lowerBound, offsetBy: -radius,
                               limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(first.upperBound, offsetBy: radius,
                             limitedBy: text.endIndex) ?? text.endIndex

        var slice = String(text[start..<end])
        // 在片段内标出所有命中词（长词优先，避免短词把长词切碎）
        for term in terms.sorted(by: { $0.count > $1.count }) {
            slice = highlight(slice, term: term)
        }
        if start > text.startIndex { slice = "…" + slice }
        if end < text.endIndex { slice += "…" }
        return slice
    }

    private static func highlight(_ s: String, term: String) -> String {
        guard !term.isEmpty else { return s }
        var result = ""
        var rest = Substring(s)
        while let r = rest.range(of: term, options: .caseInsensitive) {
            result += rest[rest.startIndex..<r.lowerBound] + hlOpen + rest[r] + hlClose
            rest = rest[r.upperBound...]
        }
        return result + rest
    }

    /// 命中按会话聚合，每组保留前几条片段做预览。
    ///
    /// 子 agent 不作为独立结果列出 —— 它们是主会话内部派发的工作，
    /// 单独列出来只会把同一件事拆成好几行。它们的命中归并到父会话上。
    private func groupBySession(_ hits: [Hit], filter: SearchFilter) -> SearchOutcome {
        guard !hits.isEmpty else { return SearchOutcome() }

        let rollup = (try? parentMap(ids: Set(hits.map(\.sessionId)))) ?? [:]

        var order: [String] = []
        var buckets: [String: [Hit]] = [:]
        var fromSubagent: [String: Int] = [:]
        for hit in hits {
            let key = rollup[hit.sessionId] ?? hit.sessionId
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(hit)
            if key != hit.sessionId { fromSubagent[key, default: 0] += 1 }
        }

        // 一次性取回这批会话的元信息
        let meta = (try? sessionSummaries(ids: order)) ?? [:]

        var groups: [SessionHitGroup] = order.compactMap { sid in
            guard var group = meta[sid] else { return nil }
            let bucket = buckets[sid] ?? []
            group.hitCount = bucket.count
            group.subagentHits = fromSubagent[sid] ?? 0
            // 优先拿主会话自己的片段做预览，子 agent 的内容不在主会话正文里，
            // 点进去找不到，会让人以为搜错了
            let own = bucket.filter { $0.sessionId == sid }
            let preferred = own.isEmpty ? bucket : own
            group.previews = Array(preferred.sorted { $0.seq < $1.seq }.prefix(3))
            return group
        }

        if filter.sortByRelevance {
            groups.sort { ($0.hitCount, $0.endedAt ?? "") > ($1.hitCount, $1.endedAt ?? "") }
        } else {
            groups.sort { ($0.endedAt ?? "") > ($1.endedAt ?? "") }
        }
        return SearchOutcome(groups: groups, strategy: .fts, totalHits: hits.count)
    }

    /// 子 agent 会话 id → 父会话 id。主会话不在结果里（无需改写）。
    private func parentMap(ids: Set<String>) throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let list = Array(ids)
        let placeholders = list.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        let stmt = try prepare("""
        SELECT id, parent_session_id FROM sessions
        WHERE id IN (\(placeholders)) AND parent_session_id IS NOT NULL
        """)
        for (i, id) in list.enumerated() { stmt.bind(Int32(i + 1), id) }
        var out: [String: String] = [:]
        while stmt.step() {
            if let child = stmt.text(0), let parent = stmt.text(1) { out[child] = parent }
        }
        return out
    }

    private func sessionSummaries(ids: [String]) throws -> [String: SessionHitGroup] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = ids.indices.map { "?\($0 + 1)" }.joined(separator: ",")
        let stmt = try prepare("""
        SELECT s.id, s.title, p.display_name, p.cwd, s.started_at, s.ended_at,
               s.is_sidechain, s.agent_type, p.id
        FROM sessions s JOIN projects p ON p.id = s.project_id
        WHERE s.id IN (\(placeholders))
        """)
        for (i, id) in ids.enumerated() { stmt.bind(Int32(i + 1), id) }

        var out: [String: SessionHitGroup] = [:]
        while stmt.step() {
            let sid = stmt.text(0) ?? ""
            out[sid] = SessionHitGroup(sessionId: sid, title: stmt.text(1) ?? "",
                                       projectId: stmt.int64(8),
                                       projectName: stmt.text(2) ?? "", projectCwd: stmt.text(3) ?? "",
                                       startedAt: stmt.text(4), endedAt: stmt.text(5),
                                       hitCount: 0, isSidechain: stmt.bool(6),
                                       agentType: stmt.text(7), previews: [])
        }
        return out
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}

// MARK: - 过滤条件

/// 把筛选器编译成 SQL 片段 + 绑定值。
/// SQL 文本和绑定下标在同一处生成，杜绝两边手工对齐导致的参数错位。
private struct FilterClause {
    var sql = ""
    private var strings: [(Int32, String)] = []
    private var ints: [(Int32, Int64)] = []

    init(_ f: SearchFilter, startIndex: Int32) {
        var next = startIndex

        if let pid = f.projectId {
            sql += " AND s.project_id = ?\(next)"
            ints.append((next, pid)); next += 1
        }
        if !f.includeSubagents { sql += " AND s.is_sidechain = 0" }
        if f.humanOnly  { sql += " AND m.role = 'user' AND m.kind = 'text'" }
        if f.assistantOnly { sql += " AND m.role = 'assistant' AND m.kind = 'text'" }
        if !f.includeToolNoise { sql += " AND m.kind = 'text'" }
        if let since = f.since {
            sql += " AND m.ts >= ?\(next)"
            strings.append((next, Store.iso.string(from: since))); next += 1
        }
        if let until = f.until {
            sql += " AND m.ts <= ?\(next)"
            strings.append((next, Store.iso.string(from: until))); next += 1
        }
    }

    func bind(to stmt: Statement) {
        for (i, v) in ints { stmt.bind(i, v) }
        for (i, v) in strings { stmt.bind(i, v) }
    }
}
