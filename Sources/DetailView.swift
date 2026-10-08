import SwiftUI

/// 右栏：会话正文
@MainActor
struct DetailView: View {
    @Bindable var model: AppModel
    @State private var lastJumpRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            // 会话信息固定在顶部，不随正文滚动 —— 正文默认停在最新一条，
            // 头部若跟着滚就永远看不到会话 id 了。
            if let session = model.selectedSession, !model.loadingDetail {
                SessionHeader(session: session, subagents: model.detailSubagents,
                              onSelectSubagent: { model.selectedSessionId = $0 })
                Divider()
            }
            // 查找条放在正文**上方**而不是浮在上面：它是常驻条不是一次性提示，
            // 浮层会挡住正文第一行，而正文第一行常常正是要找的那条
            if model.findVisible {
                FindBar(model: model)
                Divider()
            }
            content
        }
        .navigationTitle(model.selectedSession?.displayTitle ?? L.session)
        .toolbar { detailToolbar }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if model.selectedSessionId == nil {
                placeholder(L.selectSession, icon: "text.bubble")
            } else if model.loadingDetail {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleDetail.isEmpty {
                // 纯工具流水的会话（常见于子 agent）没有任何对话正文
                VStack(spacing: 10) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 34)).foregroundStyle(.tertiary)
                    // 判据用 hiddenToolCount 而不是 detail —— 默认口径下
                    // 工具记录压根没查出来，detail 空不代表会话空
                    Text(model.hiddenToolCount == 0 ? L.noContent : L.onlyToolRecords)
                        .foregroundStyle(.secondary)
                    if model.hiddenToolCount > 0 {
                        Button(L.showToolRecords(model.hiddenToolCount)) {
                            model.showToolsInTranscript = true
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 换会话时整块重建（含 ScrollViewReader）：旧的滚动偏移量若留着，
                // 从长会话切到短会话会超出新内容高度，看到的就是一片空白。
                // .id() 必须加在 ScrollViewReader 外面 —— 加在里面的 ScrollView 上
                // 会让 proxy 指向被销毁的视图，窗口直接不显示。
                transcript.id(model.selectedSessionId ?? "none")
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    // 顶部锚点。用它而不是第一条消息的 id —— 滚到首条消息时
                    // 它上方的 padding 会被顶出视口，看着像少了一截。
                    Color.clear
                        .frame(height: 1)
                        .id(Self.topAnchor)

                    let hits = Set(model.hitIdsInDetail)
                    ForEach(model.visibleDetail) { msg in
                        MessageBubble(
                            message: msg,
                            terms: model.detailTerms,
                            isHit: hits.contains(msg.id),
                            expanded: model.expanded.contains(msg.id),
                            onToggle: { model.toggleExpanded(msg.id) },
                            onCopy: { model.copyText($0) }
                        )
                        .id(msg.id)
                    }

                    // 展开与收回放在同一处，否则用户找不到回去的路
                    if model.showToolsInTranscript {
                        toolToggle(title: L.hideToolCalls, icon: "eye.slash", on: false)
                    } else if model.hiddenToolCount > 0 {
                        toolToggle(title: L.showToolCalls(model.hiddenToolCount),
                                   icon: "wrench.and.screwdriver", on: true)
                    }

                    // 底部锚点。兼作滚动目标：滚到它才能真正露出上面那个按钮。
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .padding(16)
                // 状态栏是 safeAreaInset 加在 NavigationSplitView 上的，
                // 不会内缩这个 ScrollView，末尾内容会被它压住。
                .padding(.bottom, 28)
            }
            .onChange(of: model.jumpRequest) { _, new in
                jump(delta: new - lastJumpRequest, proxy: proxy)
                lastJumpRequest = new
            }
            // 边打字边跳到第一个命中，跟浏览器的查找一致 —— 敲完还要再按一次
            // 「下一个」才动的话，根本看不出有没有找到
            .onChange(of: model.findQuery) { _, _ in
                model.hitCursor = 0
                guard let first = model.hitIdsInDetail.first else { return }
                reveal(first)
                proxy.scrollTo(first, anchor: .center)
            }
            // 首尾跳转刻意不加动画。scrollTo 到远处的锚点会迫使 LazyVStack
            // 把中间所有行都建出来并排版；再套上动画，这份代价在动画的每一帧
            // 都要付一次 —— 实测就是「点滚动到底部要卡很久」的直接原因。
            .onChange(of: model.scrollToTopRequest) { _, _ in
                proxy.scrollTo(Self.topAnchor, anchor: .top)
            }
            .onChange(of: model.scrollToBottomRequest) { _, _ in
                scrollToBottom(proxy)
            }
            // 打开一个会话时把视口带到该看的地方。
            //
            // 这里曾经刻意什么都不做：直接 scrollTo 会撞上 LazyVStack 的高度估算，
            // 把视口推进空白区。现在 `scrollToBottom` 先锚定最后一条**消息**
            // （有真实高度），那个风险已经消除，所以可以放心滚了。
            .onAppear {
                model.hitCursor = 0
                DispatchQueue.main.async {
                    if let firstHit = model.hitIdsInDetail.first {
                        // 带查询时跳第一个命中 —— 搜完当然想先看到匹配处，
                        // 这条优先于「滚到底」
                        proxy.scrollTo(firstHit, anchor: .center)
                    } else {
                        // 没查询时停在最新一条：会话是按时间累积的，
                        // 打开一个会话通常是想接着看最后聊到哪
                        scrollToBottom(proxy)
                    }
                }
            }
        }
    }

    /// 滚到底部。分两步，不能直接跳底部锚点。
    ///
    /// 为什么：`LazyVStack` 用**估算**高度算落点，而正文行高差异极大
    /// （8000 字的和三个词的并存），估错一行就能偏几千点。底部锚点只有 1pt 高，
    /// 一偏就整个出视口 —— 屏幕全空，往回滚一点触发重建才看得见内容。
    ///
    /// 两步的分工：
    /// 1. 先跳**最后一条消息**。它有真实高度，落点即使偏一些，屏幕上也一定有东西；
    ///    同时这一跳迫使末尾那几行真正被构建和测量。
    /// 2. 下一拍再对齐底部锚点。此时邻近行高已经量准，这一跳距离短、落点可靠，
    ///    末尾那个「显示工具记录」按钮才能真正露出来。
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        // 第一步：跳最后一条**消息**，不是底部锚点。
        // 它有真实高度，所以哪怕落点偏了，屏幕上也一定有内容 ——
        // 这一条本身就让「滚到底却一片空白」无法成立。
        if let last = model.visibleDetail.last?.id {
            proxy.scrollTo(last, anchor: .bottom)
        }
        // 第二步：连着校正几拍。每一拍都有更多末尾行被真正构建和测量，
        // 落点随之收敛，最后那个「显示工具记录」按钮才能完整露出来。
        // 校正窗口压在 0.25s 内，免得和用户接着的手动滚动打架。
        for delay in [0.0, 0.08, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    /// 首尾锚点的 id（正文首尾各放了个 1pt 占位视图）
    private static let topAnchor = "transcript-top"
    private static let bottomAnchor = "transcript-bottom"

    @ViewBuilder
    private func toolToggle(title: String, icon: String, on: Bool) -> some View {
        Button {
            model.showToolsInTranscript = on
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quinary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 6)
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if !model.hitIdsInDetail.isEmpty {
                Text(L.hitCounter(model.hitCursor, of: model.hitIdsInDetail.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                // 用 Label 而非裸 Image：item.label 有值，ToolbarTooltips 才能
                // 按名字找到它装提示（详见 ToolbarTooltips 的说明）
                Button { model.jumpRequest -= 1 } label: {
                    Label(L.prevHit, systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                Button { model.jumpRequest += 1 } label: {
                    Label(L.nextHit, systemImage: "chevron.down").labelStyle(.iconOnly)
                }
            }

            // 滚到首/末。和命中跳转放在一起 —— 都是「移动视口」的操作。
            if !model.visibleDetail.isEmpty {
                Button { model.scrollToTopRequest += 1 } label: {
                    Label(L.scrollToTop, systemImage: "arrow.up.to.line").labelStyle(.iconOnly)
                }
                Button { model.scrollToBottomRequest += 1 } label: {
                    Label(L.scrollToBottom, systemImage: "arrow.down.to.line").labelStyle(.iconOnly)
                }
            }
            // 纯图标看不出管什么，带上文字
            Toggle(isOn: $model.showToolsInTranscript) {
                Label(L.toolRecords, systemImage: model.showToolsInTranscript
                      ? "wrench.and.screwdriver.fill" : "wrench.and.screwdriver")
            }
            .toggleStyle(.button)

            if let session = model.selectedSession {
                // 按钮干的事是「复制到剪贴板」，不是「恢复会话」——
                // 用系统标准的复制图标，别用回退箭头误导人以为点了就接着聊
                Button { model.copyResumeCommand(session) } label: {
                    Label(L.copyResume, systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
            }
        }
    }

    private func jump(delta: Int, proxy: ScrollViewProxy) {
        let hits = model.hitIdsInDetail
        guard !hits.isEmpty else { return }
        model.hitCursor = Self.wrap(model.hitCursor + delta, count: hits.count)
        let target = hits[model.hitCursor]
        reveal(target)
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    /// 命中落在一条默认折叠的消息里（thinking / 工具记录）时，跳过去只会看到
    /// 一行折叠标题，黄色高亮全在里面 —— 看着像跳错了。所以跳转时顺手展开它。
    /// 只展开跳到的那一条，不批量展开全部命中：一条 thinking 动辄上万字。
    private func reveal(_ id: Int64) {
        guard let msg = model.visibleDetail.first(where: { $0.id == id }),
              msg.kind != "text", !model.expanded.contains(id) else { return }
        model.expanded.insert(id)
    }

    /// 命中之间循环。Swift 的 `%` 对负数返回负值，直接拿来当下标会崩 ——
    /// 在第一个命中上按「上一个」正是这个情形。
    nonisolated static func wrap(_ i: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (i % count + count) % count
    }

    @ViewBuilder
    private func placeholder(_ text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 会话内查找条

/// ⌘F 拉出来的查找条。只在当前会话正文里找，不影响左中两栏的列表 ——
/// 那是工具栏那个全局搜索框的事（⌥⌘F）。
///
/// 计数按**消息**算，不是按出现次数：跳转的落点是消息（`LazyVStack` 的锚点
/// 只能是行），一条消息里出现五次也只能跳到这一条。写成「3/17 处」会让人以为
/// 按「下一个」能在同一条里挪，所以文案明说是条数。
@MainActor
struct FindBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    private var hits: Int { model.hitIdsInDetail.count }
    private var hasInput: Bool {
        !model.findQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(L.findInSession, text: $model.findQuery)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { model.jumpRequest += 1 }   // ↩ = 下一个
                .frame(minWidth: 120, maxWidth: 320)

            if hasInput {
                if hits > 0 {
                    Text(L.hitCounter(model.hitCursor, of: hits))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(L.hitCounterHelp)
                } else {
                    Text(L.findNoMatch)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Button { model.jumpRequest -= 1 } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(hits == 0)
            .help(L.prevHitHelp)

            Button { model.jumpRequest += 1 } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(hits == 0)
            .help(L.nextHitHelp)

            Spacer(minLength: 0)

            // 找不到时给一句去处：工具记录默认不显示，而要找的东西
            // （命令、报错、文件名）恰恰大量落在里面。
            // 刻意不说「那里面有 N 处」—— 它们压根没装进内存，说了就是瞎猜。
            if hasInput, hits == 0, model.hiddenToolCount > 0 {
                Button(L.findTryTools(model.hiddenToolCount)) {
                    model.showToolsInTranscript = true
                }
                .buttonStyle(.link)
                .font(.caption)
            }

            Button { model.closeFind() } label: {
                Image(systemName: "xmark")
            }
            .help(L.findClose)

            // Esc 关闭。只在查找条显示时才存在这个按钮，
            // 否则 Esc 会在整个 app 里被它吃掉。
            Button("") { model.closeFind() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
        .onAppear { focused = true }
        // ⌘F 再按一次要把焦点抢回来（可能正在正文里选文字）
        .onChange(of: model.findFocusRequest) { _, _ in focused = true }
    }
}

// MARK: - 会话头部

@MainActor
struct SessionHeader: View {
    let session: SessionHitGroup
    let subagents: [SessionHitGroup]
    let onSelectSubagent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if session.isSidechain {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
                Text(session.displayTitle)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 8)
                SessionIdLabel(sessionId: session.sessionId)
            }

            HStack(spacing: 6) {
                Label(session.projectName, systemImage: "folder")
                Text("·").foregroundStyle(.quaternary)
                Text(When.full(session.startedAt))
                if session.startedAt != session.endedAt {
                    Text("→ \(When.full(session.endedAt))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !subagents.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(subagents) { sub in
                            Button {
                                onSelectSubagent(sub.sessionId)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.caption2)
                                        .foregroundStyle(.purple)
                                    Text(sub.displayTitle).lineLimit(1)
                                    if let type = sub.agentType {
                                        Text(type)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(L.plainCount(sub.hitCount))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 3)
                } label: {
                    Text(L.subagentsIn(subagents.count))
                        .font(.caption.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

/// 会话 id —— 也就是 ~/.claude/projects/<项目>/ 下那个 jsonl 的文件名。
/// 点一下即可复制，恢复会话（`claude … --resume <id>`）要用它。
@MainActor
struct SessionIdLabel: View {
    let sessionId: String
    @State private var copied = false

    /// 子 agent 的库内主键是「父会话:agent 文件名」合成的。
    /// 拆开显示，别让人以为文件真叫这个名字。
    private var parts: (parent: String, agent: String?) {
        let bits = sessionId.split(separator: ":", maxSplits: 1).map(String.init)
        return bits.count == 2 ? (bits[0], bits[1]) : (sessionId, nil)
    }

    var body: some View {
        let p = parts
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.parent, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            HStack(spacing: 4) {
                Text(p.parent)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                if let agent = p.agent {
                    Text("›").foregroundStyle(.quaternary)
                    Text(agent)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.purple)
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help(copied ? L.copiedSessionId : L.copySessionId)
    }
}

// MARK: - 单条消息

@MainActor
struct MessageBubble: View {
    let message: DetailMessage
    let terms: [String]
    let isHit: Bool
    let expanded: Bool
    let onToggle: () -> Void
    let onCopy: (String) -> Void

    @State private var hovering = false

    /// thinking 和工具相关的内容默认折叠 —— 它们体量大且多半不是要读的东西
    private var collapsible: Bool { message.kind != "text" }

    /// 哪些内容按 Markdown 渲染。
    ///
    /// 只有 **Claude 的正式回复**。刻意排除的三类：
    /// - `user` 的 text：那是你亲手打的字，原样才对；
    /// - `tool_result`：命令和接口的原始输出，等宽原样才读得懂；
    /// - `thinking`：也是 Claude 写的、也像 Markdown，但它默认折叠、
    ///   是草稿性质的推理过程，这一步先不动它（留作以后）。
    private var rendersMarkdown: Bool {
        MarkdownSetting.shared.enabled
            && message.role == "assistant" && message.kind == "text"
    }

    /// 复制按钮送出去的正文。渲染成什么样就复制什么样。
    private var copyPlain: String {
        rendersMarkdown ? Markdown.plainText(message.text) : message.text
    }

    /// 「我发出的消息」。必须连 kind 一起判：`role == "user"` 的记录里
    /// 绝大多数（实测 34287 / 38670）其实是 tool_result —— 那是工具回填给模型的，
    /// 挂在 user 名下只是协议如此，并不是人打的字。
    private var isMine: Bool { message.role == "user" && message.kind == "text" }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if !collapsible || expanded {
                // 超长正文默认只排前一段。排版是打开长会话最大的开销，
                // 而一条几万字的消息没人会一口气读完。
                let clip = Highlight.clip(message.text, expanded: expanded)
                if rendersMarkdown {
                    // 截断可能切在围栏中间，切分器按「吃到结尾」处理，不会丢内容
                    MarkdownBody(messageId: message.id,
                                 blocks: MarkdownCache.blocks(id: message.id,
                                                              text: clip.shown,
                                                              clipped: clip.hidden > 0),
                                 terms: terms,
                                 onCopy: onCopy)
                } else {
                    Text(TextCache.attributed(id: message.id, text: clip.shown, terms: terms,
                                              clipped: clip.hidden > 0, mono: collapsible))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if clip.hidden > 0 {
                    Button(action: onToggle) {
                        Label(L.showFullText(clip.hidden), systemImage: "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                }
            }
        }
        .padding(10)
        .background(background)
        .overlay(alignment: .leading) {
            if isHit {
                Rectangle().fill(.yellow).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 5) {
            Text(roleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(roleColor)

            if let tool = message.toolName {
                Text(tool)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            } else if collapsible {
                Text(kindLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if collapsible {
                Button(action: onToggle) {
                    HStack(spacing: 2) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8))
                        if !expanded {
                            Text(preview)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            // 渲染成 Markdown 之后跨块选不了文字，复制按钮是它的替代品。
            // 只在悬停时可见 —— 一屏几十条消息，常驻会变成一片噪点。
            //
            // 用 opacity 而不是 `if hovering`：条件渲染会让按钮出现时把时间戳
            // 往左挤一下，鼠标扫过一屏就是一串横向抖动。占位一直在，只是看不见。
            //
            // 复制出去的是**纯文本**，不是原文。`**粗体**`、`|---|` 这些字符是
            // 写给渲染器看的，粘进邮件或工单只会碍眼。要原汁原味的 Markdown
            // 走右键 —— 那是粘回 Claude、贴进 issue 时才需要的。
            //
            // 只对按 Markdown 渲染的消息这么做。你自己打的字、命令输出、
            // thinking 屏幕上就是原样显示的，剥它等于改你的话。
            Button { onCopy(copyPlain) } label: {
                Image(systemName: "doc.on.doc").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(rendersMarkdown ? L.copyMessage : L.copyMessageRaw)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .contextMenu {
                if rendersMarkdown {
                    Button(L.copyMessagePlain) { onCopy(copyPlain) }
                    Button(L.copyMessageMarkdown) { onCopy(message.text) }
                }
            }

            // 时间未知就整个不渲染 —— 不留占位符
            if let ts = When.messageStamp(message.timestamp) {
                Text(ts)
                    .font(.caption2)
                    .monospacedDigit()          // 等宽数字，纵向对齐
                    // 自己发的消息给足对比度：那是「我什么时候说的这句话」，
                    // 翻会话时真的要读。Claude 的回复和工具记录动辄几百条，
                    // 时间戳同样醒目只会喧宾夺主，保持很淡。
                    .foregroundStyle(isMine ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(.quaternary))
            }
        }
    }

    private var preview: String {
        Highlight.flatten(String(message.text.prefix(90)))
    }

    private var roleLabel: String {
        switch message.kind {
        case "thinking": return L.roleThinking
        case "tool_use": return L.roleToolUse
        case "tool_result": return L.roleToolResult
        default: return message.role == "user" ? L.roleMe : L.roleClaude
        }
    }

    private var kindLabel: String {
        switch message.kind {
        case "thinking": return L.kindThinking
        case "tool_result": return L.kindToolResult
        default: return message.kind
        }
    }

    private var roleColor: Color {
        switch message.kind {
        case "thinking": return .orange
        case "tool_use", "tool_result": return .gray
        default: return message.role == "user" ? .blue : .green
        }
    }

    private var background: some ShapeStyle {
        if collapsible { return AnyShapeStyle(.quinary) }
        return AnyShapeStyle(message.role == "user"
            ? Color.blue.opacity(0.07)
            : Color.gray.opacity(0.07))
    }
}
