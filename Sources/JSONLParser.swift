import Foundation

/// 解析 Claude Code 的会话记录文件（~/.claude/projects/**/*.jsonl）。
///
/// 文件是**只追加**写入的，所以增量索引只需从上次的字节偏移量继续读。
/// 唯一的陷阱是文件可能正在被写入 —— 末尾可能是半行 JSON，
/// 因此只消费以换行符结尾的完整行，并把偏移量停在最后一个换行符之后。
enum JSONLParser {

    /// 单个 tool_use / tool_result 正文的截断上限（字节）。
    /// 工具输出动辄几十 KB，全量索引意义不大且会让库膨胀。
    static let toolTextLimit = 4096

    /// 从 `fromOffset` 开始增量解析一个 jsonl 文件。
    /// - Parameter startSeq: 已索引的消息条数，新消息的 seq 从这里往后排。
    static func parse(path: String, fromOffset: UInt64, startSeq: Int) throws -> ParseResult {
        var result = ParseResult()
        result.consumedBytes = fromOffset

        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }

        try handle.seek(toOffset: fromOffset)
        guard let data = try handle.readToEnd(), !data.isEmpty else { return result }

        // 只处理到最后一个换行符为止，半行留给下次
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return result }
        let complete = data[data.startIndex...lastNewline]
        result.consumedBytes = fromOffset + UInt64(complete.count)

        var seq = startSeq
        complete.split(separator: 0x0A, omittingEmptySubsequences: true).forEach { lineBytes in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any] else { return }
            ingest(obj, into: &result, seq: &seq)
        }
        return result
    }

    // MARK: - 单行分派

    private static func ingest(_ obj: [String: Any], into result: inout ParseResult, seq: inout Int) {
        let type = obj["type"] as? String ?? ""

        // 会话级字段，任何带这些键的行都可能补齐（后出现的覆盖先出现的）
        if let sid = obj["sessionId"] as? String, !sid.isEmpty { result.meta.sessionId = sid }
        if let cwd = obj["cwd"] as? String { result.meta.cwd = cwd }
        if let br = obj["gitBranch"] as? String { result.meta.gitBranch = br }
        if let v = obj["version"] as? String { result.meta.version = v }
        if let a = obj["agentId"] as? String { result.meta.agentId = a }
        if obj["isSidechain"] as? Bool == true { result.meta.isSidechain = true }
        if let ts = obj["timestamp"] as? String, !ts.isEmpty {
            if result.meta.startedAt == nil || ts < result.meta.startedAt! { result.meta.startedAt = ts }
            if result.meta.endedAt == nil || ts > result.meta.endedAt! { result.meta.endedAt = ts }
        }

        switch type {
        case "ai-title":
            result.meta.aiTitle = obj["aiTitle"] as? String
        case "custom-title":
            result.meta.customTitle = obj["customTitle"] as? String
        case "agent-name":
            result.meta.agentName = obj["agentName"] as? String
        case "user", "assistant":
            extractMessage(obj, role: type, into: &result, seq: &seq)
        default:
            // attachment / system / mode / permission-mode / file-history-* /
            // queue-operation / last-prompt / pr-link / frame-link —— 无可索引正文
            break
        }
    }

    // MARK: - 消息正文提取

    private static func extractMessage(_ obj: [String: Any], role: String,
                                       into result: inout ParseResult, seq: inout Int) {
        guard let message = obj["message"] as? [String: Any] else { return }
        let ts = obj["timestamp"] as? String

        // 工具输出与系统注入同样走 role=user，得把真正是「你说的话」挑出来。
        //
        // 这里用排除法而不是枚举法。早期版本的记录**没有 origin 字段**
        // （只有 promptSource: "typed"），按「必须 origin.kind == human」判定
        // 会把几百条真实提问误判成工具输出而隐藏掉。promptSource 的取值
        // 还会随版本增加，枚举白名单同样会漏。
        let isHuman: Bool = {
            guard role == "user" else { return false }
            if obj["isMeta"] as? Bool == true { return false }   // 系统注入的上下文
            let originKind = (obj["origin"] as? [String: Any])?["kind"] as? String
            if originKind == "human" { return true }
            if originKind == "task-notification" { return false }
            if (obj["promptSource"] as? String) == "system" { return false }
            return true
        }()

        func append(_ kind: MessageKind, _ text: String, tool: String? = nil) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.messages.append(MessageRow(seq: seq, role: role, timestamp: ts,
                                              kind: kind, toolName: tool, text: trimmed))
            seq += 1
        }

        switch message["content"] {
        case let s as String:
            // 斜杠命令在记录里是一整段 <command-name>… XML。它是你的操作，
            // 但不是提问，压成 `/foo` 才读得下去。
            if let slash = Self.slashCommand(in: s) {
                append(.text, slash)
                break
            }
            append(isHuman ? .text : .toolResult, s)
            if isHuman, result.meta.firstPrompt == nil {
                result.meta.firstPrompt = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }

        case let blocks as [[String: Any]]:
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    append(.text, block["text"] as? String ?? "")

                case "thinking":
                    // thinking.signature 是几百字节 base64，索引它毫无意义
                    append(.thinking, block["thinking"] as? String ?? "")

                case "tool_use":
                    let name = block["name"] as? String
                    let input = block["input"] ?? [:]
                    append(.toolUse, jsonSummary(input), tool: name)

                case "tool_result":
                    append(.toolResult, flattenToolResult(block["content"]))

                default:
                    break
                }
            }

        default:
            break
        }
    }

    // MARK: - 辅助

    /// 从 `<command-name>/foo</command-name><command-args>bar</command-args>…`
    /// 里取出 `/foo bar`。不是斜杠命令则返回 nil。
    private static func slashCommand(in s: String) -> String? {
        guard s.hasPrefix("<command-name>") else { return nil }
        func tag(_ name: String) -> String? {
            guard let open = s.range(of: "<\(name)>"),
                  let close = s.range(of: "</\(name)>", range: open.upperBound..<s.endIndex)
            else { return nil }
            let value = s[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        guard let name = tag("command-name") else { return nil }
        return [name, tag("command-args")].compactMap { $0 }.joined(separator: " ")
    }

    /// tool_use.input 序列化成可搜索文本（保留中文，不转义 unicode）
    private static func jsonSummary(_ value: Any) -> String {
        if let s = value as? String { return truncate(s) }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value,
                                                     options: [.withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else {
            return truncate(String(describing: value))
        }
        return truncate(s)
    }

    /// tool_result.content 可能是 String，也可能是 [{type:text,text:...}]
    private static func flattenToolResult(_ value: Any?) -> String {
        switch value {
        case let s as String:
            return truncate(s)
        case let blocks as [[String: Any]]:
            let texts = blocks.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }
            return truncate(texts.joined(separator: "\n"))
        default:
            return ""
        }
    }

    /// 按字节安全截断（不切断多字节字符）
    private static func truncate(_ s: String) -> String {
        guard s.utf8.count > toolTextLimit else { return s }
        var end = s.utf8.index(s.utf8.startIndex, offsetBy: toolTextLimit)
        // 回退到字符边界
        while end > s.utf8.startIndex, String(s.utf8[s.utf8.startIndex..<end]) == nil {
            end = s.utf8.index(before: end)
        }
        return (String(s.utf8[s.utf8.startIndex..<end]) ?? String(s.prefix(1500))) + "…"
    }
}
