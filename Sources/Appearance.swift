import AppKit
import Observation

/// 界面主题。
enum AppTheme: String, CaseIterable, Sendable {
    case auto
    case light
    case dark

    @MainActor
    var label: String {
        switch self {
        case .auto:  return L.themeAuto
        case .light: return L.themeLight
        case .dark:  return L.themeDark
        }
    }

    var icon: String {
        switch self {
        case .auto:  return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark:  return "moon"
        }
    }

    /// 映射到 AppKit 的外观。nil = 跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

/// 主题设置。
///
/// 用 `NSApp.appearance` 而不是 SwiftUI 的 `.preferredColorScheme`：后者只作用于
/// 视图层级内部，管不到窗口标题栏、工具栏和菜单 —— 深色正文配浅色工具栏很难看。
/// 设成 nil 则交还给系统，用户改系统外观时会自动跟上。
@Observable
@MainActor
final class AppearanceSetting {
    static let shared = AppearanceSetting()
    private static let key = "appTheme"

    var selection: AppTheme {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.rawValue, forKey: Self.key)
            apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppTheme.auto.rawValue
        selection = AppTheme(rawValue: raw) ?? .auto
    }

    /// 启动时调用一次。init 里不能调 —— 那时 NSApp 还没建好。
    func apply() {
        NSApp?.appearance = selection.nsAppearance
    }
}

/// 「当前会话有新输出时，要不要把视口带到最新一条」。
///
/// 默认开：看一个还在跑的会话，多数时候想要的就是追上最新进展。
/// 但反过来 —— 正往回翻这个会话的历史时，每来一条新输出就被拽到底部，
/// 根本没法读。所以给个开关。
///
/// **关掉之后正文照样刷新**，只是视口不动：新内容就在下面等着，
/// 手动滚下去或按 ⌘↓ 就能看到。这个开关管的只有「跳不跳」这一件事。
@Observable
@MainActor
final class FollowSetting {
    static let shared = FollowSetting()
    private static let key = "followNewOutput"

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.key)
        }
    }

    /// 从 UserDefaults 存的原始值定出开关状态。
    ///
    /// 独立成纯函数是因为这里有个真实的坑：**不能用 `UserDefaults.bool(forKey:)`** ——
    /// 键不存在时它返回 `false`，于是「从没设置过」和「明确关掉」无法区分，
    /// 默认值会悄悄变成关。必须用 `object(forKey:)` 先判断存没存过。
    nonisolated static func resolve(stored: Any?) -> Bool {
        (stored as? Bool) ?? true      // 没存过 → 默认开，保持原有行为
    }

    private init() {
        enabled = Self.resolve(stored: UserDefaults.standard.object(forKey: Self.key))
    }
}

/// 「Claude 的回复要不要按 Markdown 渲染」。
///
/// 默认开：含块级语法的回复占了正文字数的 86%，不渲染的话满屏都是
/// `##`、`- `、```` ``` ```` 这些标记。
///
/// 留开关是因为渲染有个**明确的代价**：一条消息从一个 `Text` 变成若干块视图，
/// 于是**跨块的文本选择做不到了**（能选中一个段落，但选不了「段落 + 下面那段代码」）。
/// 配套给了每条消息和每个代码块的复制按钮，但它不完全等价。
/// 关掉就回到原来那个可以整条选中的纯文本。
@Observable
@MainActor
final class MarkdownSetting {
    static let shared = MarkdownSetting()
    private static let key = "renderMarkdown"

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.key)
        }
    }

    /// 同 `FollowSetting.resolve` 的理由：`UserDefaults.bool(forKey:)` 分不出
    /// 「没存过」和「明确关掉」，默认值会悄悄变成关。
    nonisolated static func resolve(stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    private init() {
        enabled = Self.resolve(stored: UserDefaults.standard.object(forKey: Self.key))
    }
}

/// 跨天信号。
///
/// 「今天 / 昨天」这类相对时间有个 SwiftUI 特有的坑：`Text(When.short(...))`
/// 只在 body 重新求值时才计算，而**跨天时没有任何可观察状态发生变化** ——
/// 于是 app 开着过夜，昨天渲染出的「今天 16:57」就一直挂在那儿。
/// 实测用户的 app 连开三天，08-28 的会话还显示「Today 16:57」。
///
/// 注意这**不是**格式化的错：`When.style(for:now:)` 拿真实的 now 去算，
/// 3 天前的日期照样落在 `.thisYear` 档。错的是没人告诉视图该重画了。
///
/// 做法是把「今天是哪天」变成一个可观察的值。`When.short` / `messageStamp`
/// 读它来拿 now，于是**任何在 body 里显示相对时间的视图都自动建立了依赖** ——
/// 跨天时这个值一变，它们全都重画。不需要各个视图自己去订阅。
@Observable
@MainActor
final class DayTicker {
    static let shared = DayTicker()

    /// 当前这一天的参考时刻。只在跨天时更新 —— 相对时间只关心落在哪一天，
    /// 每秒都变反而会让整个列表疯狂重画。
    private(set) var today = Date()

    private init() {}

    /// 两个时刻是否属于同一天。纯函数，自检直接断言。
    nonisolated static func sameDay(_ a: Date, _ b: Date) -> Bool {
        Calendar.current.isDate(a, inSameDayAs: b)
    }

    /// 检查是否跨天了，跨了就更新并返回 true。
    ///
    /// 幂等：同一天内反复调用不会触发重画。所以下面那几个触发源可以随便叠，
    /// 多叫几次是无害的。
    @discardableResult
    func refresh(now: Date = Date()) -> Bool {
        guard !Self.sameDay(today, now) else { return false }
        today = now
        return true
    }

    /// 启动时调一次。三个触发源都接上 —— 单靠任何一个都有漏的可能：
    ///
    /// - `NSCalendarDayChanged`：正常跨天的主力信号
    /// - 睡眠唤醒：合盖过夜时上面那个通知不一定送达
    /// - 窗口重新激活：兜底。用户切回来看的那一刻，显示必须是对的
    func start() {
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { _ = DayTicker.shared.refresh() } }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { _ = DayTicker.shared.refresh() } }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { _ = DayTicker.shared.refresh() } }
    }
}
