import Foundation
import Observation

/// 界面语言。
///
/// 刻意不用 .lproj/Localizable.strings：那套依赖 Bundle 资源目录，
/// 而这个 app 是用 swiftc + 手工组装 .app（无 Xcode），资源目录得自己维护；
/// 且切换语言需要重启进程才能换 Bundle。词表写在代码里，编译期就能查错，
/// 切换也是即时的。
enum AppLanguage: String, CaseIterable, Hashable, Sendable {
    case auto
    case zh
    case en

    /// 语言菜单里的显示名。具体语言用它自己的名字写（选项自解释），
    /// 只有「自动」需要跟随当前界面语言。
    @MainActor
    var label: String {
        switch self {
        case .auto: return L.current == .zh ? "自动（跟随系统）" : "Automatic (System)"
        case .zh:   return "中文"
        case .en:   return "English"
        }
    }

    /// auto 解析成实际使用的语言
    var resolved: AppLanguage {
        guard self == .auto else { return self }
        return Self.systemLanguage
    }

    /// 系统首选语言。只算一次 —— 每条文案都要读一次当前语言，
    /// 而 Locale.preferredLanguages 是系统调用，不该放在这条路径上重复执行。
    /// 进程运行期间用户改系统语言的情况可忽略（macOS 本身也要求重启 app）。
    private static let systemLanguage: AppLanguage = {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .zh : .en
    }()
}

/// 全局语言状态。
///
/// 关键点：`L.current` 直接读这里的 `resolved`，而不是自己存一份静态变量。
/// 静态变量的读取不经过 Observation，SwiftUI 追踪不到，结果是只有显式写了
/// `@Bindable var lang = LanguageSetting.shared` 的视图会重绘 —— 其余视图
/// 得等下次因别的原因重绘才更新（表现为「点一下才切换语言」）。
/// 走 @Observable 属性后，任何读 `L.xxx` 的视图都自动建立依赖。
@Observable
@MainActor
final class LanguageSetting {
    static let shared = LanguageSetting()
    private static let key = "appLanguage"

    var selection: AppLanguage {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.key)
        }
    }

    /// 实际生效的语言（已解析 auto）
    var resolved: AppLanguage { selection.resolved }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppLanguage.auto.rawValue
        selection = AppLanguage(rawValue: raw) ?? .auto
    }
}

// MARK: - 词表

/// 文案表。`L.current` 决定取哪一列。
///
/// 每条都是 `静态函数` 或 `静态属性`，好处是带参数的文案由编译器检查参数类型，
/// 不会出现「格式化字符串占位符和实参对不上」这种只在运行时炸的问题。
enum L {
    /// 当前实际语言。每次都从 @Observable 的 LanguageSetting 读，
    /// 读取动作本身就把调用方视图登记为依赖，切换语言后自动重绘。
    @MainActor static var current: AppLanguage { LanguageSetting.shared.resolved }

    /// 二选一的小工具，让下面每条文案都能写成一行。
    @MainActor private static func t(_ zh: String, _ en: String) -> String {
        current == .zh ? zh : en
    }

    // MARK: 窗口 / 导航

    // app 名字不在这里 —— 菜单栏 / Dock / Finder 显示的是 Info.plist 里的
    // CFBundleName，固定为英文「Claude Session Search」，与界面语言无关。
    @MainActor static var searchPrompt: String { t("搜索所有会话的内容…", "Search all session content…") }
    @MainActor static var searchResults: String { t("搜索结果", "Search Results") }
    @MainActor static var recentSessions: String { t("最近会话", "Recent Sessions") }
    @MainActor static var session: String { t("会话", "Session") }
    @MainActor static var allProjects: String { t("全部项目", "All Projects") }
    @MainActor static var projects: String { t("项目", "Projects") }

    // MARK: 筛选菜单

