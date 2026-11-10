import SwiftUI

/// 正文里的子 agent 派发卡片。
///
/// 为什么要有它：派发一个子 agent 在记录里是一条 `tool_use`，而工具记录默认
/// 不显示。于是正文从头读到尾，完全看不出这里派出去过 agent —— 只能看到
/// Claude 自言自语一句「子 agent 还在跑」，读的人无从知道它去干了什么、
/// 回来说了什么。会话头部那行折叠的「N 个子 agent」是唯一的入口，
/// 它既不说明派发发生在对话的哪一步，也点不出此刻谁还活着。
///
/// 所以卡片**不受工具开关影响**，始终排在派发点上，并且能就地展开 ——
/// 读完子 agent 再往下读父会话，不必离开当前这篇。
@MainActor
struct SubagentCard: View {
    @Bindable var model: AppModel
    let sub: SessionHitGroup

    private var expanded: Bool { model.expandedSubagents.contains(sub.sessionId) }
    private var running: Bool { model.runningSubagentIds.contains(sub.sessionId) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().padding(.leading, 12)
                nested
            }
        }
        .background(.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.purple.opacity(running ? 0.45 : 0.22), lineWidth: 1)
        )
    }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 7) {
            // 展开/收起占满剩余宽度，整行都可点 —— 只有箭头能点的话
            // 命中区域只有十来个点宽
            Button {
                model.toggleSubagent(sub.sessionId)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 9)
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.purple)
                    Text(L.subagentDispatched)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(sub.displayTitle)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let type = sub.agentType, !type.isEmpty {
                        Text(type)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if running {
                        RunningDot()
                        Text(L.agentRunning)
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 6)
                    Text(L.plainCount(sub.hitCount))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? L.collapseSubagent : L.expandSubagent)

            // 单独打开：子 agent 自己也可能有几百条，想专心读它时不该挤在缩进里
            Button {
                model.selectedSessionId = sub.sessionId
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L.openSubagent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: 展开后的子 agent 正文

    private var nested: some View {
        HStack(alignment: .top, spacing: 0) {
            // 一条竖线把层级说清楚，比缩进更耐看 —— 子 agent 的消息
            // 和父会话的消息长得一样，没有这条线就分不出谁是谁
            Rectangle()
                .fill(.purple.opacity(0.35))
                .frame(width: 2)
                .padding(.vertical, 2)

            Group {
                if let msgs = model.subagentTranscripts[sub.sessionId] {
                    if msgs.isEmpty {
                        Text(L.subagentNoText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(msgs) { msg in
                                MessageBubble(
                                    message: msg,
                                    terms: model.detailTerms,
                                    isHit: false,
                                    expanded: model.expanded.contains(msg.id),
                                    onToggle: { model.toggleExpanded(msg.id) },
                                    onCopy: { model.copyText($0) }
                                )
                            }
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.top, 8)
    }
}

/// 「还在跑」的绿点。
///
/// 刻意不做闪烁动画：卡片在 `LazyVStack` 里，一个长动画会让这一行
/// 每帧都请求重排，滚动大会话时能明显感觉到。静态圆点够用。
@MainActor
struct RunningDot: View {
    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .help(L.agentRunningHelp)
    }
}
