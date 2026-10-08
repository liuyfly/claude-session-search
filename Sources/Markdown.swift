import SwiftUI

/// Claude 回复的 Markdown 渲染。
///
/// ## 为什么要自己切块
///
/// Foundation 自带 `AttributedString(markdown:)`，两个模式实测都不能直接用：
///
/// - `.full`：块结构解析**是对的**（`PresentationIntent` 里能拿到 header /
///   unorderedList / codeBlock / table），但它**把换行全删了** —— 106 字符的样本
///   只剩 57、换行从 13 个变成 1 个。而 SwiftUI 的 `Text` 根本不渲染
///   `PresentationIntent`，于是整条会被揉成一行，比不渲染更糟。
/// - `.inlineOnlyPreservingWhitespace`：换行保住了，粗体 / 行内代码 / 链接都对，
///   但**把代码围栏揉成一行**（```` ```swift\nlet x = 1\n``` ```` → `swift let x = 1`），
///   还留着 `##`、`- ` 这些原样的标记。库里 12% 的回复含围栏，这条路会毁掉它们。
///
/// 所以这里自己做块级切分，**行内仍然交给 Foundation**（它那部分是对的，
/// 而且对技术文本足够安全，见下）。
///
/// ## 值不值得
///
/// 含块级语法的回复只占 25% 的条数，却占 **86% 的字数**（平均 1614 字，
/// 其余平均 87 字）。只做行内渲染等于恰好放弃了最该渲染的那部分。
///
/// ## 对技术文本安全吗
///
/// 实测（全部按原样保留）：`foo_bar_baz`、`*.swift`、`2 * 3 * 4`、`^\d+_\w+$`、
/// `Array<String>`、`echo $PATH`、`C:\Users\name`。
/// 唯一会被吃掉的是 `__init__` 这类**双下划线**（当成粗体）——
/// 全库 22207 条回复里含双下划线的 143 条（0.6%），真 `__init__` 只有 9 条。
enum Markdown {

    // MARK: - 块

    struct Block: Identifiable, Equatable {
        let id: Int          // 在这条消息里的序号，给 ForEach 用
        let kind: Kind
    }

