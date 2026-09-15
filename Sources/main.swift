import Foundation

// 一个二进制同时承担 CLI 自检与 GUI：
//   ClaudeSessionSearch --selftest          无界面跑断言（有语料就连索引一起验）
//   ClaudeSessionSearch --selftest --pure   只跑不依赖语料的那档
//   ClaudeSessionSearch --reindex    重建索引后退出
//   ClaudeSessionSearch             启动界面
// 因此这里用 top-level code 而不是 @main，手动分派入口。

let args = CommandLine.arguments
let dbPath: String = {
    if let i = args.firstIndex(of: "--db"), i + 1 < args.count { return args[i + 1] }
    return Store.defaultPath
}()

if args.contains("--selftest") {
    // 默认自动判断：磁盘上有会话记录就连语料断言一起跑，没有就只跑纯函数档。
    // --pure 强制只跑纯函数档（CI 上用，那里不会有 ~/.claude/projects）。
    let scope: SelfTest.Scope =
        args.contains("--pure") ? .pure : (SelfTest.hasCorpus() ? .full : .pure)
    exit(SelfTest.run(dbPath: dbPath, scope: scope))
}

if let i = args.firstIndex(of: "--recover") {
    // 从 history.jsonl 挖回已被 cleanupPeriodDays 清掉的会话（只有提问）
    guard i + 1 < args.count else { print("用法: --recover <输出目录>"); exit(2) }
    exit(Bench.recover(outDir: args[i + 1]))
}

if args.contains("--usage") {
    // 走的是 GUI 里同一条 UsageProbe 路径，确认 spawn claude 真能拿到数据
    exit(Bench.usage())
}

if let i = args.firstIndex(of: "--export-project") {
    guard i + 2 < args.count else {
        print("用法: --export-project <项目名片段> <输出目录>"); exit(2)
    }
    exit(Bench.exportProject(dbPath: dbPath, needle: args[i + 1], outDir: args[i + 2]))
}

if let i = args.firstIndex(of: "--export") {
    // 让导出能在没有 GUI 的情况下真实写一遍盘 —— 光断言格式串不够，
    // 文件名、编码、目录创建这些只有落地才暴露问题
    guard i + 2 < args.count else {
        print("用法: --export <会话id 或 标题片段> <输出目录> [--with-tools]"); exit(2)
    }
    exit(Bench.exportOne(dbPath: dbPath, needle: args[i + 1], outDir: args[i + 2],
                         includeTools: args.contains("--with-tools")))
}

if let i = args.firstIndex(of: "--bench") {
    guard i + 1 < args.count else { print("用法: --bench <会话id 或 标题片段>"); exit(2) }
    exit(Bench.run(dbPath: dbPath, needle: args[i + 1]))
}

if args.contains("--reindex") || args.contains("--rebuild") {
    // --rebuild 丢弃已索引内容重新解析；--reindex 只补增量
    let rebuild = args.contains("--rebuild")
    do {
        let store = try Store(path: dbPath)
        let stats = try Indexer(store: store).indexAll(rebuild: rebuild, onProgress: { p in
            if p.scanned % 25 == 0 || p.scanned == p.total {
                FileHandle.standardError.write("\r  \(p.scanned)/\(p.total)".data(using: .utf8)!)
            }
        })
        print(String(format: "\n%@%d 项目 / %d 会话 / %d 子 agent / 新增 %d 条 / 跳过 %d / 清理 %d / %.1fs",
                     stats.rebuilt ? "[已重建] " : "",
                     stats.projects, stats.sessions, stats.subagents,
                     stats.newMessages, stats.skipped, stats.pruned, stats.elapsed))
        exit(stats.failed.isEmpty ? 0 : 1)
    } catch {
        print("索引失败: \(error)")
        exit(1)
    }
}

if args.contains("--search") {
    guard let i = args.firstIndex(of: "--search"), i + 1 < args.count else {
        print("用法: --search <关键词>"); exit(2)
    }
    do {
        let store = try Store(path: dbPath)
        let outcome = try store.search(query: args[i + 1], filter: SearchFilter())
        let path = outcome.strategy == .fts ? "FTS5" : "子串扫描"
        print(String(format: "%d 命中 / %d 会话 · %@ · %.1f ms%@",
                     outcome.totalHits, outcome.groups.count, path, outcome.elapsedMs,
                     outcome.truncated ? " (已截断)" : ""))
        for g in outcome.groups.prefix(15) {
            let when = g.endedAt?.prefix(10) ?? "?"
            print("\n▸ \(g.title)   [\(g.projectName) · \(when) · \(g.hitCount) 条命中]")
            for p in g.previews {
                let s = p.snippet
                    .replacingOccurrences(of: hlOpen, with: "\u{1B}[43m\u{1B}[30m")
                    .replacingOccurrences(of: hlClose, with: "\u{1B}[0m")
                    .replacingOccurrences(of: "\n", with: " ")
                print("    \(p.role == "user" ? "我" : "AI")· \(s)")
            }
        }
        exit(0)
    } catch {
        print("搜索失败: \(error)")
        exit(1)
    }
}

AppEntry.main()