    @MainActor static var filter: String { t("筛选", "Filter") }
    @MainActor static var filterHelp: String { t("搜索范围与排序", "Search scope and sorting") }
    @MainActor static var searchToolOutput: String { t("搜索工具调用与输出", "Search tool calls and output") }
    @MainActor static var searchSubagents: String { t("连子 agent 的内容一起搜", "Include subagent content") }
    @MainActor static var scope: String { t("范围", "Scope") }
    @MainActor static var scopeAll: String { t("全部对话", "All messages") }
    @MainActor static var scopeHuman: String { t("只搜我说的", "Only what I said") }
    @MainActor static var scopeAssistant: String { t("只搜 Claude 说的", "Only what Claude said") }
    @MainActor static var sortByHits: String { t("按命中数排序", "Sort by hit count") }
    @MainActor static var language: String { t("语言", "Language") }

    // MARK: 主题

    @MainActor static var theme: String { t("主题", "Theme") }
    @MainActor static var themeAuto: String { t("跟随系统", "Follow System") }
    @MainActor static var themeLight: String { t("浅色", "Light") }
    @MainActor static var themeDark: String { t("深色", "Dark") }

    // MARK: 索引

    @MainActor static var rebuildIndex: String { t("重建索引", "Rebuild Index") }
    @MainActor static var rebuilding: String { t("正在重建索引…", "Rebuilding index…") }
    @MainActor static var firstIndexing: String { t("首次建立索引，请稍候…", "Building index for the first time…") }
    @MainActor static var indexing: String { t("索引中…", "Indexing…") }
    @MainActor static var indexFailed: String { t("索引失败", "Indexing failed") }
    @MainActor static var rebuilt: String { t("已重建", "Rebuilt") }

    @MainActor static func indexingProgress(_ done: Int, _ total: Int) -> String {
        t("索引中 \(done)/\(total)", "Indexing \(done)/\(total)")
    }
    @MainActor static func dbOpenFailed(_ error: String) -> String {
        t("数据库打开失败: \(error)", "Failed to open database: \(error)")
    }
    @MainActor static func sessionCount(_ n: Int) -> String {
        t("\(n) 个会话", n == 1 ? "1 session" : "\(n) sessions")
    }
    @MainActor static func subagentCount(_ n: Int) -> String {
        t("\(n) 个子 agent", n == 1 ? "1 subagent" : "\(n) subagents")
    }
    @MainActor static func newMessages(_ n: Int) -> String {
        t("新增 \(n) 条正文", "\(n) new messages")
    }
    @MainActor static func prunedSessions(_ n: Int) -> String {
        t("清理 \(n) 个已删除", "\(n) removed")
    }
    @MainActor static func parseFailures(_ n: Int) -> String {
        t("⚠️ \(n) 个文件解析失败", "⚠️ \(n) files failed to parse")
    }
    @MainActor static func autoIndexed(_ n: Int) -> String {
        t("已自动收录 \(n) 条新消息", "Auto-indexed \(n) new messages")
    }

    // MARK: 结果列表

    @MainActor static func groupCount(_ n: Int) -> String {
        t("\(n) 个会话", n == 1 ? "1 session" : "\(n) sessions")
    }
    @MainActor static func recentCount(_ n: Int) -> String {
        t("最近 \(n) 个", "Latest \(n)")
    }
    @MainActor static func hitCount(_ n: Int) -> String {
        t("\(n) 条命中", n == 1 ? "1 hit" : "\(n) hits")
    }
    @MainActor static func messageCount(_ n: Int) -> String {
        t("\(n) 条消息", n == 1 ? "1 message" : "\(n) messages")
    }
    @MainActor static func plainCount(_ n: Int) -> String {
        t("\(n) 条", "\(n)")
    }
    @MainActor static var noMatch: String { t("无匹配", "No matches") }
    @MainActor static var substringMatch: String { t(" · 子串匹配", " · substring match") }
    @MainActor static var truncated: String { t("（已截断）", " (truncated)") }
    @MainActor static func resultSummary(sessions: Int, hits: Int) -> String {
        t("\(sessions) 个会话 · \(hits) 条命中",
          "\(sessions) session\(sessions == 1 ? "" : "s") · \(hits) hit\(hits == 1 ? "" : "s")")
    }
    @MainActor static func noSessionsMatching(_ q: String) -> String {
        t("没有匹配「\(q)」的会话", "No sessions matching “\(q)”")
    }
    @MainActor static var toolNoiseHint: String {
        t("默认只搜对话正文。若要连工具调用和命令输出一起搜，\n在右上角筛选里打开「搜索工具调用与输出」。",
          "Only conversation text is searched by default. To include tool calls and\ncommand output, enable “Search tool calls and output” in the filter menu.")
    }
    @MainActor static var noSessionsIndexed: String { t("还没有索引到任何会话", "No sessions indexed yet") }
    @MainActor static var buildingIndex: String { t("正在建立索引…", "Building index…") }