    enum Kind: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case code(lang: String?, text: String)
        case listItem(marker: String, text: String, depth: Int)
        case quote(String)
        case rule
        case table(header: [String], rows: [[String]], align: [Align])
    }

    /// 列对齐，来自分隔行里的冒号：`:---` 左、`:---:` 居中、`---:` 右。
    enum Align: Equatable { case left, center, right }

    nonisolated static func blocks(_ src: String) -> [Block] {
        var kinds: [Kind] = []
        let lines = src.components(separatedBy: "\n")
        var i = 0
        var para: [String] = []

        func flushPara() {
            guard !para.isEmpty else { return }
            kinds.append(.paragraph(para.joined(separator: "\n")))
            para = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码围栏。**必须最先判**：围栏里的 `#`、`- `、`>` 都是代码不是语法。
            if isFence(trimmed) {
                flushPara()
                let lang = String(trimmed.drop(while: { $0 == "`" || $0 == "~" }))
                    .trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !isFence(lines[i].trimmingCharacters(in: .whitespaces)) {
                    body.append(lines[i]); i += 1
                }
                // 收尾围栏可能不存在 —— 正文被 8000 字上限截断时就是这样。
                // 吃到结尾，不能因为没闭合就把剩下的内容丢了。
                if i < lines.count { i += 1 }
                kinds.append(.code(lang: lang.isEmpty ? nil : lang,
                                   text: body.joined(separator: "\n")))
                continue
            }

            if trimmed.isEmpty { flushPara(); i += 1; continue }

            if let level = headingLevel(trimmed) {
                flushPara()
                let text = String(trimmed.dropFirst(level + 1))
                kinds.append(.heading(level: level, text: text))
                i += 1; continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara(); kinds.append(.rule); i += 1; continue
            }

            // 表格：当前行像表格行，**且下一行是分隔行**。
            // 少了后半个条件，一段以 `|` 开头的普通文字就会被误判成表格。
            if trimmed.hasPrefix("|"), i + 1 < lines.count,
               isDelimiterRow(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushPara()
                let header = cells(line)
                let align = alignments(lines[i + 1])
                i += 2
                var rows: [[String]] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[i])); i += 1
                }
                kinds.append(.table(header: header, rows: rows, align: align))
                continue
            }

            // 连续的引用行并成一块，否则视觉上会变成一叠独立的小块
            if trimmed == ">" || trimmed.hasPrefix("> ") {
                flushPara()
                var body: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t == ">" || t.hasPrefix("> ") else { break }
                    body.append(String(t.dropFirst(t == ">" ? 1 : 2)))
                    i += 1
                }
                kinds.append(.quote(body.joined(separator: "\n")))
                continue
            }

            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
            if let item = listMarker(trimmed) {
                flushPara()
                kinds.append(.listItem(marker: item.marker, text: item.text,
                                       depth: min(indent / 2, 3)))
                i += 1; continue
            }

            // 列表项的续行：缩进了、又不是新块的开头，接到上一项后面。
            // 不接的话它会变成一个独立段落，视觉上从列表里掉出来。
            if indent >= 2, case .listItem(let m, let t, let d) = kinds.last {
                kinds[kinds.count - 1] = Kind.listItem(marker: m, text: t + " " + trimmed,
                                                       depth: d)
                i += 1; continue
            }

            para.append(line)
            i += 1
        }
        flushPara()

        return kinds.enumerated().map { Block(id: $0.offset, kind: $0.element) }
    }

    /// `|---|:---:|` 这种分隔行。要求：以 `|` 开头、只由 `|-: ` 组成、至少有一个 `-`。
    ///
    /// 「至少一个 `-`」这条不能省：`| | |` 也满足前两条，但那是一行空单元格。
    /// 把**连续的纯文字块**（段落 + 标题）并成一组，其余块各自成组。
    ///
    /// 为什么要并：这些块之间除了换行没有任何结构，拆成多个 `Text` 就把
    /// **跨块的文本选择**弄没了 —— 而 SwiftUI 的 `Text` 只在字形范围内响应选择，
    /// 一个块的**第一个字**因此是个几个点宽的靶子，从段首起手经常落空
    /// （用户实测两次反馈）。并成一组之后，除了整条的第一个字，其余段首都在
    /// 一个 `Text` 内部，随便点。
    ///
    /// 标题也并进来是第二版才加的：第一版只并段落，可真实的回复长这样 ——
    /// 标题/段落/代码/段落/标题/段落 —— **几乎没有连续段落**，合并等于没做。
    ///
    /// 代码块、表格、列表项必须各自成视图（要布局），它们仍然切断选择，躲不掉。
    nonisolated static func groupTextBlocks(_ blocks: [Block]) -> [[Block]] {
        func mergeable(_ k: Kind?) -> Bool {
            switch k {
            case .paragraph, .heading: return true
            default: return false
            }
        }
        var out: [[Block]] = []
        for b in blocks {
            if mergeable(b.kind), mergeable(out.last?.last?.kind) {
                out[out.count - 1].append(b)
            } else {
                out.append([b])
            }
        }
        return out
    }

    /// 合并渲染时两个块之间放什么。段落之间空一行，标题两侧只换行。
    nonisolated static func separator(before prev: Kind, and cur: Kind) -> String {
        if case .heading = prev { return "\n" }
        if case .heading = cur { return "\n\n" }
        return "\n\n"
    }

    @MainActor
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title3.weight(.bold)
        case 2:  return .headline
        case 3:  return .subheadline.weight(.semibold)
        default: return .body.weight(.semibold)
        }
    }

    nonisolated static func isDelimiterRow(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// 从分隔行读出每列的对齐
    nonisolated static func alignments(_ line: String) -> [Align] {
        cells(line).map { cell in
            let l = cell.hasPrefix(":"), r = cell.hasSuffix(":")
            if l && r { return .center }
            if r { return .right }
            return .left
        }
    }

    /// 拆单元格。
    ///
    /// 只把 `\|` 当转义，**其他反斜杠一律原样留着** —— 按通用转义处理的话，
    /// 单元格里的 `C:\Users\name` 会被吃成 `C:Usersname`。
    nonisolated static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }

        var out: [String] = []
        var cur = ""
        var escaped = false
        for ch in t {
            if escaped {
                if ch == "|" { cur.append("|") } else { cur.append("\\"); cur.append(ch) }
                escaped = false
                continue
            }
            if ch == "\\" { escaped = true; continue }
            if ch == "|" { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
            cur.append(ch)
        }
        if escaped { cur.append("\\") }      // 行尾一个孤零零的反斜杠，别吞掉
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    /// 把解析好的表格重建成 Markdown 源码，供「复制表格」用。
    ///
    /// 不存原文而是重建：原文的竖线可能没对齐、可能缺列，重建出来的是规整的。
    /// **单元格里的竖线要重新转义回 `\|`** —— 解析时把它还原成了字面竖线，
    /// 直接写出去会多切出一列，粘到别处就是一张错位的表。
    nonisolated static func tableSource(header: [String], rows: [[String]],
                                        align: [Align]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        func line(_ cells: [String]) -> String {
            let padded = (0..<columns).map { c -> String in
                let raw = c < cells.count ? cells[c] : ""
                return raw.replacingOccurrences(of: "|", with: "\\|")
            }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        let ruler = (0..<columns).map { c -> String in
            switch c < align.count ? align[c] : .left {
            case .left:   return " --- "
            case .center: return " :---: "
            case .right:  return " ---: "
            }
        }.joined(separator: "|")
        return ([line(header), "|" + ruler + "|"] + rows.map(line)).joined(separator: "\n")
    }

    nonisolated static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// `## 标题` → 2。不是标题返回 nil。
    /// 要求 `#` 后面**必须有空格** —— 否则 `#1 问题` 和话题标签都会被当成标题。
    nonisolated static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), trimmed.count > hashes else { return nil }
        let after = trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes)]
        return after == " " ? hashes : nil
    }

    /// 列表项的记号和正文。无序统一成 `•`，有序保留原来的数字。
    nonisolated static func listMarker(_ trimmed: String) -> (marker: String, text: String)? {
        if let first = trimmed.first, "-*+".contains(first) {
            let rest = trimmed.dropFirst()
            guard rest.first == " " else { return nil }
            return ("•", String(rest.dropFirst()))
        }
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = trimmed.dropFirst(digits.count)
        guard let sep = rest.first, sep == "." || sep == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " else { return nil }
        return ("\(digits).", String(after.dropFirst()))
    }

    // MARK: - 行内

    /// 行内解析 + 查询词高亮，一步做完。
    ///
    /// 高亮必须**在解析之后**加：解析会删掉 `**` 这类标记，位置全变了。
    /// 实测两者能共存 —— 同一个 run 可以既是高亮又是粗体。
    @MainActor
    static func inline(_ src: String, terms: [String], base: Font) -> AttributedString {
        var s = parse(src)
        applyFonts(&s, base: base)
        Highlight.highlight(&s, terms: terms)
        return s
    }

    /// 只解析，不上样式。解析失败就原样返回 —— 宁可不渲染，也不能丢内容。
    nonisolated static func parse(_ src: String) -> AttributedString {
        (try? AttributedString(
            markdown: src,
            options: .init(allowsExtendedAttributes: false,
                           interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(src)
    }

    /// 把 `inlinePresentationIntent` 翻成**具体**字体。
    ///
    /// 不直接靠 SwiftUI 解释这个属性：正文里每个 run 都要显式带 `font`
    /// （原来的 `Highlight.attributed` 就是这么做的），混着来会出现
    /// 一部分字号跟随环境、一部分不跟的割裂感。
    @MainActor
    static func applyFonts(_ s: inout AttributedString, base: Font) {
        let code = Font.system(.callout, design: .monospaced)
        // 先收集再改：边遍历 runs 边改属性会让游标失效
        var plan: [(Range<AttributedString.Index>, Font, Bool)] = []
        for run in s.runs {
            var font = base
            var strike = false
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = code }
                if intent.contains(.stronglyEmphasized) { font = font.weight(.semibold) }
                if intent.contains(.emphasized) { font = font.italic() }
                if intent.contains(.strikethrough) { strike = true }
            }
            plan.append((run.range, font, strike))
        }
        for (range, font, strike) in plan {
            s[range].font = font
            if strike { s[range].strikethroughStyle = .single }
        }
    }

    /// 不解析 Markdown，只上字体和高亮。代码块走这条 —— 围栏里的内容是代码，
    /// 里面的 `*` `_` `#` 都是代码本身，解析它就是破坏它。
    @MainActor
    static func plain(_ src: String, terms: [String], base: Font) -> AttributedString {
        var s = AttributedString(src)
        s.font = base
        Highlight.highlight(&s, terms: terms)
        return s
    }

    // MARK: - 纯文本

    /// 把正文转成**纯文本**：去掉 Markdown 标记，保留内容和版式。
    ///
    /// 「复制这条消息」用。原来复制的是原文，粘到邮件、工单、聊天框里就是一片
    /// `**` 和 `|---|` —— 那些字符是写给渲染器看的，不是写给人看的。
    ///
    /// 三件事不能顺手一起抹掉：
    /// - **代码块原样保留**，只脱围栏。围栏里的 `*` `_` `#` 是代码本身。
    /// - **链接补回 URL**：`[文档](https://…)` 渲染出来只剩「文档」，纯文本里
    ///   丢了 URL 就再也找不回来，补成 `文档 (https://…)`。
    /// - **表格重排成空格对齐**，而不是把竖线删了了事 —— 删完粘出去是一摊烂泥。
    ///
    /// `keepCodeLanguage` 把围栏上的语言标注(```swift 的 swift)留在代码块前面。
    /// 默认丢掉 —— 纯文本里单独一行 "swift" 只是噪音。自检要**一字不差**地
    /// 比对「原文」和「复制出来的」，少一个 swift 就对不上，所以留了这个开关。
    nonisolated static func plainText(_ src: String,
                                      keepCodeLanguage: Bool = false) -> String {
        var out = ""
        var prev: Kind?
        for b in blocks(src) {
            let piece: String
            switch b.kind {
            case .paragraph(let t):          piece = stripInline(t)
            case .heading(_, let t):         piece = stripInline(t)
            case .quote(let t):              piece = stripInline(t)
            case .code(let lang, let t):
                piece = keepCodeLanguage && lang != nil ? lang! + "\n" + t : t
            case .listItem(let marker, let t, let depth):
                piece = String(repeating: "  ", count: depth) + marker + " " + stripInline(t)
            case .table(let header, let rows, let align):
                piece = tablePlain(header: header, rows: rows, align: align)
            case .rule:
                // 分割线在纯文本里没有对应物，块之间本来就隔着空行
                continue
            }
            if !out.isEmpty {
                // 列表项之间只换行。一律空行的话，一个六项的清单会被拉成半屏。
                out += isListItem(prev) && isListItem(b.kind) ? "\n" : "\n\n"
            }
            out += piece
            prev = b.kind
        }
        return out
    }

    nonisolated static func isListItem(_ k: Kind?) -> Bool {
        if case .listItem = k { return true }
        return false
    }

    /// 剥掉行内标记：`**粗**` → `粗`、`` `码` `` → `码`、`[文](url)` → `文 (url)`。
    ///
    /// 复用渲染用的那个解析器，保证「复制下来的」和「屏幕上看到的」出自同一次
    /// 解析 —— 两套实现迟早在某个边角上对不上，而那种不一致没人会去查。
    nonisolated static func stripInline(_ src: String) -> String {
        let s = parse(src)
        var out = ""
        // 一个链接可能被切成**多个 run** —— `[**粗**说明](url)` 就是两个，
        // 两个都带着同一个 link。逐 run 补 URL 会把它补两遍，所以先攒起来。
        var linkURL: String?
        var linkText = ""

        func flushLink() {
            guard let url = linkURL else { return }
            out += linkText
            if linkAddsInfo(url: url, text: linkText) { out += " (\(url))" }
            linkURL = nil
            linkText = ""
        }

        for run in s.runs {
            let text = String(s[run.range].characters)
            // `absoluteString` 给的是**规范化**后的 URL：中文路径会变成一串
            // %E5%8F%AF，复制出来人读不了。解回来。
            let url = run.link.map { $0.absoluteString.removingPercentEncoding
                                     ?? $0.absoluteString }
            if let url, !text.isEmpty {
                if linkURL == url { linkText += text }
                else { flushLink(); linkURL = url; linkText = text }
            } else {
                flushLink()
                out += text
            }
        }
        flushLink()
        return out
    }

    /// 这个链接的 URL 除了文字本身，还带了新信息吗？
    ///
    /// 解析器会把**裸邮箱**和**裸网址**也认成链接，并补上协议头：
    /// `liuyfly@126.com` → `mailto:liuyfly@126.com`、`example.com` → `https://example.com/`。
    /// 那不是新信息，补出去就是每个邮箱后面跟一串重复的东西。
    nonisolated static func linkAddsInfo(url: String, text: String) -> Bool {
        func bare(_ s: String) -> String {
            var t = s
            for scheme in ["mailto:", "https://", "http://"] where t.hasPrefix(scheme) {
                t.removeFirst(scheme.count)
                break
            }
            if t.hasSuffix("/") { t.removeLast() }       // 规范化补的尾斜杠
            return t
        }
        return bare(url) != bare(text)
    }

    /// 表格重排成空格对齐的纯文本。
    ///
    /// 列宽按**显示宽度**算而不是字符数 —— 汉字占两格，按 `count` 补空格的话
    /// 每一列都是歪的，而真实会话里的表格大半是中文。
    nonisolated static func tablePlain(header: [String], rows: [[String]],
                                       align: [Align]) -> String {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        guard columns > 0 else { return "" }

        func cell(_ r: [String], _ c: Int) -> String {
            stripInline(c < r.count ? r[c] : "")
        }
        var width = [Int](repeating: 0, count: columns)
        for r in [header] + rows {
            for c in 0..<columns { width[c] = max(width[c], displayWidth(cell(r, c))) }
        }

        func line(_ r: [String]) -> String {
            let cols = (0..<columns).map { c -> String in
                let t = cell(r, c)
                let pad = max(0, width[c] - displayWidth(t))
                switch c < align.count ? align[c] : .left {
                case .right:  return String(repeating: " ", count: pad) + t
                case .center: let l = pad / 2
                              return String(repeating: " ", count: l) + t
                                   + String(repeating: " ", count: pad - l)
                case .left:   return t + String(repeating: " ", count: pad)
                }
            }
            // 行尾补出来的空格没有意义，粘到别处还留一条看不见的毛边
            return trimTrailingSpaces(cols.joined(separator: "  "))
        }

        let ruler = (0..<columns)
            .map { String(repeating: "─", count: max(1, width[$0])) }
            .joined(separator: "  ")
        return ([line(header), ruler] + rows.map(line)).joined(separator: "\n")
    }

    nonisolated static func trimTrailingSpaces(_ s: String) -> String {
        var t = s
        while t.hasSuffix(" ") { t.removeLast() }
        return t
    }

    /// 等宽字体里占几格。够用就行，不追求 `wcwidth` 的全部边角 ——
    /// 这里的用途只是让复制出来的表格看着是齐的。
    ///
    /// 按**字形簇**数而不是 unicode 标量：`👨‍👩‍👦` 是三个标量拼的，按标量算成 6 格。
    nonisolated static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s {
            guard let u = ch.unicodeScalars.first?.value else { continue }
            switch u {
            case 0x1100...0x115F,            // 韩文字母
                 0x2E80...0xA4CF,            // CJK 部首、假名、汉字、注音
                 0xA960...0xA97F,
                 0xAC00...0xD7A3,            // 韩文音节
                 0xF900...0xFAFF,            // CJK 兼容汉字
                 0xFE10...0xFE19,
                 0xFE30...0xFE6F,            // 竖排标点、全角形式
                 0xFF00...0xFF60,            // 全角 ASCII 与标点
                 0xFFE0...0xFFE6,
                 0x1F300...0x1F64F,          // 符号与人物 emoji
                 0x1F900...0x1F9FF,
                 0x20000...0x3FFFD:          // CJK 扩展 B 及以后
                w += 2
            default:
                w += 1
            }
        }
        return w
    }
}

