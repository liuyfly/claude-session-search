import SwiftUI

/// GUI 入口。刻意不加 @main —— 入口在 main.swift 里按命令行参数分派。
@MainActor
struct AppEntry: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 900, minHeight: 560)
                // 在这里而不是 AppearanceSetting.init 里 apply：
                // 对象构造时 NSApp 还没建好，设不上外观。
                .onAppear {
                    AppearanceSetting.shared.apply()
                    // 跨天时让「今天 / 昨天」这类相对时间自动重画
                    DayTicker.shared.start()
                }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Divider()
                // ⌘F 给「在本会话中查找」，全局搜索挪到 ⌥⌘F。
                //
                // 换过来的理由：macOS 上 ⌘F 一律是「在我正在看的东西里找」
                // （Safari 找当前网页、预览找当前 PDF），而这里原来绑的是
                // 跨全部会话的搜索框 —— 正在读一个长会话时按 ⌘F，
                // 期待的是在这个会话里找，不是把左栏列表换掉。
                // 全局搜索框本来就常驻在工具栏上，点得到，不靠快捷键。
                Button(L.findInSessionMenu) { model.openFind() }
                    .keyboardShortcut("f", modifiers: .command)
                Button(L.searchAllSessions) { SearchFieldFocus.focus() }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button(L.nextHit) { model.jumpRequest += 1 }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(model.hitIdsInDetail.isEmpty)
                Button(L.prevHit) { model.jumpRequest -= 1 }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.hitIdsInDetail.isEmpty)
                Divider()
                Button(L.scrollToTop) { model.scrollToTopRequest += 1 }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button(L.scrollToBottom) { model.scrollToBottomRequest += 1 }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button(L.rebuildIndex) { model.reindex(rebuild: true) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.indexing)
            }
        }
    }
}

/// 这个 app 没有文档模型，关掉最后一个窗口就该退出。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// SwiftUI 的 `.searchable` 不暴露 FocusState，只能从视图层级里找到
/// 工具栏那个 NSSearchField 再交给它第一响应者。
enum SearchFieldFocus {
    @MainActor
    static func focus() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
              let field = findSearchField(in: window.contentView) else { return }
        window.makeFirstResponder(field)
    }

    @MainActor
    private static func findSearchField(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for sub in view.subviews {
            if let found = findSearchField(in: sub) { return found }
        }
        return nil
    }
}
