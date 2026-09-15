import Foundation

/// 把会话导出成文件。
///
/// 全是纯函数、不碰 UI、不依赖 `L` —— 因此可以在后台线程跑，也能被自检直接断言。
/// 导出物里的时间和标签刻意**不跟界面语言变**：文件是给以后的自己和工具读的，
/// 换个语言打开就对不上字段名反而麻烦。
enum Export {

    // MARK: - 单个会话 → Markdown

    /// - Parameter messages: 已按 seq 排好的正文。传进来什么就导什么 ——
    ///   要不要含工具记录由调用方决定，这里不再过滤。
    static func markdown(session: SessionHitGroup, messages: [DetailMessage]) -> String {
        var out = "# \(title(of: session))\n\n"

        let convo = messages.filter { $0.kind == "text" || $0.kind == "thinking" }
        out += "| | |\n|---|---|\n"
        out += "| Session ID | `\(session.fileKey)` |\n"
        if session.sessionId != session.fileKey {
            // 子 agent：库内主键是合成的，把 agent 那半也标出来
            out += "| Subagent | `\(session.sessionId)` |\n"
        }
        out += "| Project | \(session.projectName) (`\(session.projectCwd)`) |\n"
        out += "| Started | \(stamp(session.startedAt)) |\n"
        out += "| Ended | \(stamp(session.endedAt)) |\n"
        out += "| Messages | \(messages.count) (conversation \(convo.count)) |\n"
        out += "| Exported | \(stampNow()) |\n\n---\n\n"

        for m in messages {
            out += block(m)
        }
        return out
    }

    /// 一条消息。对话正文直接铺开，thinking 和工具记录降一级并裹进代码块 ——
    /// 工具输出里常有 `#`、`|`、``` 这类字符，不裹会把 Markdown 结构冲垮。
    private static func block(_ m: DetailMessage) -> String {
        let when = m.timestamp.map { " · \(stamp($0))" } ?? ""
        switch m.kind {
        case "text":
            let who = m.role == "user" ? "Me" : "Claude"
            return "## \(who)\(when)\n\n\(m.text)\n\n"
        case "thinking":
            return "### 💭 Thinking\(when)\n\n\(fence(m.text))\n\n"
        case "tool_use":
            return "### 🔧 \(m.toolName ?? "tool")\(when)\n\n\(fence(m.text))\n\n"
        case "tool_result":
            return "### ↩︎ \(m.toolName ?? "result")\(when)\n\n\(fence(m.text))\n\n"
        default:
            return "### \(m.kind)\(when)\n\n\(fence(m.text))\n\n"
        }
    }

    /// 用足够长的围栏，免得正文里本来就有 ``` 把代码块提前截断
    static func fence(_ text: String) -> String {
        var ticks = 3
        // 找出正文里最长的一串反引号，围栏必须比它长
        var run = 0
        for ch in text {
            if ch == "`" {
                run += 1
                ticks = max(ticks, run + 1)
            } else {
                run = 0
            }
        }
        let bar = String(repeating: "`", count: ticks)
        return "\(bar)\n\(text)\n\(bar)"
    }

    // MARK: - 项目 → 会话清单 CSV

    /// `session_id` 对子 agent 给的是**父会话** id（能直接 `claude --resume`），
    /// 所以同一会话派出的多个 agent 在这一列上是重复的 —— 要唯一定位得看
    /// `agent_file`，那才是磁盘上那个 agent-*.jsonl 的名字。
    static let csvColumns = [
        "session_id", "agent_file", "title", "project", "cwd", "started_at", "ended_at",
        "messages", "conversation_messages", "is_subagent", "agent_type", "file",
    ]

    /// 一行一个会话。用 CSV 而不是 Markdown 表格 —— 这份东西是拿来排序、
    /// 统计、丢进 Excel 的，正文另存成每会话一个 .md。
    static func csv(rows: [SessionSummary]) -> String {
        var out = csvColumns.joined(separator: ",") + "\n"
        for r in rows {
            let agentFile = r.session.sessionId != r.session.fileKey
                ? String(r.session.sessionId.split(separator: ":", maxSplits: 1).last ?? "")
                : ""
            out += [
                r.session.fileKey,
                agentFile,
                title(of: r.session),
                r.session.projectName,
                r.session.projectCwd,
                r.session.startedAt ?? "",
                r.session.endedAt ?? "",
                String(r.totalMessages),
                String(r.conversationMessages),
                r.session.isSidechain ? "yes" : "no",
                r.session.agentType ?? "",
                r.fileName,
            ].map(csvField).joined(separator: ",") + "\n"
        }
        return out
    }