// MARK: - 缓存

/// 块切分与行内渲染的缓存。
///
/// 和 `TextCache` 分开而不是塞进去：那边的键是「一条消息一个串」，
/// 这边是「一条消息 N 个块、每块一个串」，键的形状不一样。
/// 失效时机相同，所以 `invalidate()` 一起调。
@MainActor
enum MarkdownCache {
    private struct BlockKey: Hashable {
        let id: Int64
        let clipped: Bool
    }
    private struct RunKey: Hashable {
        let id: Int64
        let block: Int
        let cell: Int          // 表格单元格；非表格块固定 0
        let terms: [String]
        let style: Int
    }

    /// 合并渲染的连续段落。键里带首块序号和条数 —— 同一条消息里可能有好几组
    /// （被代码块、表格隔开），不能只按消息 id 存。
    private struct MergedKey: Hashable {
        let id: Int64
        let first: Int
        let count: Int
        let terms: [String]
    }

    private static var blockStore: [BlockKey: [Markdown.Block]] = [:]
    private static var runStore: [RunKey: AttributedString] = [:]
    private static var mergedStore: [MergedKey: AttributedString] = [:]

    /// 和 TextCache 同样的口径：超了就整体清空。正文视图一次只看一个会话，
    /// 命中集合天然局部，做 LRU 不值得。
    private static let blockCapacity = 4000
    private static let runCapacity = 12000      // 一条消息平均切出 5 个块

