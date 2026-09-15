import Foundation
import SQLite3

/// SQLite 里没有导出的 SQLITE_TRANSIENT —— 让 SQLite 自己拷贝绑定的字符串，
/// 免得 Swift 侧的临时缓冲区在语句执行前就被回收。
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum StoreError: Error, CustomStringConvertible {
    case open(String)
    case sql(String, String)

    var description: String {
        switch self {
        case .open(let m): return "打不开数据库: \(m)"
        case .sql(let q, let m): return "SQL 失败: \(m)\n  语句: \(q)"
        }
    }
}

/// 一条预编译语句的轻量封装，参数下标从 1 开始。
final class Statement {
    fileprivate let handle: OpaquePointer
    private let sql: String

    init(db: OpaquePointer, sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.sql(sql, String(cString: sqlite3_errmsg(db)))
        }
        self.handle = stmt
        self.sql = sql
    }

    deinit { sqlite3_finalize(handle) }

    @discardableResult
    func bind(_ index: Int32, _ value: String?) -> Statement {
        if let value { sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int64?) -> Statement {
        if let value { sqlite3_bind_int64(handle, index, value) }
        else { sqlite3_bind_null(handle, index) }
        return self
    }

    @discardableResult
    func bind(_ index: Int32, _ value: Int?) -> Statement {
        bind(index, value.map(Int64.init))
    }

    /// 走完一行；返回是否还有行
    func step() -> Bool { sqlite3_step(handle) == SQLITE_ROW }

    /// 执行一条不返回结果的语句
    func run() throws {
        let rc = sqlite3_step(handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sql(sql, String(cString: sqlite3_errmsg(sqlite3_db_handle(handle))))
        }
    }

    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }

    func text(_ col: Int32) -> String? {
        guard let c = sqlite3_column_text(handle, col) else { return nil }
        return String(cString: c)
    }
    func int(_ col: Int32) -> Int { Int(sqlite3_column_int64(handle, col)) }
    func int64(_ col: Int32) -> Int64 { sqlite3_column_int64(handle, col) }
    func bool(_ col: Int32) -> Bool { sqlite3_column_int(handle, col) != 0 }
}

// MARK: -

final class Store {
    private var db: OpaquePointer!