    // MARK: 会话详情

    @MainActor static var selectSession: String { t("选择左侧的会话查看内容", "Select a session to view it") }
    @MainActor static var noContent: String { t("这个会话没有正文内容", "This session has no message content") }
    @MainActor static var onlyToolRecords: String { t("这个会话只有工具调用记录", "This session only contains tool records") }
    @MainActor static func showToolRecords(_ n: Int) -> String {
        t("显示 \(n) 条工具记录", "Show \(n) tool records")
    }
    @MainActor static func showToolCalls(_ n: Int) -> String {
        t("显示 \(n) 条工具调用与输出", "Show \(n) tool calls and outputs")
    }
    @MainActor static var hideToolCalls: String { t("隐藏工具调用与输出", "Hide tool calls and outputs") }
    /// 超长正文默认截断，这是展开剩余部分的入口
    @MainActor static func showFullText(_ hidden: Int) -> String {
        t("还有 \(hidden) 字，显示完整内容", "\(hidden) more characters — show full text")
    }
    @MainActor static var toolRecords: String { t("工具记录", "Tool records") }
    @MainActor static var toolsShownHelp: String {
        t("正文里正显示工具调用与输出，点击隐藏", "Tool calls and outputs are shown; click to hide")
    }
    @MainActor static var toolsHiddenHelp: String {
        t("正文里已隐藏工具调用与输出，点击显示", "Tool calls and outputs are hidden; click to show")
    }
    @MainActor static func subagentsIn(_ n: Int) -> String {
        t("\(n) 个子 agent", n == 1 ? "1 subagent" : "\(n) subagents")
    }
    @MainActor static func subagentHitsHelp(_ n: Int) -> String {
        t("其中 \(n) 条命中在子 agent 的记录里",
          "\(n) of these hits are in subagent records")
    }
    @MainActor static func subagentSessionHelp(_ type: String?) -> String {
        let suffix = type.map { L.current == .zh ? "（\($0)）" : " (\($0))" } ?? ""
        return t("子 agent 会话\(suffix)", "Subagent session\(suffix)")
    }

    // MARK: 消息角色

    @MainActor static var roleMe: String { t("我", "Me") }
    @MainActor static var roleClaude: String { t("Claude", "Claude") }
    @MainActor static var roleMeShort: String { t("我", "Me") }
    @MainActor static var roleAIShort: String { t("AI", "AI") }
    @MainActor static var roleThinking: String { t("思考", "Thinking") }
    @MainActor static var roleToolUse: String { t("调用", "Call") }
    @MainActor static var roleToolResult: String { t("输出", "Output") }
    @MainActor static var kindThinking: String { t("内部推理", "Internal reasoning") }
    @MainActor static var kindToolResult: String { t("工具输出 / 注入内容", "Tool output / injected content") }

    // MARK: 操作

