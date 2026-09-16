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

    /// 一批增量索引的结果。
    ///
    /// 之所以要把失败路径带出来：FSEvents 的事件是**一次性**的。原来这里
    /// `(try? …) ?? -1` 把错误直接吞掉，那批内容就再也没人管了 —— 除非之后
    /// 恰好又有写入把同一个文件带进新的事件。如果失败的正好是流式输出的最后
    /// 一批，那段回复就一直不出现，看起来就是「新内容加载不出来」。
    struct BatchResult: Sendable {
        /// 实际新增的正文条数（0 表示这批变更没带来新内容）
        var added: Int
        /// 索引时抛错的路径，交给调用方安排重试
        var failed: [String]
    }

    /// FSEvents 报上来的一批变更路径，逐个增量索引。
    @discardableResult
    func indexPaths(_ paths: [String]) -> BatchResult {
        var added = 0
        var failed: [String] = []
        for path in paths {
            do {
                let n = try indexer.indexPath(path)
                if n > 0 { added += n }
            } catch {
                failed.append(path)
            }
        }
        return BatchResult(added: added, failed: failed)
    }
}

extension Indexer.Progress: @unchecked Sendable {}
extension Indexer.Stats: @unchecked Sendable {}
