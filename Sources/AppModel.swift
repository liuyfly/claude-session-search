import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {

    // MARK: - 搜索

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            terms = Self.splitTerms(query)
            refreshHits()
            scheduleSearch()
        }
    }
    var filter = SearchFilter() {
        didSet { scheduleSearch(debounce: false) }
    }
    var outcome = SearchOutcome()
    var searching = false

    /// 搜索框为空时展示的最近会话
    var recent: [SessionHitGroup] = []

    /// 当前列表（有查询时是命中分组，否则是最近会话）
    var listedSessions: [SessionHitGroup] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? recent : outcome.groups
    }

    var hasQuery: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var filterIsDefault: Bool {
        let d = SearchFilter()
        return filter.includeToolNoise == d.includeToolNoise
            && filter.includeSubagents == d.includeSubagents
            && filter.humanOnly == d.humanOnly
            && filter.assistantOnly == d.assistantOnly
            && filter.sortByRelevance == d.sortByRelevance
    }

    /// 状态条右侧的结果摘要，顺带说明短词已自动降级 —— 否则用户会以为
    /// 搜「迁移」和搜「迁移方案」用的是同一套匹配规则。
    var resultSummary: String {
        guard hasQuery else { return "" }
        if outcome.totalHits == 0 { return L.noMatch }
        var s = L.resultSummary(sessions: outcome.groups.count, hits: outcome.totalHits)
        if outcome.truncated { s += L.truncated }
        if outcome.strategy == .substring { s += L.substringMatch }
        return s
    }

    /// 高亮用的查询词。正文里每条消息都要读一次，存下来免得反复切分。
    private(set) var terms: [String] = []

    private static func splitTerms(_ q: String) -> [String] {
        q.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: - 侧栏 / 选中

    var projects: [ProjectRow] = []
    var selectedProjectId: Int64? {
        didSet {
            guard selectedProjectId != oldValue else { return }
            filter.projectId = selectedProjectId
            // 只在选中的会话确实落到范围外时才清空，让 loadRecent 换成新项目里
            // 最新的那个。不能无条件清空 —— 侧栏按「最近活跃」排序，别的项目
            // 一有更新就重排，SwiftUI 的 List 会跟着抖一下 selection，
            // 无条件清空就会把你正在读的会话换成刚更新的那个（实测撞到过）。
            if let current = selectedSession, !inCurrentProject(current) {
                selectedSessionId = nil
            }
            Task { await loadRecent() }
        }
    }

    var selectedSessionId: String? {
        didSet { if selectedSessionId != oldValue { loadDetail() } }
    }
    /// 当前选中会话的元信息。可能来自搜索结果、最近列表，或子 agent 下钻。
    var selectedSession: SessionHitGroup? {
        guard let sid = selectedSessionId else { return nil }
        return listedSessions.first { $0.sessionId == sid }
            ?? recent.first { $0.sessionId == sid }
            ?? detailSubagents.first { $0.sessionId == sid }
            ?? resolvedSession
    }

    /// 点开子 agent 时它不在任何列表里，单独查一次补上头部信息
    fileprivate var resolvedSession: SessionHitGroup?

    /// 这个会话是否在当前项目筛选范围内。「全部项目」(nil) 容纳一切。
    private func inCurrentProject(_ group: SessionHitGroup) -> Bool {
        guard let pid = selectedProjectId else { return true }
        return group.projectId == pid
    }

    var detail: [DetailMessage] = []
    var detailSubagents: [SessionHitGroup] = []
    var loadingDetail = false

    /// 每次正文加载完成递增。视图靠它区分「切换了会话」和「同一会话被增量刷新」，
    /// 两种情况都要把视口带到最新一条上。
    var detailVersion = 0

    /// 正文视图里展开的消息（thinking / 工具调用默认折叠）
    var expanded: Set<Int64> = []

    /// 正文里是否显示工具调用与工具输出。
    /// 默认关闭：一次会话动辄上百条工具记录，会把真正的对话完全淹没。
    var showToolsInTranscript = false {
        didSet {
            guard showToolsInTranscript != oldValue else { return }
            // 默认口径下工具记录根本没从库里读出来，第一次要显示时得回库补。
            // 关掉时不用重查 —— 内存里过滤一下就行。
            if showToolsInTranscript, !detailHasTools {
                // 保住当前内容和滚动位置：切开关不是换会话，不该把人弹回顶部
                loadDetail(keepingContent: true)
            } else {
                refreshVisibleDetail()
            }
        }
    }

    /// `detail` 里是否含工具记录。默认口径只查对话正文，切开关时靠它判断要不要回库。
    private var detailHasTools = false
    /// 只查对话正文时，库里被跳过的工具记录条数（SQL COUNT 得来）
    private var skippedToolCount = 0

    /// 按当前口径过滤后的正文。
    ///
    /// 存下来而不是每次算：SwiftUI 一帧里会多次读它，而 detail 最多 1600 条。
    /// 单次过滤不贵，但它是 `hitIdsInDetail` 的输入，那个要对每条正文
    /// 做一次 lowercased 全文扫描（大会话上 33 ms），不能跟着一起重算。
    private(set) var visibleDetail: [DetailMessage] = []

    /// 被隐藏的工具记录条数
    private(set) var hiddenToolCount = 0

    // MARK: - 索引状态

    var indexing = false
    var indexProgress: (done: Int, total: Int) = (0, 0)
    var liveWatchActive = false

    /// 状态栏内容。存**结构化状态**而非拼好的字符串 —— 拼好的字符串
    /// 不会随语言切换更新（它是索引结束那一刻生成的）。
    enum Status {
        case idle
        case firstIndexing
        case rebuilding
        case failed(String)
        case indexFailed
        case done(sessions: Int, subagents: Int, newMessages: Int, pruned: Int,
                  parseFailures: Int, rebuilt: Bool)
        case autoIndexed(Int)
        case copiedResume
        case exporting
        case exported(files: Int, path: String)
        case exportFailed(String)
    }

    var status: Status = .idle

    // MARK: - Toast

    /// 浮在界面上的一次性提示。
    ///
    /// 底部状态条太安静了 —— 复制成功那行小字在左下角，眼睛正看着中间/右边时
    /// 根本注意不到。Toast 只用于**用户主动操作的即时反馈**（复制、导出完成/失败）；
    /// 索引进度那类**持续状态**仍然只走状态条，否则一索引就满屏弹。
    ///
    /// `id` 是自增的：连着复制两次，文字一样但 id 变了，动画才会重新播一遍 ——
    /// 否则第二次点击界面上毫无反应，看着像没生效。
    struct Toast: Equatable, Identifiable {
        let id: Int
        let text: String
        let isError: Bool
    }

    var toast: Toast?
    private var toastSeq = 0
    /// 存着上一个自动关闭的定时任务，新 toast 来了要取消它 ——
    /// 否则前一个的计时器会把后一个提前关掉。
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// 弹一条 toast，到点自动消失。
    /// 出错的多留一会儿：错误信息是要读的，2.5 秒不够。
    func flash(_ text: String, isError: Bool = false) {
        toastSeq += 1
        toast = Toast(id: toastSeq, text: text, isError: isError)
        toastTask?.cancel()
        let seconds = isError ? 4.0 : 2.5
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// 状态栏显示的文字。每次读都按当前语言现拼，所以切语言会跟着变。
    var statusLine: String {
        switch status {
        case .idle:          return ""
        case .firstIndexing: return L.firstIndexing
        case .rebuilding:    return L.rebuilding
        case .failed(let e): return L.dbOpenFailed(e)
        case .indexFailed:   return L.indexFailed
        case .autoIndexed(let n): return L.autoIndexed(n)
        case .copiedResume:  return L.copiedResume
        case .exporting:     return L.exporting
        case let .exported(files, path): return L.exported(files, path)
        case .exportFailed(let e): return L.exportFailed(e)
        case let .done(sessions, subagents, newMessages, pruned, parseFailures, rebuilt):
            return [
                rebuilt ? L.rebuilt : nil,
                L.sessionCount(sessions),
                subagents > 0 ? L.subagentCount(subagents) : nil,
                newMessages > 0 ? L.newMessages(newMessages) : nil,
                pruned > 0 ? L.prunedSessions(pruned) : nil,
                parseFailures > 0 ? L.parseFailures(parseFailures) : nil,
            ].compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - 订阅额度

    var usage: UsageSnapshot?
    var usageLoading = false
    var usageError: String?

    /// 数据超过这个岁数就重新取。额度是分钟级变化的，没必要更勤 ——
    /// 每次取都要起一个 login shell 跑 claude，约 1 秒。
    private static let usageMaxAge: TimeInterval = 120

    var usageIsStale: Bool {
        guard let usage else { return true }
        return Date().timeIntervalSince(usage.fetchedAt) > Self.usageMaxAge
    }

    /// - Parameter force: 忽略缓存岁数，用户点刷新时传 true
    func loadUsage(force: Bool = false) {
        guard !usageLoading, force || usageIsStale else { return }
        usageLoading = true
        usageError = nil
        Task {
            do {
                usage = try await UsageProbe.fetch()
            } catch {
                usageError = error.localizedDescription
            }
            usageLoading = false
        }
    }

    // MARK: - 会话内查找（⌘F）

    /// 查找条是否显示。
    ///
    /// 和工具栏那个全局搜索框是**两件事**：全局搜索跨全部会话、决定左中两栏列出什么；
    /// 这个只在当前会话正文里找，不动列表。⌘F 给了这一个（macOS 的惯例是
    /// 「在当前视图里查找」），全局搜索挪到 ⌥⌘F。
    var findVisible = false

    /// 会话内要找的字符串。
    ///
    /// **刻意不按空格切词**，和全局搜索不一样：全局搜索把 `sqlite 索引` 当成两个
    /// 词求交集（哪条消息同时含这两个词），而查找条要的是浏览器里那种行为 ——
    /// 连空格一起当一整个子串找。同一个输入在两处给出不同结果是对的，
    /// 因为它们回答的是两个不同的问题。
    var findQuery = "" {
        didSet {
            guard findQuery != oldValue else { return }
            refreshHits()
        }
    }

    /// 每次 ⌘F 递增。查找条已经开着时也要把焦点抢回输入框 ——
    /// 用 Bool 的话第二次 ⌘F 就什么都不会发生。
    var findFocusRequest = 0

    var findActive: Bool {
        findVisible && !findQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func openFind() {
        // 没有打开任何会话时无正文可找，退回全局搜索框 —— 这时两者不存在歧义，
        // 而让 ⌘F 什么都不做是更差的结果
        guard selectedSessionId != nil, !visibleDetail.isEmpty else {
            SearchFieldFocus.focus()
            return
        }
        findVisible = true
        findFocusRequest += 1
    }

    /// 关掉查找条。**必须清空 findQuery** —— 否则正文里的黄色高亮还挂着，
    /// 而已经没有任何界面元素能解释它是从哪来的。
    func closeFind() {
        findVisible = false
        findQuery = ""
    }

    /// 正文高亮与命中定位用的词。查找条开着时它盖过全局搜索词。
    ///
    /// 两者共用同一套下游机制（黄色高亮、左侧命中条、⌘G 跳转、工具栏计数），
    /// 所以会话内查找不需要另做一套 —— 只要在这里换个输入源。
    var detailTerms: [String] {
        Self.activeTerms(find: findQuery, findVisible: findVisible, global: terms)
    }

    /// 抽成纯函数是为了自检能直接断言优先级 —— 这里有三条容易写错的规则：
    /// 查找条开着但输入为空时不能让正文失去全局高亮；查找串带空格时不能被切开；
    /// 查找条关掉后必须干净地回到全局词。
    nonisolated static func activeTerms(find: String, findVisible: Bool,
                                        global: [String]) -> [String] {
        guard findVisible, !find.trimmingCharacters(in: .whitespaces).isEmpty else {
            return global
        }
        return [find]
    }

    // MARK: - 快捷键信号（菜单命令递增/递减它，正文视图 onChange 响应）

    var jumpRequest = 0

    /// 滚到顶 / 底的请求。每次递增，正文视图 onChange 响应。
    /// 用计数器而非 Bool：连点两次要能各自生效。
    var scrollToTopRequest = 0
    var scrollToBottomRequest = 0

    /// ⌘G 走到第几个命中（0 基）。视图跳转后回写这里 ——
    /// 工具栏和查找条都要显示「3/17」，计数得有一个共同的来源。
    var hitCursor = 0

    // MARK: -

    private var search: SearchService?
    private var indexService: IndexService?
    private var watcher: ProjectsWatcher?

    /// 上一轮索引失败、等着重试的路径。
    ///
    /// FSEvents 不会把同一个事件再报一次，所以失败的路径必须自己记着，
    /// 搭下一趟车重试。设上限是因为一个真正损坏的文件会每轮都失败 ——
    /// 让它无限堆积的话，每次增量索引都要陪着它重解析一遍。
    private var pendingRetry: Set<String> = []
    private static let maxPendingRetry = 32
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    /// 这一批该索引哪些路径：新报上来的，加上还欠着的重试。
    nonisolated static func retryBatch(new: [String], pending: Set<String>) -> [String] {
        Array(Set(new).union(pending))
    }

    /// 失败路径里留哪些等下一轮。超过上限就丢掉多的 ——
    /// 坏文件不该拖着每一轮增量索引陪跑。
    nonisolated static func nextPending(failed: [String], limit: Int) -> Set<String> {
        Set(failed.prefix(limit))
    }

    /// 流式刷新时，这次查询的结果能不能覆盖正在显示的正文。
    ///
    /// 空结果覆盖非空正文 = 用户眼前的会话突然变空白。宁可停在上一秒的内容上，
    /// 也不要把已经读到的抹掉。只在 `keepingContent`（后台自动刷新）时这样兜底：
    /// 用户主动切会话时该清就得清，否则会看到上一个会话的残影。
    nonisolated static func shouldKeepExistingDetail(keepingContent: Bool,
                                                     incoming: Int,
                                                     existing: Int) -> Bool {
        keepingContent && incoming == 0 && existing > 0
    }

    init() {
        Task { await bootstrap() }
    }

    // MARK: - 启动流程

    private func bootstrap() async {
        let path = Store.defaultPath
        do {
            search = try SearchService(path: path)
            indexService = try IndexService(path: path)
        } catch {
            status = .failed("\(error)")
            return
        }

        // 旧版本查用量会在 ~/.claude/ 里留探测会话，现在不再需要，清掉。
        // 放在索引之前 —— 否则那个会话会先被扫进列表。
        UsageProbe.cleanUpLegacyProbe()

        // 已有索引先让界面可用，再在后台补齐增量
        await reloadProjects()
        await loadRecent()

        let counts = try? await search?.counts()
        if (counts?.sessions ?? 0) == 0 {
            status = .firstIndexing
        }
        await runIndex()
        startWatching()
    }

    // MARK: - 索引

    /// - Parameter rebuild: 丢弃已索引内容重新解析全部文件（⇧⌘R 走这条）
    func reindex(rebuild: Bool = false) {
        guard !indexing else { return }
        Task { await runIndex(rebuild: rebuild) }
    }

    private func runIndex(rebuild: Bool = false) async {
        guard let indexService, !indexing else { return }
        indexing = true
        indexProgress = (0, 0)
        if rebuild { status = .rebuilding }

        // 进度回调来自后台线程，切回主线程再更新 UI
        let stats = try? await indexService.indexAll(rebuild: rebuild, onProgress: { progress in
            Task { @MainActor [weak self] in
                self?.indexProgress = (progress.scanned, progress.total)
            }
        })
        indexing = false

        if let stats {
            status = .done(sessions: stats.sessions, subagents: stats.subagents,
                           newMessages: stats.newMessages, pruned: stats.pruned,
                           parseFailures: stats.failed.count, rebuilt: stats.rebuilt)
        } else {
            status = .indexFailed
        }
        // 重建后消息 id 会指向别的正文，按 id 缓存的排版结果必须作废
        if rebuild {
            TextCache.invalidate()
            MarkdownCache.invalidate()
            if selectedSessionId != nil { loadDetail() }
        }

        await reloadProjects()
        await loadRecent()
        if hasQuery { await performSearch() }
    }

    /// 监听 ~/.claude/projects，新消息落盘后自动增量索引
    private func startWatching() {
        guard watcher == nil, let indexService else { return }
        watcher = ProjectsWatcher(root: Indexer.defaultRoot.path) { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 把上一轮失败的路径捎上一起重试
                let batch = Self.retryBatch(new: paths, pending: self.pendingRetry)
                self.pendingRetry.removeAll()

                let result = await indexService.indexPaths(batch)
                self.pendingRetry = Self.nextPending(failed: result.failed,
                                                     limit: Self.maxPendingRetry)

                guard result.added > 0 else { return }
                self.status = .autoIndexed(result.added)
                await self.reloadProjects()
                await self.loadRecent()
                if self.hasQuery { await self.performSearch() }
                // 正在看的会话如果正好有新内容，刷新正文。
                //
                // 刷新是无条件的 —— 新输出必须出现在正文里。
                // **跳不跳到底部**才由开关决定：正往回翻历史时被一次次拽到底部
                // 是没法读的（见 FollowSetting）。
                if let sid = self.selectedSessionId {
                    let fileKey = SessionHitGroup.fileKey(of: sid)
                    if batch.contains(where: { $0.contains(fileKey) }) {
                        self.loadDetail(keepingContent: true,
                                        thenScrollToBottom: FollowSetting.shared.enabled)
                    }
                }
            }
        }
        liveWatchActive = watcher?.start() ?? false
    }

    // MARK: - 数据加载

    private func reloadProjects() async {
        projects = (try? await search?.projects()) ?? []
    }

    private func loadRecent() async {
        // 只列主会话。子 agent 是主会话内部派发的工作，不是你「开过」的会话，
        // 混在列表里会把同一件事拆成好几行。要看它们请从会话头部展开。
        recent = (try? await search?.recentSessions(projectId: selectedProjectId,
                                                    includeSubagents: false)) ?? []

        // 没选中任何会话时自动选最新的一个：启动时右栏不空着，
        // 切项目后（didSet 已清空选中项）也跟着切到新项目最新的那个。
        //
        // 刻意只判断「是否为 nil」，不判断「选中项是否还在列表里」——
        // loadRecent 每次索引刷新都会跑，而你可能正在看一个子 agent
        // （它本就不在 recent 里），那种判断会把你踢回最新会话。
        if selectedSessionId == nil, !hasQuery {
            selectedSessionId = recent.first?.sessionId
        }
    }

    private func scheduleSearch(debounce: Bool = true) {
        searchTask?.cancel()
        guard hasQuery else {
            outcome = SearchOutcome()
            searching = false
            Task { await loadRecent() }
            return
        }
        searching = true
        searchTask = Task { [weak self] in
            if debounce {
                // 150 ms 防抖：连续输入时只查最后一次
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    private func performSearch() async {
        guard let search, hasQuery else { return }
        let q = query
        let f = filter
        let result = try? await search.search(q, f)
        guard !Task.isCancelled, q == query else { return }   // 期间输入又变了就丢弃
        outcome = result ?? SearchOutcome()
        searching = false

        // 结果里没有当前选中的会话时，自动选中第一条，右栏不会尬着
        if let first = outcome.groups.first,
           selectedSessionId == nil || !outcome.groups.contains(where: { $0.sessionId == selectedSessionId }) {
            selectedSessionId = first.sessionId
        }
    }

    /// - Parameters:
    ///   - keepingContent: 不切加载态、不收起已展开的消息。同一会话的刷新要用它 ——
    ///     一旦让 `loadingDetail` 变 true，正文视图会被 ProgressView 顶掉，
    ///     重建后滚动位置和展开状态全没了（表现就是「每次自动索引都跳回顶部」）。
    ///   - thenScrollToBottom: 加载完把视口带到最新一条。
    private func loadDetail(keepingContent: Bool = false, thenScrollToBottom: Bool = false) {
        detailTask?.cancel()
        guard let sid = selectedSessionId, let search else {
            detail = []; detailSubagents = []
            detailHasTools = false; skippedToolCount = 0
            refreshVisibleDetail()
            return
        }
        if !keepingContent {
            loadingDetail = true
            expanded = []
        }
        // 只按需要的口径查。工具记录占了正文体积的九成，默认不显示时
        // 连搬进内存都不必 —— 只要知道有多少条，好在正文末尾给个入口。
        let wantTools = showToolsInTranscript
        detailTask = Task { [weak self] in
            let msgs = (try? await search.messages(sessionId: sid,
                                                   conversationOnly: !wantTools)) ?? []
            let skipped = wantTools ? 0 : ((try? await search.toolMessageCount(sessionId: sid)) ?? 0)
            let subs = (try? await search.subagents(of: sid)) ?? []
            // 点开子 agent 时它不在任何列表里，补查一次它自己的元信息
            let resolved = try? await search.session(id: sid)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.selectedSessionId == sid else { return }
                // `keepingContent` 的字面意思是「别动已经显示的内容」，但它原来只
                // 管了 loading 指示和折叠状态 —— 正文仍然被无条件覆盖，查询一旦
                // 返回空（出错被 `try?` 吞成 []、或读到写入中途的状态），正在看的
                // 会话就当场变成一片空白。
                //
                // 这里补上：流式刷新时，空结果不许覆盖非空的正文。宁可让画面停在
                // 上一秒的内容上等下一轮，也不能把已经读到的东西抹掉 —— 前者用户
                // 未必察觉，后者是肉眼可见的故障。
                if Self.shouldKeepExistingDetail(keepingContent: keepingContent,
                                                 incoming: msgs.count,
                                                 existing: self.detail.count) {
                    self.loadingDetail = false
                    return
                }
                self.detail = msgs
                self.detailHasTools = wantTools
                self.skippedToolCount = skipped
                self.detailSubagents = subs
                self.resolvedSession = resolved
                self.refreshVisibleDetail()
                self.loadingDetail = false
                self.detailVersion += 1
                // 递增在 detail 落定之后 —— 正文视图靠它触发滚动，
                // 早了就会滚到还没加进去的旧末尾上
                if thenScrollToBottom { self.scrollToBottomRequest += 1 }
            }
        }
    }

    // MARK: - 正文里的命中定位

    /// 当前选中会话中命中了查询的消息 id，按顺序排列，供 ⌘G 跳转。
    /// 只统计可见的消息 —— 否则会跳到一条被隐藏的工具记录上，看起来像没反应。
    private(set) var hitIdsInDetail: [Int64] = []

    /// 可见正文的**小写 UTF-8 字节**副本，随 `visibleDetail` 一起重算。
    ///
    /// 匹配原来是现算 `msg.text.lowercased()` 再 `contains`。全局搜索下它只在
    /// 换会话时跑一次，代价看不见；查找条把它变成了**每敲一个字符跑一次**，
    /// 于是这条路径的成本第一次真正暴露出来。库里最大的会话
    /// （3441 条可见消息 / 2.4 MB 正文）上实测：
    ///
    /// | 做法 | 每次按键 |
    /// |---|---|
    /// | 现算 `lowercased()` + `String.contains`（旧路径） | 90 ms |
    /// | 预先小写，`String.contains` | 47 ms |
    /// | 预先小写，`range(of:options:.literal)` | 14 ms |
    /// | 预先小写成 UTF-8 字节，逐字节找 | **1.5 ms** |
    ///
    /// `String.contains` 慢在它走 ICU 的规范等价比较 —— 查找条不需要那个语义
    /// （grep 也不做），换成字节匹配比旧路径快约 60 倍，最大的会话上也不卡手。
    /// 小写只在加载时付一次（约 50 ms，那时正在等库、看不出来）。
    ///
    /// 正确性靠 UTF-8 是**自同步编码**：多字节字符的字节序列不可能出现在
    /// 另一个字符的字节中间，所以字节级子串命中等价于字符级命中，不会多找出东西。
    /// 唯一的语义差别是不做规范等价（`é` 的两种写法互不匹配）—— 和 grep 一致。
    private var loweredVisible: [Haystack] = []

    /// 一条消息的可搜形态：id + 小写后的 UTF-8 字节。
    struct Haystack: Sendable {
        let id: Int64
        let bytes: [UInt8]
    }

    nonisolated static func haystack(id: Int64, text: String) -> Haystack {
        Haystack(id: id, bytes: Array(text.lowercased().utf8))
    }

    /// 正文口径变了就重算派生数据。顺序有依赖：命中集合建立在可见正文之上。
    private func refreshVisibleDetail() {
        visibleDetail = showToolsInTranscript
            ? detail
            : detail.filter { $0.kind == "text" || $0.kind == "thinking" }
        loweredVisible = visibleDetail.map { Self.haystack(id: $0.id, text: $0.text) }
        // 装了全量就直接减；只装了对话正文就用库里数出来的那个数
        hiddenToolCount = showToolsInTranscript
            ? 0
            : (detailHasTools ? detail.count - visibleDetail.count : skippedToolCount)
        refreshHits()
    }

    private func refreshHits() {
        hitIdsInDetail = Self.matchIds(in: loweredVisible, terms: detailTerms)
    }

    /// 哪些消息命中了这些词。多个词是**求交集**（一条消息要同时含全部词），
    /// 单个词就是子串匹配 —— 查找条走的就是后者。
    ///
    /// 返回顺序跟正文顺序一致，⌘G 才能是「往下一个」而不是乱跳。
    nonisolated static func matchIds(in items: [Haystack], terms: [String]) -> [Int64] {
        let needles = terms.map { Array($0.lowercased().utf8) }.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        return items.compactMap { item in
            needles.allSatisfy { containsBytes(item.bytes, $0) } ? item.id : nil
        }
    }

    /// 朴素的字节级子串查找。
    ///
    /// 刻意不用 KMP 之类：查找串是人手打的（几个字符），朴素算法的最坏情况
    /// 在这个输入分布下不会发生，而实测已经 1.5 ms/次。多一份复杂度换不到东西。
    nonisolated static func containsBytes(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    func toggleExpanded(_ id: Int64) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// 在 Finder 里显示这个会话对应的项目目录
    func revealProject(_ group: SessionHitGroup) {
        guard !group.projectCwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: group.projectCwd)
    }

    func revealProjectDir(_ project: ProjectRow) {
        guard !project.cwd.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.cwd)
    }

    // MARK: - 导出

    /// 把一个会话导成 Markdown。
    /// - Parameter includeTools: 连工具调用与输出一起导。默认关是因为工具记录
    ///   通常占正文体积的九成，多数时候要的只是对话本身。
    func exportSession(_ group: SessionHitGroup, includeTools: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Export.fileName(for: group)
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        panel.canCreateDirectories = true
        panel.message = includeTools ? L.exportFullMessage : L.exportConversationMessage
        guard panel.runModal() == .OK, let url = panel.url, let search else { return }

        status = .exporting
        Task {
            let msgs = (try? await search.messages(sessionId: group.sessionId,
                                                   conversationOnly: !includeTools)) ?? []
            let text = Export.markdown(session: group, messages: msgs)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                status = .exported(files: 1, path: url.path)
                flash(L.exported(1, url.path))
            } catch {
                status = .exportFailed("\(error.localizedDescription)")
                flash(L.exportFailed("\(error.localizedDescription)"), isError: true)
            }
        }
    }

    /// 把一个项目下的全部会话导到一个目录：`index.csv` 是完整清单（含子 agent），
    /// 每个会话另存一份 Markdown 正文。
    ///
    /// 正文只导对话，不含工具记录 —— 项目级导出是拿来回顾和归档的，
    /// 带上工具输出动辄几十 MB。要某个会话的完整记录，右键那个会话单独导。
    func exportProject(_ project: ProjectRow) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L.exportChooseFolder
        panel.message = L.exportProjectMessage(project.displayName)
        guard panel.runModal() == .OK, let root = panel.url, let search else { return }

        status = .exporting
        Task {
            do {
                let n = try await writeProjectExport(project, into: root, search: search)
                status = .exported(files: n.files, path: n.dir)
                flash(L.exported(n.files, n.dir))
            } catch {
                status = .exportFailed("\(error.localizedDescription)")
                flash(L.exportFailed("\(error.localizedDescription)"), isError: true)
            }
        }
    }

    /// - Returns: 写出的文件数和落地目录
    private func writeProjectExport(_ project: ProjectRow, into root: URL,
                                    search: SearchService) async throws -> (files: Int, dir: String) {
        // 含子 agent：它们也是这个项目下的会话，清单要完整
        let sessions = try await search.recentSessions(projectId: project.id,
                                                       includeSubagents: true,
                                                       limit: 100_000)
        let out = try await Export.writeProject(
            name: project.displayName, sessions: sessions, into: root
        ) { sid in
            let msgs = (try? await search.messages(sessionId: sid, conversationOnly: true)) ?? []
            let tools = (try? await search.toolMessageCount(sessionId: sid)) ?? 0
            return (msgs, tools)
        }
        return (out.files, out.dir.path)
    }

    /// 恢复会话用的命令。
    ///
    /// 展开写全，**不用 `yolor` 那个 alias**：alias 只在交互式 shell 里生效，
    /// 粘进脚本、换台机器、或者贴给别人就全废了，而且看的人无从知道它到底跑了什么。
    /// 复制出来的命令应该到哪都能跑、且自解释。
    ///
    /// `nonisolated`：只是个字符串常量，跟 UI 线程没关系。
    /// 不加的话 AppModel 的 `@MainActor` 会把它一起隔离，自检里读不到。
    nonisolated static let resumeCommand =
        "claude --dangerously-skip-permissions --chrome --resume"

    /// 拼恢复命令。提成纯函数是为了自检能盯住它 —— 尤其路径转义那条：
    /// 项目目录带空格时不转义的话，粘到终端 `cd` 会断在空格处。
    nonisolated static func resumeCommandLine(cwd: String, fileKey: String) -> String {
        "cd \(cwd.replacingOccurrences(of: " ", with: "\\ ")) && \(resumeCommand) \(fileKey)"
    }

    /// 复制恢复命令，便于粘到终端里执行
    /// 复制任意一段文字并给个反馈。Markdown 渲染之后跨块选不了字，
    /// 复制按钮是它的替代路径，所以这条要有明确的成功提示。
    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(L.copiedMessage)
    }

    func copyResumeCommand(_ group: SessionHitGroup) {
        // resume 只认父会话，group.fileKey 已经是父会话 id
        let cmd = Self.resumeCommandLine(cwd: group.projectCwd, fileKey: group.fileKey)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        status = .copiedResume
        flash(L.copiedResume)
    }
}