    @MainActor static var search: String { t("搜索", "Search") }
    @MainActor static var nextHit: String { t("下一个命中", "Next Match") }
    @MainActor static var prevHit: String { t("上一个命中", "Previous Match") }
    @MainActor static var nextHitHelp: String { t("下一个命中 (⌘G)", "Next match (⌘G)") }
    @MainActor static var prevHitHelp: String { t("上一个命中 (⇧⌘G)", "Previous match (⇧⌘G)") }
    @MainActor static var scrollToTop: String { t("滚动到顶部", "Scroll to Top") }
    @MainActor static var scrollToBottom: String { t("滚动到底部", "Scroll to Bottom") }
    @MainActor static var followNewOutput: String { t("有新输出时滚到底部", "Scroll to Bottom on New Output") }
    @MainActor static var scrollToTopHelp: String { t("滚动到顶部 (⌘↑)", "Scroll to top (⌘↑)") }
    @MainActor static var scrollToBottomHelp: String { t("滚动到底部 (⌘↓)", "Scroll to bottom (⌘↓)") }
    // MARK: Markdown 渲染

    @MainActor static var renderMarkdown: String {
        t("渲染 Claude 回复的 Markdown", "Render Markdown in Claude's Replies")
    }
    @MainActor static var copyCode: String { t("复制这段代码", "Copy this code") }
    @MainActor static var copyTable: String {
        t("复制这张表（Markdown）", "Copy this table as Markdown")
    }
    @MainActor static var copyMessage: String {
        t("复制这条消息（纯文本）· 右键可复制 Markdown 原文",
          "Copy this message as plain text · right-click for Markdown source")
    }
    /// 不按 Markdown 渲染的消息（你打的字、工具输出）：复制就是原样，没有第二种口径
    @MainActor static var copyMessageRaw: String { t("复制这条消息", "Copy this message") }
    @MainActor static var copyMessagePlain: String {
        t("复制纯文本", "Copy as Plain Text")
    }
    @MainActor static var copyMessageMarkdown: String {
        t("复制 Markdown 原文", "Copy as Markdown Source")
    }
    @MainActor static var copiedMessage: String { t("已复制到剪贴板", "Copied to clipboard") }

    // MARK: 会话内查找

    @MainActor static var findInSession: String { t("在本会话中查找", "Find in Session") }
    @MainActor static var findInSessionMenu: String {
        t("在本会话中查找…", "Find in Session…")
    }
    @MainActor static var searchAllSessions: String {
        t("搜索全部会话…", "Search All Sessions…")
    }
    @MainActor static var findClose: String { t("关闭查找条", "Close find bar") }
    @MainActor static var findNoMatch: String { t("无匹配", "No match") }
    @MainActor static func findTryTools(_ n: Int) -> String {
        t("试试显示工具记录（\(n) 条）", "Try showing \(n) tool records")
    }

    /// 「3/17」。i 是 0 基的游标，显示时 +1；命中为 0 时不该调用它，
    /// 但仍然做了兜底 —— 显示「0/0」也比崩掉好。
    @MainActor static func hitCounter(_ i: Int, of total: Int) -> String {
        total == 0 ? "0/0" : "\(min(i + 1, total))/\(total)"
    }
    @MainActor static var hitCounterHelp: String {
        t("按消息条数计；同一条里的多处不单独计",
          "Counted by message — multiple matches in one message count once")
    }

    @MainActor static var copyResume: String { t("复制恢复命令", "Copy Resume Command") }
    @MainActor static var copyResumeHelp: String { t("复制 \(AppModel.resumeCommand) 命令", "Copy \(AppModel.resumeCommand) command") }
    @MainActor static var revealInFinder: String { t("在 Finder 中显示项目", "Show Project in Finder") }
    @MainActor static var copiedResume: String { t("已复制恢复命令到剪贴板", "Resume command copied to clipboard") }
    @MainActor static var copySessionId: String { t("点击复制会话 id", "Click to copy session id") }
    @MainActor static var copiedSessionId: String { t("已复制会话 id", "Session id copied") }

    // MARK: 额度用量

