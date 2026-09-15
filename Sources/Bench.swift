import Foundation
import SwiftUI

/// `--bench <sessionId|标题片段>`：量化打开一个会话时各段耗时。
///
/// 存在的理由：详情区「卡很久」这种反馈，靠读代码只能猜。
/// 这里把每段单独计时，改完再跑一次就知道优化落在了哪。
enum Bench {

    static func run(dbPath: String, needle: String) -> Int32 {
        do {
            let store = try Store(path: dbPath)
            guard let sid = try resolve(store: store, needle: needle) else {
                print("找不到会话: \(needle)"); return 1
            }
            print("会话 \(sid)\n")

            let msgs = time("Store.messages() 全量查询") {
                (try? store.messages(sessionId: sid)) ?? []
            }
            print("   → \(msgs.count) 条，\(msgs.reduce(0) { $0 + $1.text.utf8.count } / 1024) KB")

            let convo = time("Store.messages(conversationOnly:) 默认口径") {
                (try? store.messages(sessionId: sid, conversationOnly: true)) ?? []
            }
            print("   → \(convo.count) 条，\(convo.reduce(0) { $0 + $1.text.utf8.count } / 1024) KB")

            _ = time("Store.toolMessageCount()") {
                (try? store.toolMessageCount(sessionId: sid)) ?? 0
            }

            let visible = time("过滤出可见正文（单次）") {
                msgs.filter { $0.kind == "text" || $0.kind == "thinking" }
            }
            print("   → \(visible.count) 条，\(visible.reduce(0) { $0 + $1.text.utf8.count } / 1024) KB")

            // SwiftUI 一帧里会多次读 computed property，按 10 次算
            _ = time("过滤 ×10（模拟 computed 被反复读）") { () -> Int in
                var n = 0
                for _ in 0..<10 {
                    n += msgs.filter { $0.kind == "text" || $0.kind == "thinking" }.count
                }
                return n
            }

            MainActor.assumeIsolated {
                _ = time("When.short() × 每条可见消息") {
                    visible.map { When.short($0.timestamp) }
                }
                _ = time("When.short() 再来一遍（formatter 已缓存）") {
                    visible.map { When.short($0.timestamp) }
                }
            }

            _ = time("Highlight.attributedText 无查询词") {
                visible.map { Highlight.attributedText($0.text, terms: []) }
            }

            _ = time("Highlight.attributedText 带查询词") {
                visible.map { Highlight.attributedText($0.text, terms: ["error"]) }
            }

            // 上面两项是没有截断、没有缓存的原始成本。下面是实际走的路径。
            MainActor.assumeIsolated {
                _ = time("实际路径：截断 + TextCache（首次）") {
                    visible.map { m -> AttributedString in
                        let c = Highlight.clip(m.text, expanded: false)
                        return TextCache.attributed(id: m.id, text: c.shown, terms: ["error"],
                                                    clipped: c.hidden > 0, mono: false)
                    }
                }
                _ = time("实际路径：重绘（全部命中缓存）") {
                    visible.map { m -> AttributedString in
                        let c = Highlight.clip(m.text, expanded: false)
                        return TextCache.attributed(id: m.id, text: c.shown, terms: ["error"],
                                                    clipped: c.hidden > 0, mono: false)
                    }
                }
            }

            // 匹配的几条路径。查找条（⌘F）**每敲一个字符**都要跑一次，
            // 所以这几行的差值直接决定打字手感 —— 选字节匹配就是照这个表定的。
            _ = time("命中匹配·现算 lowercased + String.contains（旧路径）") { () -> [Int64] in
                let lowered = ["error"]
                return visible.filter { (m: DetailMessage) -> Bool in
                    let t = m.text.lowercased()
                    return lowered.allSatisfy { t.contains($0) }
                }.map { $0.id }
            }
            let preLowered = time("命中匹配·预先小写成 String") {
                visible.map { $0.text.lowercased() }
            }
            _ = time("命中匹配·String.contains") { () -> Int in
                preLowered.filter { $0.contains("error") }.count
            }
            _ = time("命中匹配·range(of:options:.literal)") { () -> Int in
                preLowered.filter { $0.range(of: "error", options: .literal) != nil }.count
            }
            let preBytes = time("命中匹配·预先小写成 UTF8 字节（加载时付一次）") {
                visible.map { AppModel.haystack(id: $0.id, text: $0.text) }
            }
            _ = time("命中匹配·字节匹配（实际路径，每次按键付）") {
                AppModel.matchIds(in: preBytes, terms: ["error"])
            }

            // Markdown 渲染的成本。它只作用在 Claude 的正式回复上。
            let replies = visible.filter { $0.role == "assistant" && $0.kind == "text" }
            print("   → 其中 Claude 回复 \(replies.count) 条")
            let parsed = time("Markdown·块级切分（每条一次，有缓存）") {
                replies.map { Markdown.blocks(Highlight.clip($0.text, expanded: false).shown) }
            }
            print("   → 切出 \(parsed.reduce(0) { $0 + $1.count }) 个块")
            MainActor.assumeIsolated {
                _ = time("Markdown·行内解析全部块（首次，无缓存）") { () -> Int in
                    var n = 0
                    for bs in parsed {
                        for b in bs {
                            switch b.kind {
                            case .paragraph(let t), .quote(let t), .heading(_, let t):
                                n += Markdown.inline(t, terms: ["error"], base: .body)
                                    .characters.count
                            case .listItem(_, let t, _):
                                n += Markdown.inline(t, terms: ["error"], base: .body)
                                    .characters.count
                            case .code(_, let t):
                                n += Markdown.plain(t, terms: ["error"], base: .body)
                                    .characters.count
                            case .table(let h, let rs, _):
                                for cell in h + rs.flatMap({ $0 }) {
                                    n += Markdown.inline(cell, terms: ["error"], base: .callout)
                                        .characters.count
                                }
                            case .rule: break
                            }
                        }
                    }
                    return n
                }
            }

            // 上面几项加起来是「数据层」的成本。真正贵的是文本排版：
            // scrollTo 底部锚点要求 LazyVStack 算出全部行高，等于把每条正文
            // 都排一遍。用 TextKit 直接量，避免把 SwiftUI 的开销当成黑箱。
            MainActor.assumeIsolated {
                _ = time("TextKit 排版全部可见正文（宽 700pt）") {
                    visible.reduce(0.0) { acc, m in acc + Self.layoutHeight(m.text, width: 700) }
                }
                _ = time("TextKit 排版·截断到 \(Highlight.inlineLimit) 字（实际口径）") {
                    visible.reduce(0.0) { acc, m in
                        acc + Self.layoutHeight(Highlight.clip(m.text, expanded: false).shown,
                                                width: 700)
                    }
                }
            }

            return 0
        } catch {
            print("bench 失败: \(error)")
            return 1
        }
    }

