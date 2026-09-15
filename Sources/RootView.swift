import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    /// 语言与主题菜单的 Picker 要绑到它们
    @Bindable private var lang = LanguageSetting.shared
    @Bindable private var theme = AppearanceSetting.shared
    @Bindable private var follow = FollowSetting.shared
    @Bindable private var markdown = MarkdownSetting.shared

    var body: some View {
        NavigationSplitView {
            // navigationTitle 和 List 的 Section 头是 SwiftUI 缓存的，
            // 光靠视图重绘不一定刷新。换语言时改 id 强制重建这两栏。
            // 只加在栏内部，不加在 NavigationSplitView 上 —— 否则分栏宽度会被重置。
            SidebarView(model: model)
                .id(lang.resolved)
                .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 320)
        } content: {
            ResultListView(model: model)
                .id(lang.resolved)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 560)
        } detail: {
            DetailView(model: model)
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: L.searchPrompt)
        .toolbar { toolbarItems }
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        // Toast 浮在最上层。`.allowsHitTesting(false)` 必须加在 **toast 自己身上**，
        // 不能加到外层 —— 加错地方会把整个界面点死。
        // 它只是个通知，下面的搜索、选中、滚动都得照常能操作。
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .allowsHitTesting(false)
                    .padding(.bottom, 54)      // 让开底部状态条
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)              // id 变了才会重播动画（连点两次也有反馈）
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.toast)
        // 工具栏提示由 AppKit 直接装（SwiftUI 的 .help() 在工具栏里不生效）。
        // trigger 里带上会影响 item 集合的状态：语言、有无命中、有无正文。
        .installToolbarTooltips(trigger: TooltipTrigger(
            language: lang.resolved,
            hasHits: !model.hitIdsInDetail.isEmpty,
            hasDetail: !model.visibleDetail.isEmpty,
            hasSession: model.selectedSession != nil,
            toolsShown: model.showToolsInTranscript
        ), toolsShown: model.showToolsInTranscript)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // 语言和主题都是「外观偏好」，合在一个菜单里，
        // 免得工具栏被一堆图标占满
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(L.language, selection: $lang.selection) {
                    ForEach(AppLanguage.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                Picker(L.theme, selection: $theme.selection) {
                    ForEach(AppTheme.allCases, id: \.self) { option in
                        Label(option.label, systemImage: option.icon).tag(option)
                    }
                }
                .pickerStyle(.inline)

                Divider()

                // 关掉它，正文照样跟着刷新，只是视口不再被拽走
                Toggle(L.followNewOutput, isOn: $follow.enabled)
                // 关掉可以换回「整条能选中」的纯文本
                Toggle(L.renderMarkdown, isOn: $markdown.enabled)
            } label: {
                Label(L.language, systemImage: "gearshape")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            UsageButton(model: model)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle(L.searchToolOutput, isOn: $model.filter.includeToolNoise)
                // 子 agent 的命中会归并到派发它的主会话上，不单独成行
                Toggle(L.searchSubagents, isOn: $model.filter.includeSubagents)
                Divider()
                Picker(L.scope, selection: roleBinding) {
                    Text(L.scopeAll).tag(RoleScope.all)
                    Text(L.scopeHuman).tag(RoleScope.human)
                    Text(L.scopeAssistant).tag(RoleScope.assistant)
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(L.sortByHits, isOn: $model.filter.sortByRelevance)
                Divider()
                Button(L.rebuildIndex) { model.reindex(rebuild: true) }
            } label: {
                Label(L.filter, systemImage: model.filterIsDefault ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    private var roleBinding: Binding<RoleScope> {
        Binding(
            get: {
                if model.filter.humanOnly { return .human }
                if model.filter.assistantOnly { return .assistant }
                return .all
            },
            set: { scope in
                var f = model.filter
                f.humanOnly = scope == .human
                f.assistantOnly = scope == .assistant
                model.filter = f
            }
        )
    }
}

enum RoleScope: Hashable { case all, human, assistant }

/// 工具栏 item 集合会随这些状态变化，变了就要重装提示
struct TooltipTrigger: Hashable {
    let language: AppLanguage
    let hasHits: Bool
    let hasDetail: Bool
    let hasSession: Bool
    let toolsShown: Bool
}

// MARK: - 左栏：项目列表

/// 侧栏选中的范围。
///
/// 不能直接拿 `Int64?` 当 List 的 selection：SwiftUI 把 `nil` 解释成
/// **「没有选中」**，于是 `.tag(nil)` 的那一行和「无选中」无法区分 ——
/// 选了某个具体项目之后再点「全部项目」，binding 不会被设回 nil，那一行就点不动。
/// 给「全部」一个真实的 case，`nil` 才重新只表示无选中。
enum ProjectScope: Hashable {
    case all
    case project(Int64)
}

struct SidebarView: View {
    @Bindable var model: AppModel

    /// 把 `ProjectScope` 桥接到模型里的 `Int64?` —— 模型侧的口径
    /// （nil = 不按项目过滤）被别处用着，不动它
    private var scope: Binding<ProjectScope?> {
        Binding(
            get: { model.selectedProjectId.map(ProjectScope.project) ?? .all },
            set: { new in
                if case .project(let id) = new {
                    model.selectedProjectId = id
                } else {
                    // .all 和 nil（⌘点取消选中）都回到「不过滤」
                    model.selectedProjectId = nil
                }
            }
        )
    }

    var body: some View {
        List(selection: scope) {
            Section {
                row(label: L.allProjects, count: model.projects.reduce(0) { $0 + $1.sessionCount },
                    icon: "square.stack.3d.up", tag: .all)
            }
            Section(L.projects) {
                ForEach(model.projects) { project in
                    row(label: project.displayName, count: project.sessionCount,
                        icon: "folder", tag: .project(project.id))
                        .help(project.cwd)
                        .contextMenu {
                            Button(L.exportProject) { model.exportProject(project) }
                            Button(L.revealInFinder) { model.revealProjectDir(project) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(label: String, count: Int, icon: String, tag: ProjectScope) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 14)
            Text(label)
                .lineLimit(1)
                .truncationMode(.head)     // 路径尾部（叶子目录）更有辨识度
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        // tag 必须是**非可选**的 ProjectScope。selection 绑的是 `ProjectScope?` 时
        // SwiftUI 推出的 SelectionValue 就是 ProjectScope；给可选值它匹配不上，
        // 表现为整列都不高亮、点了也没反应。
        .tag(tag)
    }
}

// MARK: - Toast

/// 浮在界面底部中间的一次性提示。纯展示，不接受任何交互 ——
/// 拦截点击的职责在调用处用 `.allowsHitTesting(false)` 关掉。
struct ToastView: View {
    let toast: AppModel.Toast

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.isError
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(toast.isError ? Color.orange : Color.green)
            Text(toast.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .font(.callout)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        // 半透明材质：底下的内容能透出来一点，提醒这是临时浮层而不是新面板
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .frame(maxWidth: 520)
    }
}

// MARK: - 底部状态条

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.indexing {
                ProgressView().controlSize(.small)
                if model.indexProgress.total > 0 {
                    Text(L.indexingProgress(model.indexProgress.done, model.indexProgress.total))
                } else {
                    Text(L.indexing)
                }
            } else {
                Circle()
                    .fill(model.liveWatchActive ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(model.statusLine)
                    .lineLimit(1)
            }

            Spacer()

            if model.hasQuery {
                if model.searching {
                    ProgressView().controlSize(.small)
                } else {
                    Text(model.resultSummary)
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
