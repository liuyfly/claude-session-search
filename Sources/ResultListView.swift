import SwiftUI

/// 中栏：搜到的会话（或未搜索时的最近会话）
@MainActor
struct ResultListView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.listedSessions.isEmpty {
                emptyState
            } else {
                List(selection: $model.selectedSessionId) {
                    Section(header) {
                        ForEach(model.listedSessions) { group in
                            SessionRow(group: group, showPreviews: model.hasQuery)
                                .tag(group.sessionId)
                                .contextMenu { menu(for: group) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(model.hasQuery ? L.searchResults : L.recentSessions)
    }

    private var header: String {
        model.hasQuery
            ? L.groupCount(model.listedSessions.count)
            : L.recentCount(model.listedSessions.count)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.indexing {
                ProgressView()
                Text(L.buildingIndex).foregroundStyle(.secondary)
            } else if model.hasQuery {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(L.noSessionsMatching(model.query))
                    .foregroundStyle(.secondary)
                if !model.filter.includeToolNoise {
                    Text(L.toolNoiseHint)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Image(systemName: "clock")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(L.noSessionsIndexed).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    @ViewBuilder
    private func menu(for group: SessionHitGroup) -> some View {
        // 两种口径分开给，不靠工具栏那个开关 —— 右键菜单点下去该是可预期的
        Button(L.exportConversation) { model.exportSession(group, includeTools: false) }
        Button(L.exportFull) { model.exportSession(group, includeTools: true) }
        Divider()
        Button(L.copyResume) { model.copyResumeCommand(group) }
        Button(L.revealInFinder) { model.revealProject(group) }
    }
}

// MARK: -

@MainActor
struct SessionRow: View {
    let group: SessionHitGroup
    let showPreviews: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if group.isSidechain {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                        .help(L.subagentSessionHelp(group.agentType))
                }
                Text(group.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
            }

            HStack(spacing: 5) {
                Text(group.projectName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("·").foregroundStyle(.quaternary)
                Text(When.short(group.endedAt))
                    .foregroundStyle(.secondary)
                if showPreviews {
                    Text("·").foregroundStyle(.quaternary)
                    Text(L.hitCount(group.hitCount))
                        .foregroundStyle(.blue)
                        .monospacedDigit()
                    if group.subagentHits > 0 {
                        // 这些命中在子 agent 的记录里，主会话正文里搜不到，
                        // 不标出来会让人以为高亮丢了
                        Label("\(group.subagentHits)", systemImage: "arrow.triangle.branch")
                            .foregroundStyle(.purple)
                            .monospacedDigit()
                            .help(L.subagentHitsHelp(group.subagentHits))
                    }
                } else if group.hitCount > 0 {
                    Text("·").foregroundStyle(.quaternary)
                    Text(L.messageCount(group.hitCount))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .font(.caption)

            if showPreviews {
                ForEach(group.previews) { hit in
                    HStack(alignment: .top, spacing: 4) {
                        Text(hit.role == "user" ? L.roleMeShort : L.roleAIShort)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(hit.role == "user" ? .blue : .green)
                            .frame(width: 14, alignment: .leading)
                            .padding(.top, 1)
                        Text(Highlight.attributed(Highlight.flatten(hit.snippet), font: .caption))
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 3)
    }
}