    /// 真实写一遍导出物，顺带打印体量对比。
    static func exportOne(dbPath: String, needle: String, outDir: String,
                          includeTools: Bool) -> Int32 {
        do {
            let store = try Store(path: dbPath)
            guard let sid = try resolve(store: store, needle: needle),
                  let session = try store.session(id: sid) else {
                print("找不到会话: \(needle)"); return 1
            }
            let msgs = try store.messages(sessionId: sid, conversationOnly: !includeTools)
            let md = Export.markdown(session: session, messages: msgs)
            let dir = URL(fileURLWithPath: outDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = Export.fileName(for: session)
            let url = dir.appendingPathComponent(name)
            try md.write(to: url, atomically: true, encoding: .utf8)

            let bytes = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            print("""
            会话 \(sid)
              口径     \(includeTools ? "完整记录（含工具）" : "仅对话")
              消息     \(msgs.count) 条
              文件     \(name)
              大小     \(bytes / 1024) KB
              路径     \(url.path)
            """)
            return 0
        } catch {
            print("导出失败: \(error)")
            return 1
        }
    }

    /// 整个项目导出跑一遍，和 GUI 走的是同一个 `Export.writeProject`
    static func exportProject(dbPath: String, needle: String, outDir: String) -> Int32 {
        do {
            let store = try Store(path: dbPath)
            let all = try store.projects()
            guard let project = all.first(where: {
                $0.displayName.localizedCaseInsensitiveContains(needle)
                    || $0.cwd.localizedCaseInsensitiveContains(needle)
            }) else {
                print("找不到项目: \(needle)\n可选: \(all.map(\.displayName).joined(separator: ", "))")
                return 1
            }
            let sessions = try store.recentSessions(projectId: project.id,
                                                    includeSubagents: true, limit: 100_000)
            let out = try runBlocking {
                try await Export.writeProject(name: project.displayName,
                                              sessions: sessions,
                                              into: URL(fileURLWithPath: outDir)) { sid in
                    ((try? store.messages(sessionId: sid, conversationOnly: true)) ?? [],
                     (try? store.toolMessageCount(sessionId: sid)) ?? 0)
                }
            }
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(atPath: out.dir.path)) ?? []
            let bytes = files.reduce(0) { acc, f in
                acc + (((try? fm.attributesOfItem(atPath: out.dir.appendingPathComponent(f).path)[.size]) as? Int) ?? 0)
            }
            print("""
            项目 \(project.displayName)
              会话     \(sessions.count) 个（含子 agent）
              写出     \(out.files) 个文件，共 \(bytes / 1024) KB
              目录     \(out.dir.path)
            """)
            return 0
        } catch {
            print("导出失败: \(error)")
            return 1
        }
    }

