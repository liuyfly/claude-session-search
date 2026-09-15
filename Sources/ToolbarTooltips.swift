import AppKit
import SwiftUI

/// 给工具栏按钮装上悬停提示。
///
/// 为什么不用 SwiftUI 的 `.help()`：在 macOS 26 + SwiftUI 工具栏下它根本不生效。
/// 实测把 `.help()` 加在 Button、Label、内层 Image 上都试过，
/// `NSToolbarItem.toolTip` 与 hosting view 的 `toolTip` 全是 nil，
/// 鼠标真移上去也确实不出提示（移动光标 + 截图验证过）。
///
/// 所以绕到 AppKit：等工具栏建好后按 `item.label` 找到对应 item，直接设 `toolTip`。
/// 用 label 而不是图标名 —— SwiftUI 把 SF Symbol 直接绘进私有的 ContainerView，
/// 视图树里没有 NSImageView，拿不到 symbol 名（探针确认过）。
/// 代价是每个按钮都得用 `Label(文字, systemImage:)` 而非裸 `Image`，
/// 这样 item.label 才有值 —— 顺带也让无障碍朗读和溢出菜单有了名字。
@MainActor
enum ToolbarTooltips {

    /// item.label → 提示文字。
    ///
    /// 每次调用现取，所以切换语言后拿到的是新文案；也不需要外部先注册
    /// provider（那样有初始化顺序的坑：install 可能跑在赋值之前）。
    /// key 必须与按钮 `Label(...)` 的第一个参数逐字一致。
    /// - Parameter toolsShown: 「工具记录」开关的当前状态，它的提示随状态变
    private static func map(toolsShown: Bool) -> [String: String] {
        [
            L.language: "\(L.language) · \(L.theme)",
            L.usage: L.usageHelp,
            L.filter: L.filterHelp,
            L.prevHit: L.prevHitHelp,
            L.nextHit: L.nextHitHelp,
            L.scrollToTop: L.scrollToTopHelp,
            L.scrollToBottom: L.scrollToBottomHelp,
            L.toolRecords: toolsShown ? L.toolsShownHelp : L.toolsHiddenHelp,
            L.copyResume: L.copyResumeHelp,
        ]
    }

    static func install(toolsShown: Bool) {
        let map = Self.map(toolsShown: toolsShown)
        for window in NSApp.windows {
            guard let toolbar = window.toolbar else { continue }
            for item in toolbar.items {
                guard let tip = map[item.label] else { continue }
                item.toolTip = tip
                item.view?.toolTip = tip
            }
        }
    }
}

/// 让视图在出现/变化后补装工具栏提示。
struct ToolbarTooltipInstaller: ViewModifier {
    /// 变化时重装（语言切换、按钮显隐都会改变 item 集合）
    let trigger: AnyHashable
    /// 「工具记录」开关状态，它的提示文字随之变化
    let toolsShown: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { schedule() }
            .onChange(of: trigger) { _, _ in schedule() }
    }

    /// 工具栏 item 在视图更新之后才建好，同一帧里找不到，
    /// 延后几拍并多试几次。
    private func schedule() {
        for delay in [0.0, 0.2, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                ToolbarTooltips.install(toolsShown: toolsShown)
            }
        }
    }
}

extension View {
    func installToolbarTooltips(trigger: AnyHashable, toolsShown: Bool) -> some View {
        modifier(ToolbarTooltipInstaller(trigger: trigger, toolsShown: toolsShown))
    }
}