    @MainActor static var usage: String { t("订阅额度", "Subscription Usage") }
    @MainActor static var usageSession: String { t("当前会话窗口", "Current session") }
    @MainActor static var usageWeek: String { t("本周（全部模型）", "Current week (all models)") }
    @MainActor static func usageResets(_ when: String) -> String {
        t("重置于 \(when)", "resets \(when)")
    }

    /// 重置时刻。**一律 24 小时制** —— 原文的 `12:59am` 分不清是 0:59 还是 12:59，
    /// 而 app 别处的时间全是 `HH:mm`，没理由只有这一行例外。
    ///
    /// 时区只在**和本机不一致时**才显示：原文永远带一个 `(Asia/Shanghai)`，
    /// 而绝大多数时候它就是本机时区，写出来纯属占地方。真不一致时它很关键，
    /// 所以不能一律省掉。
    @MainActor static func usageResetStamp(_ r: UsageProbe.ResetTime) -> String {
        let clock = String(format: "%02d:%02d", r.hour, r.minute)
        let head = current == .zh ? "\(r.month)月\(r.day)日 \(clock)"
                                  : "\(r.monthName) \(r.day), \(clock)"
        if let id = r.timeZoneId, id != TimeZone.current.identifier {
            return "\(head) (\(id))"
        }
        return head
    }

    /// 界面上那整行「重置于 …」。
    ///
    /// 能解析就换成 24 小时制并补一句倒计时；解析不了就**原文照登** ——
    /// 上游格式一变解析就会失效，宁可难读，也绝不能显示一个错的时间，
    /// 更不能因为解析不出来就把这行信息整个扔掉。
    ///
    /// 放在文案层而不是视图里，是为了 `--usage` 能打出和界面**一模一样**的串：
    /// 原生 UI 没法截图自检，能从命令行看到最终结果就是唯一的端到端证据。
    @MainActor static func usageResetLine(_ raw: String, now: Date = Date()) -> String {
        guard let r = UsageProbe.parseReset(raw) else { return usageResets(raw) }
        var line = usageResets(usageResetStamp(r))
        if let at = UsageProbe.resetDate(r, now: now),
           let left = UsageProbe.countdown(to: at, now: now) {
            line += " · " + usageResetIn(left)
        }
        return line
    }

    /// 距重置还有多久。比绝对时刻更好用 —— 「还有 9 小时」不需要心算，
    /// 也彻底绕开了上午下午的问题。
    @MainActor static func usageResetIn(_ c: UsageProbe.Countdown) -> String {
        if c.days > 0 {
            return t("还有 \(c.days) 天 \(c.hours) 小时", "in \(c.days)d \(c.hours)h")
        }
        if c.hours > 0 {
            return t("还有 \(c.hours) 小时 \(c.minutes) 分", "in \(c.hours)h \(c.minutes)m")
        }
        if c.minutes > 0 {
            return t("还有 \(c.minutes) 分钟", "in \(c.minutes)m")
        }
        return t("即将重置", "resetting now")
    }
    @MainActor static var usageDetails: String { t("完整输出", "Full output") }
    @MainActor static var usageRefresh: String { t("重新获取", "Refresh") }
    @MainActor static var usageIdle: String { t("正在获取…", "Fetching…") }
    @MainActor static var usageFailed: String { t("取不到额度数据", "Couldn’t read usage") }
    @MainActor static var usageNoPercent: String {
        t("这次没返回额度百分比", "Limit percentages weren’t returned")
    }
    @MainActor static var usageNoPercentHint: String {
        t("百分比来自服务端，偶尔会缺；下面的用量分析是本地算的，仍然有效。点右上角重试。",
          "The percentages come from the server and occasionally don’t arrive. The breakdown below is computed locally and still valid — hit refresh to retry.")
    }
    @MainActor static var usageHint: String {
        t("这份数据本地没有，要靠 claude -p \"/usage\" 向服务端查。请确认 claude 命令在登录 shell 的 PATH 里，且已登录。",
          "This data isn’t stored locally — it comes from `claude -p \"/usage\"`. Make sure `claude` is on your login shell’s PATH and you’re signed in.")
    }
    @MainActor static func usageFetchedAt(_ when: String) -> String {
        t("获取于 \(when)", "Fetched \(when)")
    }
    @MainActor static var usageHelp: String {
        t("订阅额度用量（查询不消耗额度）", "Subscription usage (checking costs no quota)")
    }