    static func blocks(id: Int64, text: String, clipped: Bool) -> [Markdown.Block] {
        let key = BlockKey(id: id, clipped: clipped)
        if let hit = blockStore[key] { return hit }
        let made = Markdown.blocks(text)
        if blockStore.count >= blockCapacity { blockStore.removeAll(keepingCapacity: true) }
        blockStore[key] = made
        return made
    }

    /// - Parameter style: 同一个块在不同场合可能用不同基准字体（标题分级），
    ///   拿一个小整数当键的一部分，别把 `Font` 塞进键里。
    static func inline(id: Int64, block: Int, cell: Int = 0, text: String, terms: [String],
                       style: Int, base: Font, isCode: Bool = false) -> AttributedString {
        let key = RunKey(id: id, block: block, cell: cell, terms: terms, style: style)
        if let hit = runStore[key] { return hit }
        let made = isCode ? Markdown.plain(text, terms: terms, base: base)
                          : Markdown.inline(text, terms: terms, base: base)
        if runStore.count >= runCapacity { runStore.removeAll(keepingCapacity: true) }
        runStore[key] = made
        return made
    }

    /// 连续的段落和标题拼成一个串。
    ///
    /// **逐块解析再拼**，不是拼好再解析：整块丢给解析器的话，第一段里一个落单的
    /// `*` 可能和第三段里的配成一对、把中间整段变成斜体。逐块解析天然不会跨块配对。
    static func mergedText(id: Int64, first: Int, blocks: [Markdown.Block],
                           terms: [String]) -> AttributedString {
        let key = MergedKey(id: id, first: first, count: blocks.count, terms: terms)
        if let hit = mergedStore[key] { return hit }

        var made = AttributedString()
        for (i, b) in blocks.enumerated() {
            if i > 0 {
                // 分隔符要带字体，否则那一行的行高会跳。
                // 标题前后只给一个换行 —— 标题字号本来就大、自带分量，
                // 再空一行会把版面撑散（段落之间才需要空行）。
                var sep = AttributedString(Markdown.separator(before: blocks[i - 1].kind,
                                                              and: b.kind))
                sep.font = .body
                made += sep
            }
            switch b.kind {
            case .paragraph(let t):
                made += Markdown.inline(t, terms: terms, base: .body)
            case .heading(let level, let t):
                made += Markdown.inline(t, terms: terms, base: Markdown.headingFont(level))
            default:
                break       // groupTextBlocks 只会放这两种进来
            }
        }
        if mergedStore.count >= blockCapacity { mergedStore.removeAll(keepingCapacity: true) }
        mergedStore[key] = made
        return made
    }

