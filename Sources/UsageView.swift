import SwiftUI

/// 工具栏上的额度面板。
///
/// 数据不是从本地文件读的 —— 本地没有。是让 `claude -p "/usage"` 去问服务端，
/// 详见 `UsageProbe`。斜杠命令不走模型推理，所以查它不耗额度。
@MainActor
struct UsageButton: View {
    @Bindable var model: AppModel
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
            model.loadUsage()
        } label: {
            Label(L.usage, systemImage: icon).labelStyle(.iconOnly)
        }
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UsagePanel(model: model).frame(width: 380)
        }
    }

    /// 用满格程度反映当周用量，扫一眼就知道紧不紧张
    private var icon: String {
        guard let pct = model.usage?.weekPercent else { return "gauge.medium" }
        switch pct {
        case ..<34:  return "gauge.low"
        case ..<67:  return "gauge.medium"
        default:     return "gauge.high"
        }
    }
}

@MainActor
struct UsagePanel: View {
    @Bindable var model: AppModel
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L.usage).font(.headline)
                    // 降级时把完整输出默认展开 —— 那是此刻唯一有内容的部分
                    .onChange(of: model.usage?.parsedAnything) { _, ok in
                        if ok == false { showRaw = true }
                    }
                Spacer()
                if model.usageLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        model.loadUsage(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L.usageRefresh)
                }
            }

            if let err = model.usageError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L.usageFailed, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.medium))
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(L.usageHint)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if let u = model.usage {
                if u.parsedAnything {
                    if let pct = u.sessionPercent {
                        bar(L.usageSession, pct: pct, resets: u.sessionResets)
                    }
                    if let pct = u.weekPercent {
                        bar(L.usageWeek, pct: pct, resets: u.weekResets)
                    }
                    ForEach(u.extraLimits, id: \.label) { extra in
                        bar(extra.label, pct: extra.percent, resets: nil)
                    }
                } else {
                    // 服务端那半段没回来。分析段是本地算的、照样有用，
                    // 所以只提示百分比缺失，把下面的完整输出直接展开。
                    VStack(alignment: .leading, spacing: 4) {
                        Label(L.usageNoPercent, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .font(.callout.weight(.medium))
                        Text(L.usageNoPercentHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                DisclosureGroup(isExpanded: $showRaw) {
                    // 原文照登。解析只挑了几个数字出来，`/usage` 还会给
                    // 「多少用量发生在 >150k 上下文」这类分析，那些同样有用。
                    ScrollView {
                        Text(u.raw.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                    .padding(.top, 4)
                } label: {
                    Text(L.usageDetails).font(.caption)
                }

                Text(L.usageFetchedAt(When.full(iso: u.fetchedAt)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if !model.usageLoading {
                Text(L.usageIdle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func bar(_ label: String, pct: Int, resets: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.callout)
                Spacer()
                Text("\(pct)%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint(pct))
            }
            ProgressView(value: Double(pct), total: 100)
                .tint(tint(pct))
            if let resets {
                Text(L.usageResetLine(resets))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tint(_ pct: Int) -> Color {
        switch pct {
        case ..<67: return .green
        case ..<90: return .orange
        default:    return .red
        }
    }
}