    // MARK: 导出

    @MainActor static var exportConversation: String { t("导出对话…", "Export Conversation…") }
    @MainActor static var exportFull: String { t("导出完整记录…", "Export Full Transcript…") }
    @MainActor static var exportProject: String { t("导出项目会话…", "Export Project Sessions…") }
    @MainActor static var exportConversationMessage: String {
        t("导出对话正文为 Markdown（不含工具调用与输出）",
          "Export the conversation as Markdown (without tool calls and outputs)")
    }
    @MainActor static var exportFullMessage: String {
        t("导出完整记录为 Markdown（含工具调用与输出，体积可能很大）",
          "Export the full transcript as Markdown (includes tool calls and outputs; may be large)")
    }
    @MainActor static var exportChooseFolder: String { t("导出到此处", "Export Here") }
    @MainActor static func exportProjectMessage(_ project: String) -> String {
        t("为「\(project)」建一个子目录，写入 index.csv 会话清单和每个会话的 Markdown 正文",
          "Creates a subfolder for “\(project)” containing index.csv and one Markdown file per session")
    }
    @MainActor static var exporting: String { t("正在导出…", "Exporting…") }
    @MainActor static func exported(_ files: Int, _ path: String) -> String {
        t("已导出 \(files) 个文件到 \(path)",
          files == 1 ? "Exported to \(path)" : "Exported \(files) files to \(path)")
    }
    @MainActor static func exportFailed(_ err: String) -> String {
        t("导出失败：\(err)", "Export failed: \(err)")
    }

    // MARK: 其它

    @MainActor static var untitledSession: String { t("(无标题会话)", "(Untitled session)") }
    @MainActor static var starting: String { t("启动中…", "Starting…") }

    // MARK: 日期

    /// 会话列表用的短日期
    /// 会话列表用。今年以内只给日期 —— 列表一屏几十行，紧凑优先。
    @MainActor static func shortDateFormat(_ style: DateStyle) -> String {
        switch style {
        case .today:     return t("今天 HH:mm", "'Today' HH:mm")
        case .yesterday: return t("昨天 HH:mm", "'Yesterday' HH:mm")
        case .thisYear:  return t("M月d日", "MMM d")
        case .older:     return t("yyyy年M月d日", "MMM d, yyyy")
        }
    }

    /// 正文里每条消息用。和 `shortDateFormat` 只差一件事：**四档全带 HH:mm**。
    ///
    /// 正文原来直接复用 `shortDateFormat`，于是今年以内的消息只显示「8月11日」，
    /// 时分整个丢了 —— 翻旧会话时看不出一条消息是上午发的还是深夜发的。
    /// 会话列表要紧凑、正文要精确，两种需求本来就该用两个格式。
    @MainActor static func messageDateFormat(_ style: DateStyle) -> String {
        switch style {
        case .today:     return t("今天 HH:mm", "'Today' HH:mm")
        case .yesterday: return t("昨天 HH:mm", "'Yesterday' HH:mm")
        case .thisYear:  return t("M月d日 HH:mm", "MMM d, HH:mm")
        case .older:     return t("yyyy年M月d日 HH:mm", "MMM d yyyy, HH:mm")
        }
    }

    enum DateStyle { case today, yesterday, thisYear, older }

    @MainActor static var dateLocale: Locale {
        Locale(identifier: current == .zh ? "zh_CN" : "en_US")
    }
}