    static func invalidate() {
        blockStore.removeAll(keepingCapacity: true)
        runStore.removeAll(keepingCapacity: true)
        mergedStore.removeAll(keepingCapacity: true)
    }
}

// MARK: - 视图

/// 一条 Claude 回复渲染成的块序列。
///
/// **整条仍然只占 `LazyVStack` 的一行** —— 块视图住在 `MessageBubble` 内部，
/// 行数还是消息数。这很关键：滚动定位那套机制（首尾锚点、两步滚到底）
/// 是按行估高度的，把块拆成行会把它整个搅乱。
@MainActor
struct MarkdownBody: View {
    let messageId: Int64
    let blocks: [Markdown.Block]
    let terms: [String]
    let onCopy: (String) -> Void

    /// 连续的段落和标题并成一组，整组渲染成**一个** `Text` —— 跨块的选择靠这个
    private var groups: [[Markdown.Block]] { Markdown.groupTextBlocks(blocks) }

    var body: some View {
        let gs = groups
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(gs.enumerated()), id: \.element.first!.id) { index, group in
                groupView(group)
                    .padding(.top, gap(between: index == 0 ? nil : gs[index - 1].last!.kind,
                                       and: group.first!.kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 块之间的间距。连续的列表项要挨紧，别的要透气 ——
    /// 一律给同一个间距的话，列表会散成一堆互不相干的行。
    /// 段落之间的间距不在这里：它们已经并进同一个 `Text`，靠空行分隔。
    private func gap(between prev: Markdown.Kind?, and cur: Markdown.Kind) -> CGFloat {
        guard let prev else { return 0 }
        if case .listItem = prev, case .listItem = cur { return 3 }
        if case .heading = cur { return 12 }
        return 7
    }

    @ViewBuilder
    private func groupView(_ group: [Markdown.Block]) -> some View {
        switch group[0].kind {
        case .paragraph, .heading:
            // 整组一个 Text。块之间的换行由 mergedText 拼进串里，
            // 所以这里不需要再给间距。
            Text(MarkdownCache.mergedText(id: messageId, first: group[0].id,
                                          blocks: group, terms: terms))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            blockView(group[0])
        }
    }

    @ViewBuilder
    private func blockView(_ block: Markdown.Block) -> some View {
        switch block.kind {
        case .paragraph(let text):
            // 走不到这里（段落都被 groupView 接走了），留着让 switch 完整
            Text(attr(block, text, style: 0, base: .body))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            // 同段落，走不到这里，留着让 switch 完整
            Text(attr(block, text, style: level, base: Markdown.headingFont(level)))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(attr(block, text, style: 0, base: .body))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 16)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(.quaternary).frame(width: 3)
                Text(attr(block, text, style: 0, base: .body))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let lang, let text):
            CodeBlock(text: attr(block, text, style: 9,
                                 base: .system(.callout, design: .monospaced), isCode: true),
                      lang: lang,
                      onCopy: { onCopy(text) })

        case .rule:
            Divider().padding(.vertical, 3)

        case .table(let header, let rows, let align):
            TableBlock(messageId: messageId, blockId: block.id, terms: terms,
                       header: header, rows: rows, align: align, onCopy: onCopy)
        }
    }

    private func attr(_ block: Markdown.Block, _ text: String,
                      style: Int, base: Font, isCode: Bool = false) -> AttributedString {
        MarkdownCache.inline(id: messageId, block: block.id, text: text,
                             terms: terms, style: style, base: base, isCode: isCode)
    }

}

/// 围栏代码块。
///
/// **长行换行，不做横向滚动。** 横向 ScrollView 嵌在正文这个纵向 ScrollView 里，
/// 触控板上会抢走纵向滚动手势 —— 翻一个满是代码块的会话时每滑到一块就卡一下，
/// 比换行难受得多。换行不丢任何字符，代价只是长行不好看。
///
/// **悬停不能改变布局。** 复制按钮用 overlay 浮在右上角，不进 VStack ——
/// 最早它是跟语言标签同一行的，于是没有语言标签的代码块一悬停就**凭空多出一行**，
/// 块变高、下面的正文整个被推下去（用户实测报的就是这个）。
/// 语言标签那行只跟「有没有语言」有关，和鼠标在哪无关。
@MainActor
struct CodeBlock: View {
    let text: AttributedString
    let lang: String?
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang {
                Text(lang)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.top, 6)
            }
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L.copyCode)
            .padding(5)
            // 用 opacity 而不是条件渲染：条件渲染会让按钮出现/消失时参与布局
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
    }
}