    /// CSV 转义：含逗号、引号、换行的字段要用双引号包起来，内部引号翻倍。
    /// 会话标题里出现逗号和换行都很常见，漏了这步整份文件的列就错位了。
    static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else {
            return s
        }
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    struct SessionSummary {
        var session: SessionHitGroup
        var totalMessages: Int
        var conversationMessages: Int
        /// 这个会话的正文导到了哪个文件，好让 CSV 能对回去
        var fileName: String
    }

    // MARK: - 整个项目落盘

    /// 在 `root` 下建一层带时间戳的目录，写入 `index.csv` 和每个会话的 Markdown。
    ///
    /// 取正文的动作用闭包传进来，这样 GUI（走 actor、async）和 CLI（直连 Store、同步）
    /// 能共用同一份落盘逻辑 —— 否则两边各写一遍，改一处忘一处。
    /// - Parameter fetch: 给定会话 id，返回对话正文和被略过的工具记录条数
    static func writeProject(
        name: String,
        sessions: [SessionHitGroup],
        into root: URL,
        fetch: (String) async throws -> (msgs: [DetailMessage], toolCount: Int)
    ) async throws -> (files: Int, dir: URL) {
        let stamp = stampNow()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let base = sanitize(name)
        let dir = root.appendingPathComponent("\(base.isEmpty ? "project" : base)-\(stamp)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var rows: [SessionSummary] = []
        var written = 0
        for (i, s) in sessions.enumerated() {
            let got = try await fetch(s.sessionId)
            let file = fileName(for: s, index: i + 1)
            try markdown(session: s, messages: got.msgs)
                .write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            written += 1
            rows.append(SessionSummary(session: s,
                                       totalMessages: got.msgs.count + got.toolCount,
                                       conversationMessages: got.msgs.count,
                                       fileName: file))
        }

        try csv(rows: rows)
            .write(to: dir.appendingPathComponent("index.csv"), atomically: true, encoding: .utf8)
        return (written + 1, dir)
    }

    // MARK: - 文件名

    /// 会话标题直接拿来当文件名会炸：`/` 是路径分隔符，`:` 在 Finder 里显示成 `/`，
    /// 前导 `.` 会变成隐藏文件，尾随空格和句点在某些工具链上也有麻烦。
    /// 再加上 id 前 8 位，避免同名标题互相覆盖。
    static func fileName(for session: SessionHitGroup, index: Int? = nil) -> String {
        var name = sanitize(title(of: session))
        if name.isEmpty { name = "session" }
        // 文件系统上限 255 字节，中文一个字 3 字节，留足余量给后缀
        if name.count > 60 { name = String(name.prefix(60)) }
        let prefix = index.map { String(format: "%03d-", $0) } ?? ""
        return "\(prefix)\(name)-\(idSuffix(of: session)).md"
    }

    /// 文件名尾巴上那串短 id。
    ///
    /// 子 agent 必须用 agent 那半：同一个父会话可以派出几十个 agent，
    /// 全用父会话 id 的话它们的文件名只差标题，标题重复（"Explore xxx" 很常见）
    /// 就会互相覆盖 —— 单个会话导出时没有序号前缀兜底，覆盖是静默的。
    static func idSuffix(of session: SessionHitGroup) -> String {
        if session.sessionId != session.fileKey,
           let agent = session.sessionId.split(separator: ":", maxSplits: 1).last {
            return String(agent.suffix(8))
        }
        return String(session.fileKey.prefix(8))
    }

    static func sanitize(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t\0")
        let cleaned = s.components(separatedBy: illegal).joined(separator: " ")
        return cleaned
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // 前导句点会成为隐藏文件；尾随句点在归档工具里易出问题
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: -

    /// 无标题会话在库里存的是语言无关的哨兵值，导出时给个固定英文占位
    static func title(of session: SessionHitGroup) -> String {
        session.title == SessionMeta.untitledSentinel || session.title.isEmpty
            ? "(untitled session)"
            : session.title
    }

    /// jsonl 里的时间戳是带毫秒的 UTC ISO8601，导出时转成本地时区的可读形式
    static func stamp(_ iso: String?) -> String {
        guard let iso, let d = When.date(iso) else { return "—" }
        return formatter.string(from: d)
    }

    static func stampNow() -> String { formatter.string(from: Date()) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
