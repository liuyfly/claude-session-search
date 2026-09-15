import Foundation

/// 从 jsonl 里提取出的一个可索引文本块。
/// 一条 assistant 消息可能产出多块（thinking + text + 多个 tool_use）。
struct MessageRow: Sendable {
    var seq: Int
    var role: String            // user | assistant
    var timestamp: String?      // ISO8601
    var kind: MessageKind
    var toolName: String?
    var text: String
}

enum MessageKind: String, Sendable {
    case text
    case thinking
    case toolUse = "tool_use"
    case toolResult = "tool_result"
}

/// 会话级属性，由散落在各行的元数据行汇总而来。
struct SessionMeta: Sendable {
    var sessionId: String = ""
    var cwd: String?
    var gitBranch: String?
    var version: String?

    /// 标题候选，优先级见 `resolvedTitle`
    var aiTitle: String?
    var customTitle: String?
    var agentName: String?
    var firstPrompt: String?

    /// 最后的兜底：会话里第一条正文（部分会话既没有生成标题，
    /// 也没有 origin.kind=human 的开场消息，比如被 spawn 的子 agent）
    var firstAnyText: String?

    var startedAt: String?
    var endedAt: String?
    var isSidechain = false
    var agentId: String?

    /// 解析出的标题与其来源。
    ///
    /// 用户显式改过的名字（custom-title / agent-name，即 CLI 里改的那个）
    /// 必须盖过 Claude 自动生成的 ai-title —— 你把会话命名成「ISSUE-123」，
    /// 就是不想再看那句自动摘要。Claude CLI 自己也是这么显示的。
    var resolvedTitle: (text: String, source: String) {
        if let t = customTitle, !t.isEmpty { return (t, "custom") }
        if let t = agentName, !t.isEmpty { return (t, "agent") }
        if let t = aiTitle, !t.isEmpty { return (t, "ai") }
        if let t = firstPrompt, !t.isEmpty { return (Self.oneLine(t), "prompt") }
        if let t = firstAnyText, !t.isEmpty { return (Self.oneLine(t), "first") }
        // 标题会存进数据库，不能带语言。存哨兵值，显示时再按当前语言翻译。
        return (Self.untitledSentinel, "none")
    }

    /// 无标题会话在库里的占位值。语言无关，因此切换语言不需要重建索引。
    static let untitledSentinel = "\u{0}untitled"

    private static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return String(flat.trimmingCharacters(in: .whitespaces).prefix(80))
    }
}

/// 子 agent 的 .meta.json
struct AgentMeta: Decodable, Sendable {
    var agentType: String?
    var description: String?
    var spawnDepth: Int?
}

/// 单个 jsonl 文件的一次（增量）解析结果
struct ParseResult: Sendable {
    var messages: [MessageRow] = []
    var meta = SessionMeta()
    /// 本次已完整消费到的字节偏移量（只统计以换行结尾的完整行，
    /// 避免把正在写入的半行当成数据）
    var consumedBytes: UInt64 = 0
}

/// 搜索结果里的单条命中
struct Hit: Identifiable, Sendable {
    var id: Int64               // messages.id
    var sessionId: String
    var seq: Int
    var role: String
    var kind: String
    var timestamp: String?
    /// 已标注命中区间的片段，命中处用 \u{1}…\u{2} 包裹
    var snippet: String
}

/// 搜索结果按会话聚合后的一行
struct SessionHitGroup: Identifiable, Sendable {
    var id: String { sessionId }
    var sessionId: String

    /// 子 agent 的库内主键是「父会话 uuid : agent 文件名」合成的。
    /// 凡是要对上磁盘上那个 jsonl 的场合（比对 FSEvents 路径、拼 `claude --resume`）
    /// 都只能用父会话那半 —— 合成主键在文件系统里不存在。
    static func fileKey(of sessionId: String) -> String {
        sessionId.split(separator: ":", maxSplits: 1).first.map(String.init) ?? sessionId
    }

    var fileKey: String { Self.fileKey(of: sessionId) }
    var title: String
    /// 所属项目。用来判断「切项目后当前选中的会话是否还在新范围里」——
    /// 没有它就只能一切项目就清空选中会话，那会被侧栏的顺序抖动误伤。
    var projectId: Int64 = 0
    var projectName: String
    var projectCwd: String
    var startedAt: String?
    var endedAt: String?
    var hitCount: Int
    var isSidechain: Bool
    var agentType: String?
    var previews: [Hit]
    /// 命中里有多少条来自这个会话派发的子 agent。
    /// 子 agent 不作为独立会话列出，它们的命中归并到父会话上。
    var subagentHits: Int = 0

    /// 界面上显示的标题。库里存的是语言无关的哨兵值，这里按当前语言翻译，
    /// 于是切换语言无需重建索引。
    @MainActor
    var displayTitle: String {
        title == SessionMeta.untitledSentinel ? L.untitledSession : title
    }
}

/// 搜索走了哪条路径 —— 用于在 UI 上说明「短词已自动降级为子串搜索」
enum SearchStrategy: Sendable {
    case fts            // FTS5 trigram 索引
    case substring      // LIKE 全表扫描（查询含 <3 字符的词）
    case empty
}

struct SearchOutcome: Sendable {
    var groups: [SessionHitGroup] = []
    var strategy: SearchStrategy = .empty
    var totalHits: Int = 0
    var elapsedMs: Double = 0
    var truncated: Bool = false
}

/// 会话正文视图里的一条消息
struct DetailMessage: Identifiable, Sendable {
    var id: Int64
    var seq: Int
    var role: String
    var kind: String
    var toolName: String?
    var timestamp: String?
    var text: String
}

struct ProjectRow: Identifiable, Hashable, Sendable {
    var id: Int64
    var dirName: String
    var cwd: String
    var displayName: String
    var sessionCount: Int
    var lastActiveAt: String?
}