    /// 走 GUI 里同一条 `UsageProbe.fetch()`，确认从进程里 spawn claude 真能拿到数据
    static func usage() -> Int32 {
        print("探测会话目录: \(UsageProbe.projectDirName)")
        do {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let snap = try runBlocking { try await UsageProbe.fetch() }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            print(String(format: "耗时 %.0f ms\n", ms))
            print("解析结果:")
            // 界面上显示的原样。原生 UI 没法截图，这里是唯一能核对最终串的地方。
            func shown(_ raw: String?) -> String {
                guard let raw else { return "—" }
                return MainActor.assumeIsolated { L.usageResetLine(raw) }
            }
            print("  界面显示（会话窗口）: \(shown(snap.sessionResets))")
            print("  界面显示（本周）: \(shown(snap.weekResets))")
            print("  当前会话窗口: \(snap.sessionPercent.map { "\($0)%" } ?? "—")"
                  + (snap.sessionResets.map { " · 重置于 \($0)" } ?? ""))
            print("  本周(全部模型): \(snap.weekPercent.map { "\($0)%" } ?? "—")"
                  + (snap.weekResets.map { " · 重置于 \($0)" } ?? ""))
            for e in snap.extraLimits { print("  \(e.label): \(e.percent)%") }
            print("\n原文 \(snap.raw.count) 字：\n\(snap.raw)")
            return snap.parsedAnything ? 0 : 1
        } catch {
            print("失败: \(error.localizedDescription)")
            return 1
        }
    }

    /// 把已被清理的会话残卷挖出来落盘
    static func recover(outDir: String) -> Int32 {
        let lost = Recover.lostSessions()
        guard !lost.isEmpty else {
            print("history.jsonl 里没有找到已被清理的会话 —— 说明磁盘上的会话是完整的")
            return 0
        }
        let alive = Recover.aliveSessionIds().count
        let prompts = lost.reduce(0) { $0 + $1.entries.count }
        print("""
        磁盘现存会话   \(alive) 个
        已被清理       \(lost.count) 个会话，history 里还留着 \(prompts) 条提问
        最早可回溯到   \(Export.stamp(ISO8601DateFormatter().string(from: lost[0].first)))
        """)
        do {
            let out = try Recover.writeArchive(into: URL(fileURLWithPath: outDir))
            print("""

            已写出 \(out.files) 个文件（\(out.sessions) 个会话 / \(out.prompts) 条提问）
            目录   \(out.dir.path)
            """)
            return 0
        } catch {
            print("写出失败: \(error.localizedDescription)")
            return 1
        }
    }

    /// CLI 是同步的 top-level 代码，用信号量把 async 调用等回来
    private static func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task {
            do { result = .success(try await body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    /// 先按 id 精确找，找不到再按标题模糊找 —— 手敲 uuid 太累
    private static func resolve(store: Store, needle: String) throws -> String? {
        if try store.session(id: needle) != nil { return needle }
        let stmt = try store.prepare(
            "SELECT id FROM sessions WHERE title LIKE ?1 ORDER BY msg_count DESC LIMIT 1")
        stmt.bind(1, "%\(needle)%")
        return stmt.step() ? stmt.text(0) : nil
    }

    /// 用 TextKit 排一段文字并返回高度。只为计时，返回值本身不重要。
    @MainActor
    private static func layoutHeight(_ text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ])
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container).height
    }

    @discardableResult
    private static func time<T>(_ label: String, _ body: () -> T) -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let out = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        print(String(format: "%8.1f ms  %@", ms, label))
        return out
    }
}
