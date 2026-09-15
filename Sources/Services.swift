import Foundation

/// 查询走独立的 SQLite 连接，和索引写入互不阻塞（WAL 支持一写多读）。
/// 包成 actor 是为了让 UI 侧的并发调用自动串行化。
actor SearchService {
    private let store: Store

    init(path: String) throws {
        self.store = try Store(path: path)
    }

    func search(_ query: String, _ filter: SearchFilter) throws -> SearchOutcome {
        try store.search(query: query, filter: filter)
    }

    func messages(sessionId: String, conversationOnly: Bool = false) throws -> [DetailMessage] {
        try store.messages(sessionId: sessionId, conversationOnly: conversationOnly)
    }

    func toolMessageCount(sessionId: String) throws -> Int {
        try store.toolMessageCount(sessionId: sessionId)
    }

    func subagents(of sessionId: String) throws -> [SessionHitGroup] {
        try store.subagents(of: sessionId)
    }

    func session(id: String) throws -> SessionHitGroup? {
        try store.session(id: id)
    }

    func projects() throws -> [ProjectRow] {
        try store.projects()
    }

    func recentSessions(projectId: Int64?, includeSubagents: Bool, limit: Int = 200) throws -> [SessionHitGroup] {
        try store.recentSessions(projectId: projectId, includeSubagents: includeSubagents, limit: limit)
    }

    func counts() throws -> (projects: Int, sessions: Int, sidechains: Int, messages: Int, textBytes: Int) {
        try store.counts()
    }
}

/// 索引侧的独立连接。写操作全在这个 actor 里串行发生。
actor IndexService {
    private let indexer: Indexer

    init(path: String) throws {
        self.indexer = Indexer(store: try Store(path: path))
    }

    func indexAll(rebuild: Bool = false,
                  onProgress: @Sendable @escaping (Indexer.Progress) -> Void) throws -> Indexer.Stats {
        try indexer.indexAll(rebuild: rebuild, onProgress: onProgress)
    }

    /// FSEvents 报上来的一批变更路径，逐个增量索引。
    /// - Returns: 实际新增的正文条数（0 表示这批变更没带来新内容）
    @discardableResult
    func indexPaths(_ paths: [String]) -> Int {
        var added = 0
        for path in paths {
            let n = (try? indexer.indexPath(path)) ?? -1
            if n > 0 { added += n }
        }
        return added
    }
}

extension Indexer.Progress: @unchecked Sendable {}
extension Indexer.Stats: @unchecked Sendable {}
