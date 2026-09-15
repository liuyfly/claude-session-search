import Foundation

/// 订阅额度用量。
///
/// 这份数据本地文件里没有 —— `~/.claude/` 下唯一带用量语义的 `stats-cache.json`
/// 早就停更了，额度百分比是 Claude Code 实时向服务端要的。唯一的拿法是
/// 让 `claude` 自己去问：`claude -p "/usage"`。
///
/// 实测两件关键事：
/// 1. 斜杠命令不走模型推理 —— 返回的 usage 全零、`num_turns: 0`，**不消耗额度**，约 1 秒。
/// 2. 每次调用都会在 `~/.claude/projects/` 下留一个会话 jsonl。所以固定 session id
///    反复 `--resume`，只留一个文件；再在索引时跳过它，免得自己污染自己的列表。
struct UsageSnapshot: Sendable {
    /// 原文照存。解析只是为了把关键数字挑大字显示，格式一变解析会失效，
    /// 但原文永远还在 —— 不能因为解析不出来就把信息丢了。
    var raw: String
    var sessionPercent: Int?
    var sessionResets: String?
    var weekPercent: Int?
    var weekResets: String?
    /// `Current week (Fable): 0% used` 这类附加额度
    var extraLimits: [(label: String, percent: Int)] = []
    var fetchedAt: Date

    var parsedAnything: Bool {
        sessionPercent != nil || weekPercent != nil || !extraLimits.isEmpty
    }
}

enum UsageProbe {

    /// 探测用的工作目录。用一个中立目录而不是用户的项目目录，
    /// 免得把 CLAUDE.md、MCP 配置之类无关的东西拖进来。
    static var workDir: URL {
        URL(fileURLWithPath: Store.defaultPath)
            .deletingLastPathComponent()
            .appendingPathComponent("probe")
    }

    /// 旧版本用固定 session id + `--resume` 复用一个探测会话，为的是不让
    /// `~/.claude/projects/` 里堆文件。那个做法会撞会话锁：
    /// 上一次调用没干净退出（超时被 terminate、或进程还没释放），
    /// 下一次 `--resume` 和 `--session-id` 就双双失败，报
    /// `Session ID … is already in use.` —— 用户实测「经常报错」。
    ///
    /// 现在改用 `--no-session-persistence`：压根不写会话文件，
    /// 于是没有 id、没有锁、也不产生垃圾。实测连跑三次全部成功、0 个新增 jsonl。
    /// 这些是旧方案留下的残迹，启动时清掉。
    ///
    /// 只清三样**确实有害**的：会话正文（它会混进会话列表）、会话锁、hook 状态。
    /// 刻意**不动** `workDir` 和 projects 下那个探测目录 —— 取一次用量就会重新
    /// 建出来（Claude Code 会为任何 cwd 建项目目录），每次启动都丢废纸篓
    /// 只是制造噪音。它们现在不含 jsonl，索引侧由 `Indexer.isOwnProbe` 跳过，无害。
    static func cleanUpLegacyProbe() {
        let fm = FileManager.default
        let legacyId = "c1a0de00-0000-4000-8000-000000000001"
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var targets = [
            home.appendingPathComponent(".claude/session-env/\(legacyId)"),
            home.appendingPathComponent(".claude/hooks/.state/\(legacyId).uuids"),
        ]
        // 探测目录里的会话正文 —— 只删 jsonl，目录本身留着
        for dir in (try? fm.contentsOfDirectory(at: Indexer.defaultRoot,
                                                includingPropertiesForKeys: nil)) ?? []
        where Indexer.isOwnProbe(dir) {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "jsonl" {
                targets.append(f)
            }
        }
        for t in targets where fm.fileExists(atPath: t.path) {
            // 移到废纸篓而不是直接删 —— 万一判断错了还能捞回来
            try? fm.trashItem(at: t, resultingItemURL: nil)
        }
    }

    /// 这个探测会话在 `~/.claude/projects/` 下对应的目录名（扁平化路径）。
    ///
    /// 实测规则：`/`、`.`、`_`、**空格**都换成 `-`。空格那条是踩出来的 ——
    /// 路径里有 `Application Support`，起初漏了空格，算出来的名字和真实目录不符。
    /// 只用于诊断输出；真正的过滤走 `Indexer.isOwnProbe` 的后缀匹配，
    /// 不依赖完整推导对不对。
    static var projectDirName: String {
        var s = workDir.path
        for ch in ["/", ".", "_", " "] { s = s.replacingOccurrences(of: ch, with: "-") }
        return s
    }