    /// 单次搜索最多取回的命中数 —— 「error」这类高频词能命中上万条，
    /// 全取回没意义且拖慢 UI。超出会在结果里标记 truncated。
    static let hitLimit = 2000

    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeSessionSearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.db").path
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.open(path)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA temp_store=MEMORY")
        try exec("PRAGMA cache_size=-64000")     // 64 MB page cache
        try migrate()
    }

    deinit { if db != nil { sqlite3_close_v2(db) } }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(sql, msg)
        }
    }

    func prepare(_ sql: String) throws -> Statement { try Statement(db: db, sql: sql) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec("COMMIT")
            return value
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS projects (
          id            INTEGER PRIMARY KEY,
          dir_name      TEXT NOT NULL UNIQUE,
          cwd           TEXT NOT NULL DEFAULT '',
          display_name  TEXT NOT NULL DEFAULT ''
        );

        CREATE TABLE IF NOT EXISTS sessions (
          id                TEXT PRIMARY KEY,
          project_id        INTEGER NOT NULL REFERENCES projects(id),
          file_path         TEXT NOT NULL,
          title             TEXT NOT NULL DEFAULT '',
          title_source      TEXT NOT NULL DEFAULT '',
          first_prompt      TEXT,
          started_at        TEXT,
          ended_at          TEXT,
          msg_count         INTEGER NOT NULL DEFAULT 0,
          git_branch        TEXT,
          is_sidechain      INTEGER NOT NULL DEFAULT 0,
          parent_session_id TEXT,
          agent_id          TEXT,
          agent_type        TEXT,
          agent_description TEXT,
          indexed_bytes     INTEGER NOT NULL DEFAULT 0,
          file_mtime        REAL NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS messages (
          id          INTEGER PRIMARY KEY,
          session_id  TEXT NOT NULL,
          seq         INTEGER NOT NULL,
          role        TEXT NOT NULL,
          kind        TEXT NOT NULL,
          tool_name   TEXT,
          ts          TEXT,
          text        TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_msg_session ON messages(session_id, seq);
        -- LIKE 用不上索引，但这个索引能让默认口径（kind='text'）先把行集缩到
        -- 约四分之一再逐行扫描，短词兜底查询因此快数倍。
        CREATE INDEX IF NOT EXISTS idx_msg_kind_role ON messages(kind, role);
        CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_id);
        CREATE INDEX IF NOT EXISTS idx_sessions_parent ON sessions(parent_session_id);
        CREATE INDEX IF NOT EXISTS idx_sessions_ended ON sessions(ended_at DESC);
        """)

        // trigram 分词是中文可检索的关键：unicode61 会把整段中文当成一个 token。
        // external content 模式避免正文存两份。
        try exec("""
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
          text,
          tokenize='trigram',
          content='messages',
          content_rowid='id'
        );
        """)

        // 用触发器保持 FTS 同步，重建会话时删除也能正确回收索引
        try exec("""
        CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
          INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
          INSERT INTO messages_fts(messages_fts, rowid, text) VALUES('delete', old.id, old.text);
        END;
        """)
    }

    // MARK: - 写入

    func upsertProject(dirName: String, cwd: String, displayName: String) throws -> Int64 {
        let stmt = try prepare("""
        INSERT INTO projects(dir_name, cwd, display_name) VALUES(?1, ?2, ?3)
        ON CONFLICT(dir_name) DO UPDATE SET
          cwd = CASE WHEN excluded.cwd <> '' THEN excluded.cwd ELSE projects.cwd END,
          display_name = CASE WHEN excluded.display_name <> '' THEN excluded.display_name ELSE projects.display_name END
        RETURNING id
        """)
        stmt.bind(1, dirName).bind(2, cwd).bind(3, displayName)
        guard stmt.step() else { throw StoreError.sql("upsertProject", "无返回 id") }
        return stmt.int64(0)
    }

    /// 已索引到的位置。返回 nil 表示这个会话还没入库。
    func indexState(sessionId: String) throws -> (bytes: UInt64, msgCount: Int, mtime: Double)? {
        let stmt = try prepare("SELECT indexed_bytes, msg_count, file_mtime FROM sessions WHERE id = ?1")
        stmt.bind(1, sessionId)
        guard stmt.step() else { return nil }
        return (UInt64(stmt.int64(0)), stmt.int(1), sqlite3_column_double(stmt.handle, 2))
    }

    /// 索引格式版本。解析逻辑变更后递增它，旧库会在启动时自动全量重建
    /// —— 否则改了 parser 也看不到效果（已索引的文件会被当成「无变化」跳过）。
    static let schemaVersion: Int32 = 4

    /// 库里的格式版本与当前代码是否一致
    func needsRebuild() throws -> Bool {
        let stmt = try prepare("PRAGMA user_version")
        guard stmt.step() else { return false }
        let stored = Int32(stmt.int(0))
        // 空库不算需要重建，它本来就要走全量索引
        let hasData = try counts().messages > 0
        return hasData && stored != Self.schemaVersion
    }

    func markSchemaVersion() throws {
        try exec("PRAGMA user_version = \(Self.schemaVersion)")
    }

    /// 丢弃全部已索引的正文，保留会话骨架，下一轮索引会从头重读。
    func resetAllSessions() throws {
        try exec("DELETE FROM messages")
        try exec("UPDATE sessions SET indexed_bytes = 0, msg_count = 0")
        // FTS 的 external content 表要单独清，触发器只管逐行删除
        try exec("INSERT INTO messages_fts(messages_fts) VALUES('rebuild')")
    }

    /// 丢弃某会话已索引的正文（文件被重写/compact 后需要全量重建）
    func resetSession(_ sessionId: String) throws {
        let del = try prepare("DELETE FROM messages WHERE session_id = ?1")
        del.bind(1, sessionId)
        try del.run()
        let upd = try prepare("UPDATE sessions SET indexed_bytes = 0, msg_count = 0 WHERE id = ?1")
        upd.bind(1, sessionId)
        try upd.run()
    }

    /// 标题来源的权威度，数字越小越可信。
    ///
    /// custom / agent 是**用户在 CLI 里显式改的名字**，必须能盖过 ai
    /// 自动生成的摘要 —— 若两者同级，增量索引时先写入的那个就赖着不走了。
    /// prompt / first 是从正文里猜的，且在增量索引中会漂移。
    private static func titleRankSQL(_ column: String) -> String {
        """
        (CASE \(column)
           WHEN 'custom' THEN 1 WHEN 'agent' THEN 1
           WHEN 'agent-desc' THEN 2
           WHEN 'ai' THEN 3
           WHEN 'prompt' THEN 4
           WHEN 'first' THEN 5
           ELSE 6 END)
        """
    }

    func upsertSession(id: String, projectId: Int64, filePath: String, meta: SessionMeta,
                       parentSessionId: String?, agentMeta: AgentMeta?,
                       indexedBytes: UInt64, msgCount: Int, mtime: Double) throws {
        // 子 agent 的 .meta.json 里的 description 就是派发时写的任务摘要，
        // 比它那条又长又是模板的开场 prompt 好读得多。
        let title: (text: String, source: String) = {
            if let desc = agentMeta?.description, !desc.isEmpty { return (desc, "agent-desc") }
            return meta.resolvedTitle
        }()
        let stmt = try prepare("""
        INSERT INTO sessions(id, project_id, file_path, title, title_source, first_prompt,
                             started_at, ended_at, msg_count, git_branch, is_sidechain,
                             parent_session_id, agent_id, agent_type, agent_description,
                             indexed_bytes, file_mtime)
        VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)
        ON CONFLICT(id) DO UPDATE SET
          -- 增量索引时只读了文件尾部，标题行（在文件开头）往往不在这一批里，
          -- 于是本轮解析只能退到弱来源。绝不能让弱来源覆盖已存的权威标题，
          -- 否则会话名会漂成某条中间消息的正文。
          title         = CASE WHEN \(Self.titleRankSQL("excluded.title_source"))
                                 <= \(Self.titleRankSQL("sessions.title_source"))
                            THEN excluded.title ELSE sessions.title END,
          title_source  = CASE WHEN \(Self.titleRankSQL("excluded.title_source"))
                                 <= \(Self.titleRankSQL("sessions.title_source"))
                            THEN excluded.title_source ELSE sessions.title_source END,
          first_prompt  = COALESCE(sessions.first_prompt, excluded.first_prompt),
          started_at    = MIN(COALESCE(sessions.started_at, excluded.started_at), COALESCE(excluded.started_at, sessions.started_at)),
          ended_at      = MAX(COALESCE(sessions.ended_at, excluded.ended_at), COALESCE(excluded.ended_at, sessions.ended_at)),
          msg_count     = excluded.msg_count,
          git_branch    = COALESCE(excluded.git_branch, sessions.git_branch),
          indexed_bytes = excluded.indexed_bytes,
          file_mtime    = excluded.file_mtime
        """)
        stmt.bind(1, id).bind(2, projectId).bind(3, filePath)
            .bind(4, title.text).bind(5, title.source).bind(6, meta.firstPrompt)
            .bind(7, meta.startedAt).bind(8, meta.endedAt).bind(9, msgCount)
            .bind(10, meta.gitBranch).bind(11, meta.isSidechain ? 1 : 0)
            .bind(12, parentSessionId).bind(13, meta.agentId)
            .bind(14, agentMeta?.agentType).bind(15, agentMeta?.description)
            .bind(16, Int64(indexedBytes))
        sqlite3_bind_double(stmt.handle, 17, mtime)
        try stmt.run()
    }

    /// 批量插入正文。调用方负责包在一个事务里。
    func insertMessages(_ rows: [MessageRow], sessionId: String) throws {
        guard !rows.isEmpty else { return }
        let stmt = try prepare("""
        INSERT INTO messages(session_id, seq, role, kind, tool_name, ts, text)
        VALUES(?1,?2,?3,?4,?5,?6,?7)
        """)
        for row in rows {
            stmt.bind(1, sessionId).bind(2, row.seq).bind(3, row.role)
                .bind(4, row.kind.rawValue).bind(5, row.toolName)
                .bind(6, row.timestamp).bind(7, row.text)
            try stmt.run()
            stmt.reset()
        }
    }

    /// 删掉磁盘上已不存在的会话
    func pruneMissingSessions(keeping liveIds: Set<String>) throws -> Int {
        let all = try prepare("SELECT id FROM sessions")
        var stale: [String] = []
        while all.step() { if let id = all.text(0), !liveIds.contains(id) { stale.append(id) } }
        guard !stale.isEmpty else { return 0 }
        let delMsg = try prepare("DELETE FROM messages WHERE session_id = ?1")
        let delSess = try prepare("DELETE FROM sessions WHERE id = ?1")
        for id in stale {
            delMsg.bind(1, id); try delMsg.run(); delMsg.reset()
            delSess.bind(1, id); try delSess.run(); delSess.reset()
        }
        return stale.count
    }

    /// 删掉没有任何会话的项目行。
    ///
    /// `~/.claude/projects/` 下会留着空目录（会话被清理掉、或那个目录里从没跑过
    /// 会话），扫描时照样会建 project 行。侧栏靠 `HAVING count(s.id) > 0` 挡住了
    /// 它们，但 `counts()` 数的是 projects 表的行数，于是报出来的项目数偏高
    /// （实测 14 个里有 4 个是空的）。空行没有任何用处，直接清掉。
    func pruneEmptyProjects() throws {
        try prepare("""
        DELETE FROM projects
        WHERE id NOT IN (SELECT DISTINCT project_id FROM sessions)
        """).run()
    }

    // MARK: - 统计

    func counts() throws -> (projects: Int, sessions: Int, sidechains: Int, messages: Int, textBytes: Int) {
        let stmt = try prepare("""
        SELECT (SELECT count(*) FROM projects),
               (SELECT count(*) FROM sessions WHERE is_sidechain = 0),
               (SELECT count(*) FROM sessions WHERE is_sidechain = 1),
               (SELECT count(*) FROM messages),
               (SELECT COALESCE(sum(length(text)), 0) FROM messages)
        """)
        guard stmt.step() else { return (0, 0, 0, 0, 0) }
        return (stmt.int(0), stmt.int(1), stmt.int(2), stmt.int(3), stmt.int(4))
    }

    func projects() throws -> [ProjectRow] {
        let stmt = try prepare("""
        SELECT p.id, p.dir_name, p.cwd, p.display_name,
               count(s.id), max(s.ended_at)
        FROM projects p
        LEFT JOIN sessions s ON s.project_id = p.id AND s.is_sidechain = 0
        GROUP BY p.id
        HAVING count(s.id) > 0
        ORDER BY max(s.ended_at) DESC
        """)
        var out: [ProjectRow] = []
        while stmt.step() {
            out.append(ProjectRow(id: stmt.int64(0),
                                  dirName: stmt.text(1) ?? "",
                                  cwd: stmt.text(2) ?? "",
                                  displayName: stmt.text(3) ?? "",
                                  sessionCount: stmt.int(4),
                                  lastActiveAt: stmt.text(5)))
        }
        return out
    }

    // MARK: - 会话正文

    /// 正文里默认显示的两种消息。工具调用与输出体量是它们的十倍，
    /// 默认口径下不该白搬一趟。
    static let conversationKinds = ["text", "thinking"]

    /// - Parameter conversationOnly: 只取对话正文，跳过工具调用与输出。
    ///   实测某个会话全量是 1647 条 / 1.3 MB，其中对话只有 283 条 / 144 KB。
    func messages(sessionId: String, conversationOnly: Bool = false) throws -> [DetailMessage] {
        let filter = conversationOnly ? "AND kind IN ('text','thinking')" : ""
        let stmt = try prepare("""
        SELECT id, seq, role, kind, tool_name, ts, text
        FROM messages WHERE session_id = ?1 \(filter) ORDER BY seq
        """)
        stmt.bind(1, sessionId)
        var out: [DetailMessage] = []
        while stmt.step() {
            out.append(DetailMessage(id: stmt.int64(0), seq: stmt.int(1),
                                     role: stmt.text(2) ?? "", kind: stmt.text(3) ?? "",
                                     toolName: stmt.text(4), timestamp: stmt.text(5),
                                     text: stmt.text(6) ?? ""))
        }
        return out
    }

    /// 被跳过的工具记录条数。只查对话正文时用它填「显示 N 条工具调用与输出」，
    /// 不必为了一个数字把那 1.2 MB 读出来。
    func toolMessageCount(sessionId: String) throws -> Int {
        let stmt = try prepare("""
        SELECT COUNT(*) FROM messages
        WHERE session_id = ?1 AND kind NOT IN ('text','thinking')
        """)
        stmt.bind(1, sessionId)
        return stmt.step() ? stmt.int(0) : 0
    }

    /// 搜索框为空时展示的「最近会话」。没有这个的话首屏会是一片空白。
    func recentSessions(projectId: Int64?, includeSubagents: Bool, limit: Int) throws -> [SessionHitGroup] {
        var sql = """
        SELECT s.id, s.title, p.display_name, p.cwd, s.started_at, s.ended_at,
               s.msg_count, s.is_sidechain, s.agent_type, p.id
        FROM sessions s JOIN projects p ON p.id = s.project_id
        WHERE 1=1
        """
        if projectId != nil { sql += " AND s.project_id = ?1" }
        if !includeSubagents { sql += " AND s.is_sidechain = 0" }
        sql += " ORDER BY s.ended_at DESC LIMIT \(limit)"

        let stmt = try prepare(sql)
        if let projectId { stmt.bind(1, projectId) }

        var out: [SessionHitGroup] = []
        while stmt.step() {
            out.append(SessionHitGroup(sessionId: stmt.text(0) ?? "", title: stmt.text(1) ?? "",
                                       projectId: stmt.int64(9),
                                       projectName: stmt.text(2) ?? "", projectCwd: stmt.text(3) ?? "",
                                       startedAt: stmt.text(4), endedAt: stmt.text(5),
                                       hitCount: stmt.int(6), isSidechain: stmt.bool(7),
                                       agentType: stmt.text(8), previews: []))
        }
        return out
    }

    /// 单个会话的元信息（子 agent 不在任何列表里，正文视图靠这个拿标题）
    func session(id: String) throws -> SessionHitGroup? {
        let stmt = try prepare("""
        SELECT s.id, s.title, p.display_name, p.cwd, s.started_at, s.ended_at,
               s.msg_count, s.is_sidechain, s.agent_type, p.id
        FROM sessions s JOIN projects p ON p.id = s.project_id
        WHERE s.id = ?1
        """)
        stmt.bind(1, id)
        guard stmt.step() else { return nil }
        return SessionHitGroup(sessionId: stmt.text(0) ?? "", title: stmt.text(1) ?? "",
                               projectId: stmt.int64(9),
                               projectName: stmt.text(2) ?? "", projectCwd: stmt.text(3) ?? "",
                               startedAt: stmt.text(4), endedAt: stmt.text(5),
                               hitCount: stmt.int(6), isSidechain: stmt.bool(7),
                               agentType: stmt.text(8), previews: [])
    }

    /// 挂在某个主会话下的子 agent 会话
    func subagents(of sessionId: String) throws -> [SessionHitGroup] {
        let stmt = try prepare("""
        SELECT s.id, s.title, p.display_name, p.cwd, s.started_at, s.ended_at,
               s.msg_count, s.agent_type, p.id
        FROM sessions s JOIN projects p ON p.id = s.project_id
        WHERE s.parent_session_id = ?1
        ORDER BY s.started_at
        """)
        stmt.bind(1, sessionId)
        var out: [SessionHitGroup] = []
        while stmt.step() {
            out.append(SessionHitGroup(sessionId: stmt.text(0) ?? "", title: stmt.text(1) ?? "",
                                       projectId: stmt.int64(8),
                                       projectName: stmt.text(2) ?? "", projectCwd: stmt.text(3) ?? "",
                                       startedAt: stmt.text(4), endedAt: stmt.text(5),
                                       hitCount: stmt.int(6), isSidechain: true,
                                       agentType: stmt.text(7), previews: []))
        }
        return out
    }
}
