import SwiftUI

/// 把带 \u{1}…\u{2} 标记的片段渲染成高亮 AttributedString。
enum Highlight {

    static func attributed(_ marked: String, font: Font = .callout) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(marked)

        while let open = rest.firstIndex(of: Character(hlOpen)) {
            var plain = AttributedString(rest[rest.startIndex..<open])
            plain.font = font
            out += plain

            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: Character(hlClose)) else {
                var tail = AttributedString(rest[afterOpen...])
                tail.font = font
                out += tail
                return out
            }

            var hit = AttributedString(rest[afterOpen..<close])
            hit.font = font.weight(.semibold)
            hit.backgroundColor = .yellow.opacity(0.45)
            hit.foregroundColor = .primary
            out += hit

            rest = rest[rest.index(after: close)...]
        }

        var tail = AttributedString(rest)
        tail.font = font
        out += tail
        return out
    }

    /// 正文视图里给整段文字标出查询词（没有预先标记，现算）
    static func attributedText(_ text: String, terms: [String], font: Font = .body) -> AttributedString {
        guard !terms.isEmpty else {
            var s = AttributedString(text)
            s.font = font
            return s
        }
        var marked = text
        for term in terms.sorted(by: { $0.count > $1.count }) where !term.isEmpty {
            marked = mark(marked, term: term)
        }
        return attributed(marked, font: font)
    }

    private static func mark(_ s: String, term: String) -> String {
        var result = ""
        var rest = Substring(s)
        while let r = rest.range(of: term, options: .caseInsensitive) {
            result += rest[rest.startIndex..<r.lowerBound] + hlOpen + rest[r] + hlClose
            rest = rest[r.upperBound...]
        }
        return result + rest
    }

    /// 在**已经解析好**的 AttributedString 上标出查询词。
    ///
    /// Markdown 渲染必须走这条路：`attributedText` 那套是先往原文里插
    /// \u{1}/\u{2} 标记再整体构造，而 Markdown 解析会删掉 `**` 这类标记、
    /// 位置全变了，标记法在那之后对不上。所以改成解析完再按范围加底色。
    ///
    /// 只加底色和前景色，**不动字体** —— 字体已经被 Markdown 定过
    /// （粗体、行内代码），再覆盖一遍会把这些信息抹平。
    @MainActor
    static func highlight(_ s: inout AttributedString, terms: [String]) {
        for term in terms where !term.isEmpty {
            var from = s.startIndex
            while from < s.endIndex,
                  let r = s[from...].range(of: term, options: .caseInsensitive) {
                s[r].backgroundColor = .yellow.opacity(0.45)
                s[r].foregroundColor = .primary
                // 空匹配会让游标停在原地死循环；term 非空时 upperBound 必然前进
                from = r.upperBound
            }
        }
    }

    /// 正文视图里那条消息应该渲染多少字，以及被截掉了多少。
    ///
    /// 阈值定在 8000 而不是更低，是因为拖慢界面的是**离群值**而非普通长回复：
    /// 库里最长的一条正文有 62 万字，某个 664 KB 的会话里 627 KB 只来自 2 条消息。
    /// 全库实测 —— 8000 字只截掉 0.8% 的消息（正常阅读几乎无感），
    /// 却把那个会话的排版量从 664 KB 压到 49 KB。
    /// 再往下调（2000 字要截 4%）换来的收益远不如损失的阅读体验。
    static let inlineLimit = 8000

    static func clip(_ text: String, expanded: Bool) -> (shown: String, hidden: Int) {
        guard !expanded, text.count > inlineLimit else { return (text, 0) }
        return (String(text.prefix(inlineLimit)), text.count - inlineLimit)
    }

    /// 片段里的换行会把行高撑乱，压成单行
    static func flatten(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }
}

/// 正文 AttributedString 的缓存。
///
/// 构造它不便宜（一个 703 KB 的会话带查询词时 144 ms），而 SwiftUI 会因为
/// 任何无关状态变化重建 MessageBubble —— 展开一条 thinking、切换语言、
/// 窗口改大小都会让整屏正文重新构造一遍。按消息 id 缓存就都省了。
@MainActor
enum TextCache {
    private struct Key: Hashable {
        let id: Int64
        let terms: [String]
        let clipped: Bool
        let mono: Bool
    }

    private static var store: [Key: AttributedString] = [:]

    /// 超过就整体清空。做 LRU 不值得 —— 正文视图一次只看一个会话，
    /// 命中集合天然局部；条数够容纳最大的会话（1562 条）再留些余量。
    private static let capacity = 4000