    enum Failure: LocalizedError {
        case claudeNotFound
        case timedOut
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "找不到 claude 命令"
            case .timedOut: return "claude 命令超时"
            case .unreadable(let s): return s.isEmpty ? "没有输出" : s
            }
        }
    }

    // MARK: - 定位 claude（不走登录 shell）

    /// 用户主目录下受 TCC（隐私）管辖的目录。碰任何一个都会弹「是否允许访问…文件夹」。
    static let tccProtectedDirs = [
        "Desktop", "Documents", "Downloads",
        "Library/Mobile Documents",          // iCloud Drive
        "Movies", "Music", "Pictures",
    ]

    /// 给子进程的 PATH。**刻意不继承用户 PATH，也刻意不走登录 shell。**
    ///
    /// 原来这里跑 `zsh -l -c "claude …"`，理由写在下面 `run` 里：GUI 进程继承的
    /// PATH 找不到用户装的命令行工具。代价是踩了个很隐蔽的坑 ——
    /// `-l` 会加载 `.zprofile` / `.bash_profile`，用户可能在那里把工具装在
    /// `~/Documents` 下并追加进 PATH（实测：maven）。而 zsh 查找命令时会
    /// **逐个 opendir 每个 PATH 目录**，于是碰到 TCC 保护目录、弹出授权窗。
    ///
    /// 更糟的是弹窗上写的是**本 app 的名字**：TCC 把权限归因给 responsible
    /// process，派生的子进程没有独立身份，全部记在发起者头上。用户看到
    /// 「Claude Session Search 想访问你的『文档』文件夹」，而 app 自己压根没碰过那里。
    ///
    /// 现在直接定位可执行文件、完全不经 shell，PATH 只给这几个固定目录 ——
    /// 全在 TCC 管辖范围之外（`isTCCSafe` 守着这条不变量）。
    static let safePathDirs = [
        "\(NSHomeDirectory())/.local/bin",
        "\(NSHomeDirectory())/.claude/local",
        "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// PATH 里有没有混进 TCC 保护目录。纯函数，给自检断言用 ——
    /// 以后谁往 `safePathDirs` 里加一条 `~/Documents/...` 会被立刻抓住。
    static func isTCCSafe(_ dirs: [String]) -> Bool {
        let home = NSHomeDirectory()
        return dirs.allSatisfy { dir in
            let full = dir.hasPrefix("/") ? dir : "\(home)/\(dir)"
            return !tccProtectedDirs.contains { full == "\(home)/\($0)" || full.hasPrefix("\(home)/\($0)/") }
        }
    }

    /// claude 可执行文件的位置。按常见安装位置直接找，找不到才认输 ——
    /// 不回落到 `zsh -l`，因为那正是要躲开的东西。
    ///
    /// 实测本机是原生 Mach-O 二进制（`~/.local/bin/claude`），不是 node 脚本，
    /// 所以直接执行就行，不需要 node 在 PATH 里。
    static func locateClaude() -> URL? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        // nvm 按版本号分目录，枚举一层，新版本优先
        let nvm = "\(home)/.nvm/versions/node"
        for version in ((try? fm.contentsOfDirectory(atPath: nvm)) ?? []).sorted().reversed() {
            candidates.append("\(nvm)/\(version)/bin/claude")
        }
        return candidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { fm.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - 取数

    /// `/usage` 的输出分两半：额度百分比来自**服务端**，后面「哪些行为在消耗额度」
    /// 那段是**本地**算的。实测撞到过只回来后半段的情况 —— 本地分析齐全，
    /// 三行 `Current …: N% used` 全没了。所以：
    ///
    /// 1. 缺百分比时重试几次（查 /usage 不消耗额度，重试是免费的）
    /// 2. 重试仍没有就**降级返回**，而不是报错 —— 那半段分析本身有用，
    ///    把它当成失败整个丢掉、只弹一句「Couldn't read usage」是更差的结果
    static func fetch() async throws -> UsageSnapshot {
        guard let claude = locateClaude() else { throw Failure.claudeNotFound }
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        var last = ""
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            // `--no-session-persistence` 只跟 `--print`（也就是 -p）一起生效。
            // 不写会话文件 ⇒ 不需要 session id ⇒ 没有锁可撞。
            //
            // 注意**不能看退出码**：claude 出错时照样返回 0，只把
            // "Error: …" 打到 stdout。所以只看能不能解析出百分比。
            last = try await run(claude, ["-p", "/usage", "--no-session-persistence"])
            if parse(last).parsedAnything { return parse(last) }
            // 连用量正文都不是（没登录、找不到命令之类），重试没有意义
            if !looksLikeUsage(last) { break }
        }
        if looksLikeUsage(last) { return parse(last) }   // 降级：raw 完整，百分比为 nil
        throw Failure.unreadable(String(last.prefix(600)))
    }

    /// 是不是 `/usage` 的正文（哪怕缺了百分比那几行）
    static func looksLikeUsage(_ s: String) -> Bool {
        s.contains("contributing to your limits") || s.contains("using your subscription")
    }

    /// 直接执行 claude 二进制，**不经过 shell**。
    ///
    /// 曾经是 `zsh -l -c …`，为的是解决「GUI 进程继承的 PATH 里找不到用户装的
    /// 命令行工具」。那个问题现在由 `locateClaude()` 显式查找解决，于是
    /// 登录 shell 连带拖进来的整套用户环境（以及其中指向 TCC 保护目录的
    /// PATH 条目）就不需要了 —— 详见 `safePathDirs` 上的说明。
    private static func run(_ claude: URL, _ args: [String],
                            timeout: TimeInterval = 60) async throws -> String {
        let task = Process()
        task.executableURL = claude
        task.arguments = args
        task.currentDirectoryURL = workDir
        // 只换 PATH，其余（HOME / USER / TMPDIR…）照旧继承 —— claude 要靠它们
        // 找到 ~/.claude 下的配置和登录凭据
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = safePathDirs.joined(separator: ":")
        task.environment = env
        // stdout 和 stderr 都接到同一个管道，等价于原来 shell 里的 `2>&1`
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()

        // 边跑边读。管道缓冲区满了子进程会阻塞，等它退出再读就死锁了。
        let handle = pipe.fileHandleForReading
        let reader = Task.detached { () -> Data in
            var data = Data()
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                data.append(chunk)
            }
            return data
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning {
            if Date() > deadline {
                task.terminate()
                reader.cancel()
                throw Failure.timedOut
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let data = await reader.value
        let text = String(data: data, encoding: .utf8) ?? ""
        if text.contains("command not found") { throw Failure.claudeNotFound }
        return text
    }

    // MARK: - 解析（纯函数，自检直接断言）

    static func parse(_ text: String) -> UsageSnapshot {
        var snap = UsageSnapshot(raw: text, fetchedAt: Date())
        for line in text.split(separator: "\n").map(String.init) {
            guard let pct = percent(in: line) else { continue }
            let resets = resetPart(of: line)
            if line.contains("Current session") {
                snap.sessionPercent = pct
                snap.sessionResets = resets
            } else if line.contains("Current week"), line.contains("all models") {
                snap.weekPercent = pct
                snap.weekResets = resets
            } else if line.contains("Current week"), let label = parenLabel(in: line) {
                snap.extraLimits.append((label, pct))
            }
        }
        return snap
    }

    /// `12% used` → 12。只认紧跟 `%` 的数字，避开 "87% of your usage was at >150k"
    /// 那种描述性百分比 —— 那些行不含 "used"。
    private static func percent(in line: String) -> Int? {
        guard line.contains("% used") else { return nil }
        guard let r = line.range(of: #"(\d+)% used"#, options: .regularExpression) else { return nil }
        return Int(line[r].prefix(while: \.isNumber))
    }

    /// `· resets Jul 31 at 7pm (Asia/Shanghai)` → `Jul 31 at 7pm (Asia/Shanghai)`
    private static func resetPart(of line: String) -> String? {
        guard let r = line.range(of: "resets ") else { return nil }
        let s = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    // MARK: - 重置时刻（纯函数，自检直接断言）

    /// 重置时刻，拆成 24 小时制的字段。
    ///
    /// 为什么要拆：claude 给的原文是 **12 小时制、且没有年份**。
    /// `Sep 10 at 12:59am` 这种写法用户实测「分不清是凌晨 0:59 还是中午 12:59」——
    /// 12am / 12pm 恰好是 12 小时制里最容易读反的两个点（12am 是午夜，
    /// 直觉上却像中午）。app 其余所有时间都走 `HH:mm`，这一行是唯一的例外，
    /// 因为它是从 claude 的文本里原样搬过来的。
    ///
    /// 顺带说明另一半困惑：同一个重置点，claude 有时报 `12:59am` 有时报 `1am`。
    /// 实测同一个二进制、隔几分钟连跑两次就能复现，**跟本 app 无关** ——
    /// 我们从头到尾只是把它那行字原样搬过来。所以这里只改可读性、不做四舍五入
    /// 到整点：把 0:59 说成 1:00 是替上游圆谎，真实到分钟才对得上原文。
    struct ResetTime: Equatable, Sendable {
        var month: Int          // 1–12
        var monthName: String   // "Sep"，英文界面沿用原文写法
        var day: Int
        var hour: Int           // 0–23，已从 am/pm 换算过
        var minute: Int
        var timeZoneId: String? // "Asia/Shanghai"；原文没带括号时为 nil
    }

    /// 宽松匹配：分钟可缺（`7pm`）、大小写随意、`am`/`a.m.` 都收、时区括号可缺。
    /// 上游格式变了就整条匹配失败 —— 那时调用方回退到原文照登，不会显示错的时间。
    private static let resetPattern = try? NSRegularExpression(
        pattern: #"^([A-Za-z]{3,})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([APap])\.?[Mm]\.?(?:\s*\(([^)]+)\))?"#)

    private static let monthAbbrs = ["jan", "feb", "mar", "apr", "may", "jun",
                                     "jul", "aug", "sep", "oct", "nov", "dec"]

    /// `Sep 10 at 12:59am (Asia/Shanghai)` → 9 月 10 日 00:59。解析不出来返回 nil。
    static func parseReset(_ s: String) -> ResetTime? {
        let text = s.trimmingCharacters(in: .whitespaces)
        guard let re = resetPattern,
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        func group(_ i: Int) -> String? {
            guard let r = Range(m.range(at: i), in: text) else { return nil }
            return String(text[r])
        }

        guard let monRaw = group(1)?.lowercased().prefix(3),
              let monIdx = monthAbbrs.firstIndex(of: String(monRaw)),
              let day = group(2).flatMap(Int.init),
              var hour = group(3).flatMap(Int.init),
              let half = group(5)?.lowercased()
        else { return nil }
        let minute = group(4).flatMap(Int.init) ?? 0
        guard (1...12).contains(hour), (0...59).contains(minute), (1...31).contains(day)
        else { return nil }

        // 12 小时制换 24 小时制。这两条特例就是歧义的来源：
        // 12am = 0 点、12pm = 12 点，其余 pm 才是加 12。
        if hour == 12 { hour = 0 }
        if half == "p" { hour += 12 }

        return ResetTime(month: monIdx + 1, monthName: String(monRaw).capitalized,
                         day: day, hour: hour, minute: minute, timeZoneId: group(6))
    }

    /// 补出绝对时间，用来算倒计时。
    ///
    /// 年份原文里没有，只能推：取让这个日期离 now 最近的那个年份。
    /// 直接用当前年份的话，12 月底看到「Jan 2」会算成**一年后**。
    /// 时区也按原文括号里那个来 —— 用户可能在别的时区看一台机器的额度。
    static func resetDate(_ r: ResetTime, now: Date = Date()) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        if let id = r.timeZoneId, let tz = TimeZone(identifier: id) { cal.timeZone = tz }
        let year = cal.component(.year, from: now)
        var best: Date?
        for y in [year - 1, year, year + 1] {
            var c = DateComponents()
            c.year = y; c.month = r.month; c.day = r.day
            c.hour = r.hour; c.minute = r.minute
            guard let d = cal.date(from: c) else { continue }
            if best.map({ abs(d.timeIntervalSince(now)) < abs($0.timeIntervalSince(now)) }) ?? true {
                best = d
            }
        }
        return best
    }

    struct Countdown: Equatable, Sendable {
        var days: Int
        var hours: Int
        var minutes: Int
    }

    /// 还剩多久。已经过去了返回 nil —— 那种情况下「还有 -3 小时」比不显示更糟。
    /// 不足一分钟返回全 0，由文案层说成「即将重置」。
    static func countdown(to d: Date, now: Date = Date()) -> Countdown? {
        let secs = d.timeIntervalSince(now)
        guard secs > 0 else { return nil }
        let total = Int(secs) / 60
        return Countdown(days: total / 1440, hours: (total % 1440) / 60, minutes: total % 60)
    }

    /// `Current week (Fable): 0% used` → `Fable`
    private static func parenLabel(in line: String) -> String? {
        guard let open = line.firstIndex(of: "("),
              let close = line[open...].firstIndex(of: ")"), open < close else { return nil }
        let label = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : label
    }
}