/// Markdown 表格。
///
/// 用 `Grid` 而不是嵌套的 HStack/VStack：列宽必须**跨行对齐**，
/// 这正是 Grid 存在的理由。逐列的对齐靠在表头那一行的单元格上挂
/// `.gridColumnAlignment` —— 它设的是整列，只需要在一行上声明一次。
///
/// **窄栏靠换行，不做横向滚动**，理由同代码块：横向 ScrollView 嵌在正文这个
/// 纵向 ScrollView 里会抢走触控板的纵向手势。列窄了单元格自己折行，一个字不丢。
@MainActor
struct TableBlock: View {
    let messageId: Int64
    let blockId: Int
    let terms: [String]
    let header: [String]
    let rows: [[String]]
    let align: [Markdown.Align]
    let onCopy: (String) -> Void
    @State private var hovering = false

    /// 列数按**最宽的那一行**算。Claude 偶尔会给出参差的行（某行少一个 `|`），
    /// 按表头算的话那些多出来的单元格会被静默丢掉。
    private var columns: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 5) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    cellText(row: -1, col: c, bold: true)
                        // 整列的对齐在这里定，下面各行不用再声明
                        .gridColumnAlignment(hAlign(c))
                }
            }
            // 直接放在 Grid 里（不套 GridRow）的视图会自动跨满所有列。
            // 用 Rectangle 而不是 Divider：Divider 那条线太淡，
            // 表头和数据行贴在一起时分不出来。
            Rectangle().fill(.tertiary).frame(height: 1)
            ForEach(rows.indices, id: \.self) { r in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cellText(row: r, col: c, bold: false)
                    }
                }
            }
        }
        .padding(10)
        // 描边用 .tertiary / 1pt。原来是 .quaternary / 0.5pt，深色背景下几乎看不见，
        // 表格和正文糊成一片（用户实测反馈）。代码块不需要这么重的边 ——
        // 它有填充色，边界本来就清楚。
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.tertiary, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            Button { onCopy(Markdown.tableSource(header: header, rows: rows, align: align)) } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .padding(4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L.copyTable)
            .padding(5)
            // 同代码块：悬停只改可见性，不改布局
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cellText(row: Int, col: Int, bold: Bool) -> some View {
        let raw = cell(row: row, col: col)
        Text(MarkdownCache.inline(id: messageId, block: blockId,
                                  // 表头用 0，数据行从 1 开始，别和表头撞键
                                  cell: (row + 1) * columns + col,
                                  text: raw, terms: terms,
                                  style: bold ? 8 : 0,
                                  base: bold ? .callout.weight(.semibold) : .callout))
            .multilineTextAlignment(textAlign(col))
            .textSelection(.enabled)
    }

    /// 参差的行按空单元格补齐，不越界
    private func cell(row: Int, col: Int) -> String {
        let source = row < 0 ? header : rows[row]
        return col < source.count ? source[col] : ""
    }

    private func hAlign(_ col: Int) -> HorizontalAlignment {
        switch col < align.count ? align[col] : .left {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }

    private func textAlign(_ col: Int) -> TextAlignment {
        switch col < align.count ? align[col] : .left {
        case .left:   return .leading
        case .center: return .center
        case .right:  return .trailing
        }
    }
}