    static func attributed(id: Int64, text: String, terms: [String],
                           clipped: Bool, mono: Bool) -> AttributedString {
        let key = Key(id: id, terms: terms, clipped: clipped, mono: mono)
        if let hit = store[key] { return hit }
        let made = Highlight.attributedText(text, terms: terms,
                                            font: mono ? .system(.caption, design: .monospaced) : .body)
        // 用户点开「显示完整内容」拿到的可能是几十万字，缓存住会把内存吃光。
        // 只存有界的截断版本 —— 展开的那一两条重绘时重算，代价可控。
        guard text.count <= Highlight.inlineLimit else { return made }
        if store.count >= capacity { store.removeAll(keepingCapacity: true) }
        store[key] = made
        return made
    }

    /// 重建索引后消息 id 会指向不同的正文，缓存必须作废
    static func invalidate() { store.removeAll(keepingCapacity: true) }
}

/// 时间显示：今天只给时刻，今年省略年份，更早给完整日期。
enum When {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac = ISO8601DateFormatter()

    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// ISO8601 解析本身不便宜（283 条正文重复解析约 10 ms，每次重绘都要付）。
    /// 缓存解析结果而不是格式化结果 —— 后者含「今天/昨天」这种相对表述，
    /// app 跨天开着就会显示错的日期。
    @MainActor private static var parsed: [String: Date] = [:]

    @MainActor
    private static func cachedDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let hit = parsed[s] { return hit }
        guard let d = date(s) else { return nil }
        if parsed.count >= 8000 { parsed.removeAll(keepingCapacity: true) }
        parsed[s] = d
        return d
    }

    /// DateFormatter 的构造出奇地贵，而正文里每条消息都要格式化一次时间戳。
    /// 实测 280 条消息重建 formatter 要 28 ms，且每次视图重绘都白花一遍。
    /// 按 (locale, 格式串) 缓存复用 —— 语言切换后 key 变了，自然拿到新的。
    @MainActor private static var cache: [String: DateFormatter] = [:]

    @MainActor
    private static func formatter(locale: Locale, format: String) -> DateFormatter {
        let key = "\(locale.identifier)|\(format)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = locale
        f.dateFormat = format
        cache[key] = f
        return f
    }

    /// 时间落在哪一档。抽出来是为了两个格式化入口共用，
    /// 也为了自检能在非主线程直接断言分档逻辑。
    nonisolated static func style(for d: Date, now: Date = Date()) -> L.DateStyle {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return .today }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(d, inSameDayAs: yesterday) { return .yesterday }
        if cal.component(.year, from: d) == cal.component(.year, from: now) { return .thisYear }
        return .older
    }

    /// 「今天 / 昨天」这类相对表述必须拿 `DayTicker.shared.today` 当 now，
    /// 不能直接用 `Date()`。
    ///
    /// 不是为了拿到更准的时间 —— 两者在同一天内是等价的 —— 而是为了
    /// **建立依赖**：这个读操作发生在视图 body 求值期间，SwiftUI 的观察机制
    /// 会把它登记下来，于是跨天时那个值一变，所有显示相对时间的行自动重画。
    /// 用 `Date()` 的话没有任何可观察状态变化，body 永远不会重算，
    /// 昨天渲染的「今天 16:57」就会一直挂着（实测挂了三天）。
    @MainActor
    static func short(_ s: String?) -> String {
        guard let d = cachedDate(s) else { return "—" }
        return formatter(locale: L.dateLocale,
                         format: L.shortDateFormat(style(for: d, now: DayTicker.shared.today)))
            .string(from: d)
    }

    /// 正文里每条消息的时间戳。跟 `short` 的区别是**永远带时分**。
    ///
    /// 解析不出来时返回 nil，而不是 `short` 那个占位的「—」：
    /// 时间未知就干脆不占地方，比摆个破折号让人猜是什么意思要好。
    /// （实测索引库里 ts 覆盖率 100%，这条分支是给格式变化留的后路。）
    @MainActor
    static func messageStamp(_ s: String?) -> String? {
        guard let d = cachedDate(s) else { return nil }
        // now 走 DayTicker，理由同 `short`
        return formatter(locale: L.dateLocale,
                         format: L.messageDateFormat(style(for: d, now: DayTicker.shared.today)))
            .string(from: d)
    }

    /// 已经是 Date 的场合（比如刚取回来的时间戳），不用绕一趟 ISO 字符串
    @MainActor
    static func full(iso d: Date) -> String {
        formatter(locale: Locale(identifier: "en_US_POSIX"),
                  format: "yyyy-MM-dd HH:mm:ss").string(from: d)
    }

    /// ISO 风格的完整时间，两种语言下都一样 —— 它是给人对照 jsonl 记录用的
    @MainActor
    static func full(_ s: String?) -> String {
        guard let d = cachedDate(s) else { return "—" }
        return formatter(locale: Locale(identifier: "en_US_POSIX"),
                         format: "yyyy-MM-dd HH:mm").string(from: d)
    }
}
