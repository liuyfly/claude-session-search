import Foundation

/// 从 `~/.claude/history.jsonl` 里挖回已被清理的会话。
///
/// Claude Code 默认只保留 30 天的会话正文（`cleanupPeriodDays`，实测默认 30），
/// 到期静默删除。但 `history.jsonl` 不受这个窗口约束 —— 实测它回溯到 4 月，
/// 里面每条记录带 `sessionId` / `project` / `timestamp` / `display`。
///
/// **能救回的只有你自己发的提问，没有 Claude 的回复，也没有工具调用。**
/// 那些只存在于已被删掉的 jsonl 里。所以这是残卷，不是原文 ——
/// 但「当时问过什么」往往已经够想起那次对话在干什么了。
enum Recover {

    static var historyPath: String {
        NSHomeDirectory() + "/.claude/history.jsonl"
    }

    struct Entry {
        var sessionId: String
        var project: String
        var timestamp: Date
        var text: String
        /// 提问时粘贴进去的内容（`history.jsonl` 里也存了一份）
        var pasted: [String]
    }

    struct LostSession {
        var sessionId: String
        var project: String
        var entries: [Entry]
        var first: Date { entries.first?.timestamp ?? .distantPast }
        var last: Date { entries.last?.timestamp ?? .distantPast }
    }

    // MARK: - 读取

    static func readHistory() -> [Entry] {
        guard let data = FileManager.default.contents(atPath: historyPath),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [Entry] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let sid = o["sessionId"] as? String,
                  let display = o["display"] as? String else { continue }
            // 时间戳是毫秒
            let ms = (o["timestamp"] as? Double) ?? 0
            var pasted: [String] = []
            // pastedContents 的形状是 { "1": { "content": "…" }, … }
            if let p = o["pastedContents"] as? [String: Any] {
                for (_, v) in p {
                    if let item = v as? [String: Any], let c = item["content"] as? String {
                        pasted.append(c)
                    }
                }
            }
            out.append(Entry(sessionId: sid,
                             project: (o["project"] as? String) ?? "",
                             timestamp: Date(timeIntervalSince1970: ms / 1000),
                             text: display,
                             pasted: pasted))
        }
        return out
    }

    /// 磁盘上还在的会话 id。history 里出现而这里没有的，就是被清理掉的。
    static func aliveSessionIds() -> Set<String> {
        let fm = FileManager.default
        let root = Indexer.defaultRoot
        var ids = Set<String>()
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "jsonl" {
                ids.insert(f.deletingPathExtension().lastPathComponent)
            }
        }
        return ids
    }

    /// 已被清理、但 history 里还留着提问的会话，按时间正序
    static func lostSessions() -> [LostSession] {
        let alive = aliveSessionIds()
        var grouped: [String: [Entry]] = [:]
        for e in readHistory() where !alive.contains(e.sessionId) {
            grouped[e.sessionId, default: []].append(e)
        }
        return grouped.map { sid, entries in
            let sorted = entries.sorted { $0.timestamp < $1.timestamp }
            return LostSession(sessionId: sid,
                               project: sorted.first?.project ?? "",
                               entries: sorted)
        }
        .sorted { $0.first < $1.first }
    }

    // MARK: - 落盘

    /// 每个丢失的会话写一份 Markdown，外加一份 index.csv。
    /// - Returns: 写出的文件数和目录
    static func writeArchive(into root: URL) throws -> (files: Int, sessions: Int, prompts: Int, dir: URL) {
        let lost = lostSessions()
        let stamp = Export.stampNow()
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "-")
        let dir = root.appendingPathComponent("recovered-prompts-\(stamp)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var csv = "session_id,project,first_prompt_at,last_prompt_at,prompts,file\n"
        var files = 0
        var prompts = 0
        for (i, s) in lost.enumerated() {
            let name = fileName(for: s, index: i + 1)
            try markdown(s).write(to: dir.appendingPathComponent(name),
                                  atomically: true, encoding: .utf8)
            files += 1
            prompts += s.entries.count
            csv += [s.sessionId, s.project,
                    Export.stamp(iso8601(s.first)), Export.stamp(iso8601(s.last)),
                    String(s.entries.count), name]
                .map(Export.csvField).joined(separator: ",") + "\n"
        }
        try csv.write(to: dir.appendingPathComponent("index.csv"),
                      atomically: true, encoding: .utf8)
        return (files + 1, lost.count, prompts, dir)
    }

    private static func fileName(for s: LostSession, index: Int) -> String {
        // 没有标题可用（标题在被删掉的 jsonl 里），拿第一条提问当名字
        var stem = Export.sanitize(Highlight.flatten(s.entries.first?.text ?? ""))
        if stem.isEmpty { stem = "session" }
        if stem.count > 50 { stem = String(stem.prefix(50)) }
        return String(format: "%03d-%@-%@.md", index, stem, String(s.sessionId.prefix(8)))
    }

    static func markdown(_ s: LostSession) -> String {
        var out = "# \(Highlight.flatten(String((s.entries.first?.text ?? "").prefix(80))))\n\n"
        out += "> ⚠️ 这是从 `history.jsonl` 重建的**残卷**：只有你发出的提问，\n"
        out += "> 没有 Claude 的回复和工具调用 —— 那些随原始 jsonl 一起被清理了。\n\n"
        out += "| | |\n|---|---|\n"
        out += "| Session ID | `\(s.sessionId)` |\n"
        out += "| Project | `\(s.project)` |\n"
        out += "| First prompt | \(Export.stamp(iso8601(s.first))) |\n"
        out += "| Last prompt | \(Export.stamp(iso8601(s.last))) |\n"
        out += "| Prompts | \(s.entries.count) |\n"
        out += "| Recovered | \(Export.stampNow()) |\n\n---\n\n"

        for e in s.entries {
            out += "## Me · \(Export.stamp(iso8601(e.timestamp)))\n\n\(e.text)\n\n"
            for p in e.pasted {
                out += "**粘贴的内容：**\n\n\(Export.fence(p))\n\n"
            }
        }
        return out
    }

    /// `Export.stamp` 吃的是 ISO 字符串，这里把 Date 转过去
    private static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
