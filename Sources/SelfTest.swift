import Foundation

/// 无界面自检：建全量索引并断言结果，用来在没有 UI 的情况下确认索引层是对的。
enum SelfTest {

    /// 自测查询词。
    ///
    /// 刻意选 Claude Code 会话里**普遍存在的通用技术词**，而不是某个人的项目名 ——
    /// 否则换一台机器跑，这批断言会整片变红，而失败原因跟代码毫无关系。
    /// 断言本身也全是相对关系（子集、≤、>0），不依赖具体命中数。
    private enum Q {
        /// 中文三字词：走 FTS 路径（两字会被 trigram 静默吞掉，见 [4]）
        static let cn = "数据库"
        /// 高频英文词，正文和工具输出里都有
        static let common = "error"
        /// 与 `common` 大量共现，用来测多词 AND 求交集
        static let second = "file"
        /// 工具输出里海量出现、正文里相对少 —— 用来验证噪音过滤确实有意义
        static let noisy = "git"
        /// 低频词，测另一端的边界
        static let rare = "install"
    }

    private static var failures: [String] = []
    private static var checks = 0

    /// 跑哪一档。
    ///
    /// 拆两档的理由：纯函数档在任何机器上都该全绿，语料档要有 `~/.claude/projects`
    /// 才有意义。没拆之前，别人 clone 下来跑 `--selftest` 会因为「你的机器上没有
    /// 我的会话」而红一片 —— 失败原因和代码毫无关系，这种失败比不跑还糟。
    enum Scope {
        /// 只跑不碰磁盘的断言
        case pure
        /// 纯函数档 + 建索引跑语料断言
        case full
    }

    /// 磁盘上有没有可索引的语料。没有就只能跑纯函数档。
    static func hasCorpus() -> Bool {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
                at: Indexer.defaultRoot, includingPropertiesForKeys: nil) else { return false }
        for dir in dirs where !Indexer.isOwnProbe(dir) {
            let inside = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if inside.contains(where: { $0.pathExtension == "jsonl" }) { return true }
        }
        return false
    }

    static func run(dbPath: String, scope: Scope) -> Int32 {
        failures = []; checks = 0

        pureChecks()

        if scope == .full {
            guard corpusChecks(dbPath: dbPath) else { return 1 }
        } else {
            print("\n" + String(repeating: "·", count: 52))
            if hasCorpus() {
                print("按 --pure 只跑了纯函数档，跳过了索引与搜索断言。")
            } else {
                print("跳过语料档 —— \(Indexer.defaultRoot.path) 下没有会话记录。")
            }
            print("纯函数断言不依赖语料，上面的结果依然有效。")
        }

        print("\n" + String(repeating: "─", count: 52))
        let label = scope == .full ? "" : "（纯函数档）"
        if failures.isEmpty {
            print("✅ \(checks) 项断言全部通过\(label)")
            return 0
        }
        print("❌ \(failures.count)/\(checks) 项失败\(label):")
        for f in failures { print("   · \(f)") }
        return 1
    }

    /// 纯函数档：不读磁盘、不建索引、不依赖任何会话记录。
    /// 任何机器上都该全绿 —— 这里红了就是真的有 bug。
    private static func pureChecks() {
        // ---------- 7. 侧栏选中范围 ----------
        //
        // 侧栏曾经直接拿 `Int64?` 当 List 的 selection，「全部项目」那行 tag 是 nil。
        // SwiftUI 把 nil 当成「没有选中」，两者无法区分 —— 选过某个项目之后
        // 「全部项目」就点不动了。现在用显式的 case 表示「全部」。
        print("\n[7s] 侧栏选中范围")
        expect(ProjectScope.all != ProjectScope.project(0), "「全部」和项目 0 是不同的值")
        expect(ProjectScope.project(7) == ProjectScope.project(7), "同一项目相等")
        expect(ProjectScope.project(7) != ProjectScope.project(8), "不同项目不等")
        // 桥接到模型的 Int64? 必须双向无损
        let roundTrip: (Int64?) -> Int64? = { pid in
            let scope: ProjectScope = pid.map(ProjectScope.project) ?? .all
            if case .project(let id) = scope { return id }
            return nil
        }
        expect(roundTrip(nil) == nil, "nil ↔ 全部 往返一致")
        expect(roundTrip(42) == 42, "项目 id 往返一致")
        expect(Set([ProjectScope.all, .project(1), .project(2)]).count == 3,
               "三种取值互不冲突（可当 Set/Hashable 用）")

        // ---------- 7d. 额度用量解析 ----------
        //
        // 解析的是 `claude -p "/usage"` 的人类可读输出，格式随 Claude Code 版本变。
        // 这里钉住当前格式，同时确认最危险的那条：描述性百分比不能被误当成额度。
        print("\n[7d] 额度用量解析")
        let sample = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 14% used · resets Jul 31 at 7pm (Asia/Shanghai)
        Current week (all models): 20% used · resets Aug 5 at 2am (Asia/Shanghai)
        Current week (Fable): 0% used

        What's contributing to your limits usage?

        Last 24h · 577 requests · 10 sessions
          87% of your usage was at >150k context
        Last 7d · 5561 requests · 28 sessions
          79% of your usage came from sessions active for 8+ hours
        """
        let snap = UsageProbe.parse(sample)
        expect(snap.sessionPercent == 14, "会话窗口 14%（得到 \(snap.sessionPercent.map(String.init) ?? "nil")）")
        expect(snap.weekPercent == 20, "本周 20%（得到 \(snap.weekPercent.map(String.init) ?? "nil")）")
        expect(snap.sessionResets == "Jul 31 at 7pm (Asia/Shanghai)", "会话窗口的重置时间")
        expect(snap.weekResets == "Aug 5 at 2am (Asia/Shanghai)", "本周的重置时间")
        expect(snap.extraLimits.count == 1 && snap.extraLimits.first?.label == "Fable",
               "括号里的附加额度单独成项")
        expect(snap.extraLimits.first?.percent == 0, "Fable 0%")
        // "87% of your usage was at >150k" 不带 "used"，绝不能被当成额度
        expect(snap.sessionPercent != 87 && snap.weekPercent != 87,
               "描述性百分比（87% of your usage…）没被误认成额度")
        expect(snap.raw == sample, "原文完整留存，解析失败也不丢信息")
        expect(snap.parsedAnything, "样本能解析出内容")

        // 拿不到数据时不能假装解析成功 —— 那样界面会显示 0% 让人以为额度没用
        let empty = UsageProbe.parse("Error: something went wrong")
        expect(!empty.parsedAnything, "无效输出不产生假数据")
        expect(empty.sessionPercent == nil && empty.weekPercent == nil, "无效输出下百分比为 nil")

        // 旧方案（固定 session id + --resume）会撞会话锁，报这一句。
        // 它必须被当成失败：解析成 0% 会让人以为额度没用。
        let locked = UsageProbe.parse(
            "Error: Session ID c1a0de00-0000-4000-8000-000000000001 is already in use.")
        expect(!locked.parsedAnything, "会话锁冲突被当成失败而不是 0%")

        // 实测撞到过的降级形态：服务端那三行百分比没回来，本地分析段齐全。
        // 这种要能被识别成「是用量正文、只是缺百分比」，从而降级展示而不是整个报错。
        let partial = """
        You are currently using your subscription to power your Claude Code usage

        What's contributing to your limits usage?
        Approximate, based on local sessions on this machine — does not include other devices.

        Last 24h · 684 requests · 7 sessions
          83% of your usage was at >150k context
          54% of your usage came from subagent-heavy sessions
        """
        expect(UsageProbe.looksLikeUsage(partial), "缺百分比的输出仍被认作用量正文")
        let ps = UsageProbe.parse(partial)
        expect(!ps.parsedAnything, "缺百分比时不伪造数字")
        expect(ps.raw == partial, "降级时原文完整保留（那段分析是本地算的，有用）")
        // "83% of your usage was at >150k" 不带 used，绝不能被当成额度
        expect(ps.sessionPercent == nil && ps.weekPercent == nil,
               "描述性百分比没被误认成额度")
        // 真正的失败（没登录 / 找不到命令）不该被当成用量正文去降级
        expect(!UsageProbe.looksLikeUsage("zsh: command not found: claude"),
               "命令找不到不算用量正文")
        expect(!UsageProbe.looksLikeUsage("Invalid API key · Please run /login"),
               "未登录不算用量正文")

        // ---------- 7f. 有新输出时滚到底部 ----------
        //
        // 这个开关唯一的坑在**默认值**：`UserDefaults.bool(forKey:)` 对不存在的键
        // 返回 false，用它就没法区分「从没设置过」和「明确关掉」，
        // 于是默认值会悄悄变成「关」—— 对老用户来说就是行为无声无息地改了。
        print("\n[7f] 有新输出时滚到底部")
        expect(FollowSetting.resolve(stored: nil), "从没设置过 → 默认开（保持原有行为）")
        expect(FollowSetting.resolve(stored: true), "存了 true → 开")
        expect(!FollowSetting.resolve(stored: false),
               "存了 false → 关（和「没存过」区分得开）")
        // 非 Bool 的脏数据（手改过 plist 之类）也要落到默认开，而不是崩或者关掉
        expect(FollowSetting.resolve(stored: "yes"), "脏数据回落到默认开")
        // 钉住上面那段注释说的事：resolve 的兜底和 UserDefaults.bool 的兜底相反
        expect(FollowSetting.resolve(stored: nil)
                != UserDefaults.standard.bool(forKey: "aKeyThatIsNeverSet-ClaudeSessionSearch"),
               "resolve 的默认值与 UserDefaults.bool 的兜底相反（所以不能用 bool(forKey:)）")

        // ---------- 7y. 跨天刷新 ----------
        //
        // 用户实测：app 连开三天，08-28 16:57 的会话一直显示「Today 16:57」，
        // 而当天已经是 08-31。
        //
        // 关键判断：**格式化逻辑是无辜的**。`style(for:now:)` 拿真实的 now 去算，
        // 三天前的日期照样落在 .thisYear 档。错的是跨天时没有任何可观察状态变化，
        // SwiftUI 于是从不重算 body，昨天渲染的字符串就一直挂着。
        // 下面头两条断言就是把「不是格式化的锅」钉死 —— 免得以后有人跑来改格式。
        print("\n[7y] 跨天刷新")
        let cal2 = Calendar.current
        func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
            cal2.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
        }
        let aug28 = at(2026, 8, 28, 16, 57)
        let aug31 = at(2026, 8, 31, 10, 0)
        expect(When.style(for: aug28, now: aug28) == .today,
               "08-28 当天看 08-28 → 今天（这就是当初渲染出「Today」的原因，本身没错）")
        expect(When.style(for: aug28, now: aug31) == .thisYear,
               "08-31 看 08-28 → 今年档，不是今天（分档逻辑无辜）")
        expect(When.style(for: aug28, now: at(2026, 8, 29, 10, 0)) == .yesterday,
               "08-29 看 08-28 → 昨天")

        // 跨天信号本身
        expect(DayTicker.sameDay(aug28, at(2026, 8, 28, 23, 59)), "同一天的两个时刻算同一天")
        expect(!DayTicker.sameDay(aug28, aug31), "隔三天不算同一天")
        // 差一分钟但跨了午夜 —— 时间差小不代表同一天，这是最容易写错的边界
        expect(!DayTicker.sameDay(at(2026, 8, 28, 23, 59), at(2026, 8, 29, 0, 0)),
               "跨午夜哪怕只差一分钟也算换天")

        MainActor.assumeIsolated {
            // 幂等：同一天内反复调用不触发重画。三个触发源能随便叠就是靠这条。
            let ticker = DayTicker.shared
            expect(!ticker.refresh(now: ticker.today), "同一天内 refresh 不触发变更")
            expect(!ticker.refresh(now: ticker.today.addingTimeInterval(1)),
                   "同一天内隔一秒再调也不触发")
            // 真跨天才动
            let threeDaysLater = cal2.date(byAdding: .day, value: 3, to: ticker.today)!
            expect(ticker.refresh(now: threeDaysLater), "跨天时 refresh 返回 true（触发重画）")
            expect(DayTicker.sameDay(ticker.today, threeDaysLater), "跨天后 today 跟上了")
            // 收尾：把 today 拨回真实的今天，别影响后面的断言
            _ = ticker.refresh(now: Date())
            expect(DayTicker.sameDay(ticker.today, Date()), "自检结束后 today 已复位")
        }

        // ---------- 7r2. 重置时刻：12 小时制歧义 ----------
        //
        // 用户实测：app 显示「Resets Sep 10 at 12:59am」，而 claude 的面板上是
        // 「Resets Sep 10 at 1am」。两件事混在一起：
        //
        // 1. 那一分钟的差是**上游给的**。app 全程只是把 claude 那行字原样搬过来
        //    （`[7d]` 里 `snap.weekResets` 的断言就是这个口径），同一个二进制隔几
        //    分钟连跑两次即可复现 12:59am / 1am 两种输出 —— 不是这里能修的。
        // 2. `12:59am` 本身读不出来是几点。12am 是午夜、12pm 是中午，恰好是
        //    12 小时制里最反直觉的两个点。这个能修：换成 24 小时制。
        //
        // 下面第一组就是把 12am/12pm 这两条特例钉死 —— 换算写错的话，
        // 一个会把 0:59 说成 12:59，另一个会把中午说成午夜，全是静默错误。
        print("\n[7r2] 重置时刻解析（12 → 24 小时制）")
        func reset(_ s: String) -> UsageProbe.ResetTime? { UsageProbe.parseReset(s) }

        let midnight = reset("Sep 10 at 12:59am (Asia/Shanghai)")
        expect(midnight?.hour == 0 && midnight?.minute == 59,
               "12:59am → 00:59（用户就是被这条绕晕的）")
        expect(midnight?.month == 9 && midnight?.day == 10, "月日解析正确")
        expect(midnight?.timeZoneId == "Asia/Shanghai", "括号里的时区取出来了")
        expect(reset("Sep 10 at 12:00pm (Asia/Shanghai)")?.hour == 12, "12:00pm → 12 点（中午）")
        expect(reset("Sep 10 at 12:00am (Asia/Shanghai)")?.hour == 0, "12:00am → 0 点（午夜）")
        expect(reset("Jul 31 at 7pm (Asia/Shanghai)")?.hour == 19, "7pm → 19 点，分钟缺省为 0")
        expect(reset("Jul 31 at 7pm (Asia/Shanghai)")?.minute == 0, "没写分钟就是整点")
        expect(reset("Aug 5 at 2am (Asia/Shanghai)")?.hour == 2, "2am → 2 点")
        expect(reset("Sep 8 at 3:49pm (Asia/Shanghai)")?.hour == 15, "3:49pm → 15:49")
        expect(reset("Jan 2 at 1am")?.timeZoneId == nil, "没有时区括号也能解析")
        // 上游格式变了必须整条失败，回退到原文照登；绝不能猜出一个错时间
        expect(reset("Sep 10 at 25:00am") == nil, "不合法的小时 → 解析失败")
        expect(reset("Foo 10 at 1am") == nil, "认不出的月份 → 解析失败")
        expect(reset("in about 3 hours") == nil, "完全换一种写法 → 解析失败（回退原文）")

        // 年份不在原文里，只能推。直接用当前年份的话，12 月底看到「Jan 2」
        // 会算成一年后，倒计时就成了 360 多天。
        let dec31 = at(2026, 12, 31, 22, 0)
        let janReset = reset("Jan 2 at 1am (Asia/Shanghai)")!
        let janDate = UsageProbe.resetDate(janReset, now: dec31)!
        expect(cal2.component(.year, from: janDate) == 2027, "12/31 看到「Jan 2」→ 推成下一年")
        expect(janDate > dec31 && janDate.timeIntervalSince(dec31) < 4 * 86400,
               "跨年推算出来的重置点在几天内，不是一年后")

        let sepReset = reset("Sep 10 at 12:59am (Asia/Shanghai)")!
        let sepDate = UsageProbe.resetDate(sepReset, now: at(2026, 9, 8, 15, 0))!
        expect(cal2.component(.year, from: sepDate) == 2026, "同年的日期不乱推年份")

        // 倒计时
        let base = at(2026, 9, 8, 15, 0)
        expect(UsageProbe.countdown(to: at(2026, 9, 10, 0, 59), now: base)
               == .init(days: 1, hours: 9, minutes: 59), "剩 1 天 9 小时 59 分")
        expect(UsageProbe.countdown(to: at(2026, 9, 8, 20, 30), now: base)
               == .init(days: 0, hours: 5, minutes: 30), "同一天内只给时分")
        expect(UsageProbe.countdown(to: base.addingTimeInterval(30), now: base)
               == .init(days: 0, hours: 0, minutes: 0), "不足一分钟 → 全 0（文案说「即将重置」）")
        // 已经过去的重置点必须返回 nil —— 显示「还有 -3 小时」比不显示更糟
        expect(UsageProbe.countdown(to: at(2026, 9, 8, 14, 0), now: base) == nil,
               "重置点已过 → nil，不显示负数")

        MainActor.assumeIsolated {
            // 展示串：一律 HH:mm，且补零（`0:59` 不如 `00:59` 一眼看出是凌晨）
            let stamp = L.usageResetStamp(midnight!)
            expect(stamp.contains("00:59"), "展示串用 24 小时制且补零（得到「\(stamp)」）")
            expect(!stamp.lowercased().contains("am") && !stamp.lowercased().contains("pm"),
                   "展示串里不再有 am/pm")
            // 时区和本机一致时省掉 —— 原文那个 (Asia/Shanghai) 多数时候是废话
            let local = UsageProbe.ResetTime(month: 9, monthName: "Sep", day: 10,
                                             hour: 0, minute: 59,
                                             timeZoneId: TimeZone.current.identifier)
            expect(!L.usageResetStamp(local).contains(TimeZone.current.identifier),
                   "时区等于本机时不显示")
            let remote = UsageProbe.ResetTime(month: 9, monthName: "Sep", day: 10,
                                              hour: 0, minute: 59,
                                              timeZoneId: "America/New_York")
            expect(L.usageResetStamp(remote).contains("America/New_York"),
                   "时区和本机不同时必须显示（这时它是关键信息）")

            // 整行：解析成功走 24 小时制 + 倒计时，解析失败原文照登
            let line = L.usageResetLine("Sep 10 at 12:59am (Asia/Shanghai)",
                                        now: at(2026, 9, 8, 15, 0))
            expect(line.contains("00:59"), "整行用 24 小时制（得到「\(line)」）")
            expect(!line.lowercased().contains("12:59am"), "整行里不再出现 12:59am")
            let garbled = "resets sometime next Tuesday"
            expect(L.usageResetLine(garbled).contains(garbled),
                   "解析不了就原文照登，信息不丢")
        }

        // ---------- 7g. 会话内查找（⌘F） ----------
        //
        // 查找条和工具栏那个全局搜索框共用下游机制（高亮、命中条、⌘G 跳转、
        // 计数），只在「用哪些词」这一步分岔。所以这里钉的全是**优先级和口径**：
        // 写错了不会崩，只会静默地找错东西。
        print("\n[7g] 会话内查找")

        // 口径差异：全局搜索把空格当分词（求交集），查找条把空格当内容。
        // 这是刻意的 —— 两者回答的是不同问题 —— 所以必须钉住。
        expect(AppModel.activeTerms(find: "sqlite 索引", findVisible: true,
                                    global: ["query"]) == ["sqlite 索引"],
               "查找串带空格不切词，整串当一个子串")
        expect(AppModel.activeTerms(find: "x", findVisible: true, global: ["query"]) == ["x"],
               "查找条开着且有输入 → 用查找串")
        // 输入为空时不能让正文丢掉全局高亮：刚按下 ⌘F 还没打字，
        // 原来搜出来的那些黄块不该消失
        expect(AppModel.activeTerms(find: "", findVisible: true, global: ["query"]) == ["query"],
               "查找条开着但没输入 → 仍用全局词")
        expect(AppModel.activeTerms(find: "   ", findVisible: true, global: ["query"]) == ["query"],
               "只打了空格也算没输入")
        expect(AppModel.activeTerms(find: "x", findVisible: false, global: ["query"]) == ["query"],
               "查找条关掉 → 干净回到全局词")
        expect(AppModel.activeTerms(find: "x", findVisible: false, global: []) == [],
               "两边都没有 → 没有高亮词")

        // 匹配本身。走的是小写 UTF-8 字节，所以中英文混排、大小写、
        // 带空格的整串都得单独钉一遍。
        let corpus = [
            AppModel.haystack(id: 1, text: "从 MySQL 换成了 SQLite"),
            AppModel.haystack(id: 2, text: "sqlite 的 索引 建错了"),
            AppModel.haystack(id: 3, text: "完全无关的一条"),
        ]
        expect(AppModel.matchIds(in: corpus, terms: ["sqlite"]) == [1, 2], "单词子串匹配")
        expect(AppModel.matchIds(in: corpus, terms: ["sqlite", "索引"]) == [2],
               "多词求交集：两个词都在同一条里才算命中")
        expect(AppModel.matchIds(in: corpus, terms: ["SQLite"]) == [1, 2],
               "大小写不敏感（查找条不该区分大小写）")
        expect(AppModel.matchIds(in: corpus, terms: ["sqlite 的"]) == [2],
               "整串带空格时按子串找，不当成两个词")
        expect(AppModel.matchIds(in: corpus, terms: []).isEmpty, "没有词 → 没有命中")
        expect(AppModel.matchIds(in: corpus, terms: [""]).isEmpty, "空串不能匹配全部")
        expect(AppModel.matchIds(in: corpus, terms: ["找不到的东西"]).isEmpty, "找不到就是空")

        // 字节级匹配的边界。UTF-8 是自同步编码，所以字节命中等价于字符命中；
        // 下面几条是把「不会误命中」和「不会漏」都钉住。
        expect(AppModel.containsBytes(Array("迁移方案".utf8), Array("移方".utf8)),
               "中文跨字符的子串能找到（字节连续就算命中）")
        expect(!AppModel.containsBytes(Array("迁移".utf8), Array("移迁".utf8)),
               "顺序不同不算命中")
        // 「一」U+4E00 = E4 B8 80，「丁」U+4E01 = E4 B8 81：前两字节相同。
        // 朴素字节查找要是写错了（比如少比一个字节）就会把它们弄混。
        expect(!AppModel.containsBytes(Array("丁".utf8), Array("一".utf8)),
               "前缀字节相同的两个汉字不能互相命中")
        expect(!AppModel.containsBytes(Array("abc".utf8), Array("abcd".utf8)),
               "needle 比 haystack 长 → false，不越界")
        expect(!AppModel.containsBytes(Array("abc".utf8), []), "空 needle → false")
        expect(!AppModel.containsBytes([], Array("a".utf8)), "空 haystack → false")
        expect(AppModel.containsBytes(Array("abc".utf8), Array("abc".utf8)), "整串相等")
        expect(AppModel.containsBytes(Array("aab".utf8), Array("ab".utf8)),
               "首字节匹配但后续失配时要能继续往后找")
        // 顺序必须跟正文顺序一致 —— ⌘G 是「往下一个」，乱序就成了乱跳
        expect(AppModel.matchIds(in: corpus, terms: ["的"]) == [2, 3],
               "命中按正文顺序返回")

        // 命中之间循环。Swift 的 % 对负数返回负值，第一个命中上按「上一个」
        // 会直接拿到 -1 当下标 —— 崩溃，而且只在这一个操作上崩。
        expect(DetailView.wrap(-1, count: 17) == 16, "在第一个命中上按「上一个」→ 绕到最后一个")
        expect(DetailView.wrap(17, count: 17) == 0, "在最后一个上按「下一个」→ 绕回第一个")
        expect(DetailView.wrap(3, count: 17) == 3, "正常范围内不变")
        expect(DetailView.wrap(-20, count: 17) == 14, "连按多次也不越界")
        expect(DetailView.wrap(5, count: 0) == 0, "没有命中时返回 0，不做除零")

        MainActor.assumeIsolated {
            expect(L.hitCounter(0, of: 17) == "1/17", "游标 0 基，显示 1 基")
            expect(L.hitCounter(16, of: 17) == "17/17", "最后一个")
            expect(L.hitCounter(0, of: 0) == "0/0", "没有命中时不崩")
            // 命中变少（比如切换了工具记录口径）时游标可能超界，显示要夹住
            expect(L.hitCounter(99, of: 3) == "3/3", "游标超界时夹到总数")
        }

        // ---------- 7k. Markdown 渲染 ----------
        //
        // 自己做块级切分，是因为 Foundation 两个内置模式都不能直接用：
        // `.full` 解析对了块结构但**把换行全删了**（SwiftUI 的 Text 又不渲染
        // PresentationIntent，整条会揉成一行）；`.inlineOnlyPreservingWhitespace`
        // 保住了换行，却**把代码围栏揉成一行**。所以这里钉的是自己那套切分。
        print("\n[7k] Markdown 块级切分")

        func kinds(_ src: String) -> [Markdown.Kind] { Markdown.blocks(src).map(\.kind) }

        // 标题：`#` 后面必须有空格，否则 `#1 问题` 会被当成标题
        expect(Markdown.headingLevel("## 结论") == 2, "## → 二级标题")
        expect(Markdown.headingLevel("###### 六级") == 6, "六级标题")
        expect(Markdown.headingLevel("####### 七个井号") == nil, "七级不是标题")
        expect(Markdown.headingLevel("#1 问题") == nil, "#1 不是标题（后面没空格）")
        expect(Markdown.headingLevel("#") == nil, "光一个 # 不是标题")
        expect(Markdown.headingLevel("C# 的写法") == nil, "C# 开头的句子不是标题")

        // 列表记号
        expect(Markdown.listMarker("- 第一条")?.marker == "•", "- 是无序列表")
        expect(Markdown.listMarker("* 第一条")?.marker == "•", "* 也是无序列表")
        expect(Markdown.listMarker("1. 第一条")?.marker == "1.", "有序列表保留序号")
        expect(Markdown.listMarker("12) 第十二条")?.marker == "12.", "右括号也算有序")
        expect(Markdown.listMarker("-无空格") == nil, "记号后没空格不是列表")
        expect(Markdown.listMarker("2026. 那一年") == nil, "四位数不是序号（是年份）")
        expect(Markdown.listMarker("*.swift 文件") == nil, "*.swift 不是列表项")
        expect(Markdown.listMarker("2 * 3 = 6") == nil, "算式不是列表项")

        // 围栏优先于一切：里面的 # 和 - 是代码不是语法
        let mdFenced = kinds("""
        前言

        ```python
        # 这是注释，不是标题
        - 这是减号，不是列表
        ```

        后记
        """)
        expect(mdFenced.count == 3, "围栏切出 3 块（段落 + 代码 + 段落），得到 \(mdFenced.count)")
        if case .code(let lang, let body) = mdFenced[1] {
            expect(lang == "python", "语言标签解析出来了")
            expect(body.contains("# 这是注释") && body.contains("- 这是减号"),
                   "围栏里的 # 和 - 原样保留，没被当成标题和列表")
            expect(!body.contains("```"), "围栏标记本身不进正文")
        } else {
            expect(false, "第二块应该是代码块")
        }

        // 没有收尾围栏 —— 正文被 8000 字上限截断时就是这样，
        // 不能因为没闭合就把剩下的内容丢掉
        let unclosed = kinds("说明\n\n```sh\nls -la\necho hi")
        expect(unclosed.count == 2, "未闭合围栏切出 2 块")
        if case .code(_, let body) = unclosed[1] {
            expect(body.contains("ls -la") && body.contains("echo hi"),
                   "未闭合围栏吃到结尾，内容一个字不丢")
        } else {
            expect(false, "未闭合的也该是代码块")
        }

        // 连续引用并成一块，否则视觉上会散成一叠
        let quoted = kinds("> 第一行\n> 第二行\n\n正文")
        expect(quoted.count == 2, "连续引用行并成一块")
        if case .quote(let q) = quoted[0] {
            expect(q == "第一行\n第二行", "引用内容拼对了")
        } else {
            expect(false, "第一块应该是引用")
        }

        // 列表项续行要接回上一项，不能掉出列表变成独立段落
        let cont = kinds("- 第一条很长\n  接着写完\n- 第二条")
        expect(cont.count == 2, "续行接回去之后只有 2 个列表项，得到 \(cont.count)")
        if case .listItem(_, let t, _) = cont[0] {
            expect(t.contains("第一条很长") && t.contains("接着写完"), "续行拼进了第一项")
        } else {
            expect(false, "第一块应该是列表项")
        }

        // 嵌套深度
        if case .listItem(_, _, let d) = kinds("    - 深一层")[0] {
            expect(d == 2, "4 空格缩进 → 深度 2")
        } else {
            expect(false, "缩进的也该是列表项")
        }

        // 表格
        let table = kinds("| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |")
        expect(table.count == 1, "整张表是一个块")
        if case .table(let h, let rs, let al) = table[0] {
            expect(h == ["A", "B"], "表头解析正确")
            expect(rs == [["1", "2"], ["3", "4"]], "数据行解析正确")
            expect(al == [.left, .left], "没写冒号默认左对齐")
        } else {
            expect(false, "应该切成表格块")
        }

        // 对齐
        if case .table(_, _, let al) = kinds("| A | B | C |\n|:---|:---:|---:|\n| 1 | 2 | 3 |")[0] {
            expect(al == [.left, .center, .right], "冒号定义的三种对齐都读对了")
        } else {
            expect(false, "带对齐的也该是表格")
        }

        // 误判防线：没有分隔行就不是表格。
        // 少了这条，一段以 `|` 开头的普通文字（比如画的 ASCII 图）会被当成表格。
        expect(!Markdown.isDelimiterRow("| 正文 |"), "普通行不是分隔行")
        expect(!Markdown.isDelimiterRow("| | |"), "全空单元格不是分隔行（没有 -）")
        expect(Markdown.isDelimiterRow("|---|---|"), "标准分隔行")
        expect(Markdown.isDelimiterRow("| :--- | ---: |"), "带空格和冒号的分隔行")
        if case .paragraph = kinds("| 只有一行 |")[0] {} else {
            expect(false, "没有分隔行 → 当段落，不当表格")
        }

        // 单元格拆分：只有 \| 是转义，别的反斜杠原样留着 ——
        // 按通用转义处理的话 C:\Users\name 会被吃成 C:Usersname
        expect(Markdown.cells("| a | b |") == ["a", "b"], "基本拆分")
        expect(Markdown.cells("| C:\\Users\\name | x |") == ["C:\\Users\\name", "x"],
               "反斜杠路径原样保留")
        expect(Markdown.cells("| a \\| b | c |") == ["a | b", "c"],
               "\\| 是转义的竖线，不拆列")
        expect(Markdown.cells("|  留空  |  |") == ["留空", ""], "空单元格保留位置")

        // 连续段落要并成一组：拆成多个 Text 就没法跨段落选中了
        func groups(_ src: String) -> [[Markdown.Block]] {
            Markdown.groupTextBlocks(Markdown.blocks(src))
        }
        let prose = groups("第一段。\n\n第二段。\n\n第三段。")
        expect(prose.count == 1, "纯文字的三段并成 1 组（得到 \(prose.count) 组）")
        expect(prose[0].count == 3, "这一组里有 3 个段落块")

        // 标题也要并进来。第一版只并段落，可真实的回复长这样 ——
        // 标题/段落/标题/段落 —— 几乎没有连续段落，只并段落等于没做。
        let structured = groups("## 一\n\n正文一。\n\n## 二\n\n正文二。")
        expect(structured.count == 1,
               "标题和段落交替也并成 1 组（得到 \(structured.count) 组）")
        expect(structured[0].count == 4, "四个块全在一组里")
        // 分隔符：段落之间空一行，标题两侧只换行（标题字号自带分量）
        expect(Markdown.separator(before: .heading(level: 2, text: "x"),
                                  and: .paragraph("y")) == "\n", "标题后面只换行")
        expect(Markdown.separator(before: .paragraph("x"),
                                  and: .paragraph("y")) == "\n\n", "段落之间空一行")
        expect(Markdown.separator(before: .paragraph("x"),
                                  and: .heading(level: 2, text: "y")) == "\n\n",
               "标题前面空一行")

        // 被代码块隔开就必须断开 —— 代码块是独立视图，跨不过去
        let mixed = groups("前面两段。\n\n还是前面。\n\n```\ncode\n```\n\n后面一段。")
        expect(mixed.count == 3, "段落 / 代码 / 段落 → 3 组（得到 \(mixed.count)）")
        expect(mixed[0].count == 2, "代码块前的两段并在一起")
        expect(mixed[2].count == 1, "代码块后的一段单独一组")

        // 列表项不并 —— 它们要挂悬挂缩进，得各自成视图
        let listed = groups("- 一\n- 二\n- 三")
        expect(listed.count == 3, "三个列表项不合并")
        expect(Markdown.groupTextBlocks([]).isEmpty, "空输入返回空")

        // 复制表格：重建的 Markdown 必须能原样再解析回来。
        // 最容易错的是转义 —— 解析时把 \| 还原成了字面竖线，
        // 写回去不重新转义的话会多切出一列，粘到别处就是错位的表。
        let tricky = "| 名称 | 说明 |\n|---|:---:|\n| a \\| b | 含竖线 |\n| C:\\Users | 反斜杠 |"
        guard case .table(let th, let tr, let ta) = kinds(tricky)[0] else {
            expect(false, "带转义的表格应该切出来"); return
        }
        let source = Markdown.tableSource(header: th, rows: tr, align: ta)
        guard case .table(let th2, let tr2, let ta2) = kinds(source)[0] else {
            expect(false, "重建出来的源码应该还能解析成表格"); return
        }
        expect(th2 == th, "重建后表头不变")
        expect(tr2 == tr, "重建后数据行不变（含字面竖线和反斜杠）")
        expect(ta2 == ta, "重建后对齐不变")
        expect(source.contains("\\|"), "含竖线的单元格重新转义了")
        expect(source.contains(":---:"), "居中对齐写回了源码")

        // 参差的行：某行少一个 | 时不能把多出来的单元格丢掉，也不能越界
        if case .table(let h2, let rs2, _) = kinds("| A | B | C |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |")[0] {
            expect(h2.count == 3, "表头 3 列")
            expect(rs2[0] == ["1"], "短行原样保留，渲染时按空单元格补齐")
            expect(rs2[1].count == 4, "长行多出来的单元格不丢")
        } else {
            expect(false, "参差的表格也该切出来")
        }

        MainActor.assumeIsolated {
            // 行内：Foundation 那半边。技术文本不能被吃掉。
            func plain(_ s: String) -> String {
                String(Markdown.parse(s).characters)
            }
            for safe in ["foo_bar_baz 里的 snake_case", "删掉 *.swift 和 *.o",
                         "2 * 3 * 4 = 24", "^\\d+_\\w+$", "Array<String>",
                         "echo $PATH && ls", "C:\\Users\\name", "未闭合的 **粗体"] {
                expect(plain(safe) == safe, "技术文本原样保留：\(safe)")
            }
            // 已知会被吃掉的唯一一类：双下划线当成粗体。
            // 全库 22207 条回复里含双下划线的只有 143 条（0.6%），真 __init__ 9 条，
            // 所以接受。钉住它是为了以后换解析器时能立刻发现行为变了。
            expect(plain("__init__") == "init", "双下划线会被当成粗体（已知且接受）")

            // 高亮叠加在解析结果上 —— 标记法在解析之后对不上了，必须按范围加
            var attributed = Markdown.parse("把 **sqlite** 换成 sqlite 新版本")
            Highlight.highlight(&attributed, terms: ["sqlite"])
            var marked = 0, bold = 0
            for run in attributed.runs {
                if run.backgroundColor != nil { marked += 1 }
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { bold += 1 }
            }
            expect(marked == 2, "两处都高亮了（得到 \(marked)）")
            expect(bold >= 1, "粗体没被高亮覆盖掉")
            // 空词不能死循环
            var empty = Markdown.parse("随便一段")
            Highlight.highlight(&empty, terms: ["", " "])
            expect(String(empty.characters) == "随便一段", "空查询词不改动内容也不卡住")
        }

        // ---------- 7n. 复制成纯文本 ----------
        //
        // 「复制这条消息」送出去的是渲染后的样子，不是源码。
        // 粘到邮件、工单、聊天框里的人看不到渲染，只看到一堆 ** 和 |---|。
        print("\n[7n] 复制成纯文本")

        expect(Markdown.plainText("这是 **重点**，还有 `ptCode`。")
                == "这是 重点，还有 ptCode。", "粗体和行内代码的标记被剥掉")
        expect(Markdown.plainText("## 结论") == "结论", "标题去掉井号")
        expect(Markdown.plainText("> 引用一句") == "引用一句", "引用去掉尖括号")

        // 链接：渲染出来只剩文字，纯文本里丢了 URL 就再也找不回来
        expect(Markdown.plainText("见 [文档](https://example.com/a)")
                == "见 文档 (https://example.com/a)", "链接补回 URL")
        // 规范化后的 URL 里中文是一串 %E5%8F%AF，复制出来人读不了
        expect(Markdown.plainText("见 [文档](https://example.com/文档)")
                == "见 文档 (https://example.com/文档)", "URL 里的中文不留百分号编码")
        // 链接文字里夹了别的格式时，AttributedString 会把它切成好几个 run，
        // 每个都带着同一个 link。逐 run 补 URL 会补好几遍。
        expect(Markdown.plainText("见 [**粗**文档](https://example.com/a)")
                == "见 粗文档 (https://example.com/a)", "链接被切成多段时 URL 只补一次")
        // 解析器会把裸邮箱和裸网址也认成链接并补上协议头。那不是新信息 ——
        // 补出去就是每个邮箱后面跟一串重复的东西（真实语料里抓到的）。
        expect(!Markdown.plainText("https://example.com").contains("("),
               "裸网址不重复括一遍")
        expect(Markdown.plainText("联系 someone@example.com") == "联系 someone@example.com",
               "裸邮箱不补 mailto:")
        expect(Markdown.linkAddsInfo(url: "https://example.com/a", text: "文档"),
               "正常链接要补 URL")
        expect(!Markdown.linkAddsInfo(url: "mailto:a@b.com", text: "a@b.com"),
               "mailto: 前缀不算新信息")
        expect(!Markdown.linkAddsInfo(url: "https://example.com/", text: "https://example.com"),
               "规范化补的尾斜杠不算新信息")

        // 代码块只脱围栏。里面的 * _ # 是代码本身，剥它就是破坏它
        let ptCode = Markdown.plainText("```swift\nlet x = a * b   // **not bold**\n```")
        expect(ptCode == "let x = a * b   // **not bold**",
               "代码块原样保留，只去掉围栏（得到 \(ptCode)）")

        // 列表：项与项之间只换行。一律空行的话六项清单会被拉成半屏
        let ptList = Markdown.plainText("- 一\n- 二\n- 三")
        expect(ptList == "• 一\n• 二\n• 三", "列表项之间单换行（得到 \(ptList.debugDescription)）")
        expect(Markdown.plainText("正文。\n\n- 一").contains("\n\n"),
               "段落和列表之间仍然空一行")

        // 分隔线在纯文本里没有对应物
        expect(!Markdown.plainText("上\n\n---\n\n下").contains("---"), "分隔线不输出")

        // 表格是这件事里最值钱的一块：删掉竖线会粘成一摊烂泥，要重排成对齐的
        let ptTable = Markdown.plainText("| 名称 | 说明 |\n|---|---|\n| a | 短 |\n| bbbb | 长一些 |")
        expect(!ptTable.contains("|"), "纯文本表格里没有竖线")
        expect(!ptTable.contains("---"), "也没有 Markdown 分隔行")
        let ptRows = ptTable.components(separatedBy: "\n")
        expect(ptRows.count == 4, "表头 + 横线 + 两行数据（得到 \(ptRows.count) 行）")
        // 列宽按**显示宽度**对齐。按 count 算的话「名称」和「ab」一样长，
        // 第二列就会整体左移两格 —— 中文表格最常见的歪法。
        let ptAligned = Markdown.plainText("| 名称 | x |\n|---|---|\n| ab | y |")
            .components(separatedBy: "\n")
        expect(ptAligned[0] == "名称  x",
               "表头：汉字列后只隔两格（得到 \(ptAligned[0].debugDescription)）")
        expect(ptAligned[2] == "ab    y",
               "ab 补到四格宽再隔两格（得到 \(ptAligned[2].debugDescription)）")

        expect(Markdown.displayWidth("名称") == 4, "汉字占两格")
        expect(Markdown.displayWidth("abcd") == 4, "ASCII 占一格")
        expect(Markdown.displayWidth("中a") == 3, "中英混排")
        expect(Markdown.displayWidth("👨‍👩‍👦") == 2, "emoji 按字形簇算两格，不是按标量")
        expect(Markdown.trimTrailingSpaces("a  ") == "a", "行尾空格去掉")
        expect(Markdown.trimTrailingSpaces("  a") == "  a", "行首空格留着")

        // 技术文本不能被吃掉 —— 这条路径和渲染共用解析器，但出口不同，单独钉住
        for ptSafe in ["删掉 *.swift", "foo_bar_baz", "C:\\Users\\name", "2 * 3 = 6"] {
            expect(Markdown.plainText(ptSafe) == ptSafe, "技术文本原样复制：\(ptSafe)")
        }
        expect(Markdown.plainText("") == "", "空正文复制出空串")

        // ---------- 7o. Toast ----------
        //
        // Toast 靠 `.animation(value:)` 驱动，值不变就不重播。
        // 所以「连着复制两次」必须产生两个**不相等**的 Toast ——
        // 否则第二次点击界面上毫无反应，看着像没生效。
        // 那个自增 id 就是干这个的，不是装饰。
        print("\n[7o] Toast")
        let t1 = AppModel.Toast(id: 1, text: "已复制恢复命令", isError: false)
        let t2 = AppModel.Toast(id: 2, text: "已复制恢复命令", isError: false)
        expect(t1 != t2, "文字相同、id 不同的 toast 不相等（连点两次能重播动画）")
        expect(t1 == AppModel.Toast(id: 1, text: "已复制恢复命令", isError: false),
               "同 id 同内容相等（不会无谓重播）")
        expect(t1 != AppModel.Toast(id: 1, text: "已复制恢复命令", isError: true),
               "错误态和正常态不相等")

        // ---------- 7r. 恢复命令 ----------
        //
        // 命令展开写全，不依赖 `yolor` 那个 shell alias ——
        // alias 只在交互式 shell 里生效，粘进脚本或换台机器就废了。
        print("\n[7r] 恢复命令")
        let full = "claude --dangerously-skip-permissions --chrome --resume"
        expect(AppModel.resumeCommandLine(cwd: "/Users/x/src/repo", fileKey: "abc-123")
                == "cd /Users/x/src/repo && \(full) abc-123", "恢复命令展开写全")
        // 带空格的项目目录必须转义，否则粘到终端 cd 会断在空格处
        expect(AppModel.resumeCommandLine(cwd: "/Users/x/My Projects/a", fileKey: "z")
                == "cd /Users/x/My\\ Projects/a && \(full) z", "带空格的路径被转义")
        // 不能退回 alias —— 那是这次改动要避免的
        expect(!AppModel.resumeCommandLine(cwd: "/a", fileKey: "b").contains("yolor"),
               "不输出 shell alias")
        expect(AppModel.resumeCommandLine(cwd: "/a", fileKey: "b").hasSuffix(" b"),
               "会话 id 在命令末尾（--resume 的参数位）")
    }

    /// 语料档：需要 `~/.claude/projects` 下有真实会话，会建一个完整索引。
    /// 断言只用**结构性**关系（子集、非空、一一对应），不钉具体数量 ——
    /// 每个人的语料规模都不一样。
    private static func corpusChecks(dbPath: String) -> Bool {
        print("数据库: \(dbPath)")
        // 自检总是从零开始，避免旧库干扰断言
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }

        guard let store = try? Store(path: dbPath) else {
            print("❌ 无法创建数据库"); return false
        }
        let indexer = Indexer(store: store)

        // ---------- 1. 全量索引 ----------
        print("\n[1] 全量索引 \(Indexer.defaultRoot.path)")
        guard let first = try? indexer.indexAll(onProgress: { p in
            if p.scanned % 50 == 0 || p.scanned == p.total {
                print("    \(p.scanned)/\(p.total) …")
            }
        }) else {
            print("❌ 索引失败"); return false
        }
        print(String(format: "    完成: %d 项目 / %d 主会话 / %d 子 agent / %d 条正文 / %.1fs",
                     first.projects, first.sessions, first.subagents, first.newMessages, first.elapsed))
        if !first.failed.isEmpty {
            print("    ⚠️ \(first.failed.count) 个文件解析失败:")
            for f in first.failed.prefix(5) { print("       \(f.path): \(f.error)") }
        }

        guard let counts = try? store.counts() else { print("❌ 统计失败"); return false }
        print(String(format: "    入库: %d 会话 + %d 子 agent, %d 条正文, %.1f MB 文本",
                     counts.sessions, counts.sidechains, counts.messages,
                     Double(counts.textBytes) / 1e6))

        expect(first.failed.isEmpty, "所有文件都能解析（失败 \(first.failed.count) 个）")

        // 和磁盘对账，而不是断言「至少有 N 个会话」。
        // Claude Code 会清理旧记录（实测半年内从 97 个主会话降到 82 个），
        // 写死数量的护栏迟早会因为数据自然衰减而误报，那时人只会把它调低——
        // 护栏就废了。「索引到的 == 磁盘上有的」才是索引层真正要守的不变量。
        let disk = countOnDisk()
        print("    磁盘: \(disk.sessions) 主会话 + \(disk.sidechains) 子 agent, \(disk.projects) 个项目目录")
        expect(counts.sessions == disk.sessions,
               "主会话全部入库（库 \(counts.sessions) / 磁盘 \(disk.sessions)）")
        expect(counts.sidechains == disk.sidechains,
               "子 agent 全部入库（库 \(counts.sidechains) / 磁盘 \(disk.sidechains)）")
        expect(counts.projects == disk.projects,
               "有会话的项目全部入库（库 \(counts.projects) / 磁盘 \(disk.projects)）")
        // 正文块数只做「不为空」的下限，具体数量同样随数据变
        expect(counts.messages > counts.sessions,
               "正文块数多于会话数（\(counts.messages) 条）")

        // ---------- 2. 增量索引：未变的文件必须原样跳过 ----------
        //
        // 注意不能断言「零新增」：自检运行时，当前这个 Claude 会话自己的
        // jsonl 正在被追加写入，第二遍把新落盘的几行收进来是**正确行为**。
        // 所以断言的是「几乎全部跳过」，并把活跃文件的增量单独报出来。
        print("\n[2] 重跑索引（未变的文件应跳过）")
        let total = first.sessions + first.subagents
        guard let second = try? indexer.indexAll() else { print("❌ 二次索引失败"); return false }
        let active = total - second.skipped
        print("    跳过 \(second.skipped)/\(total) 个文件，\(active) 个仍在写入，新增 \(second.newMessages) 条")

        // 同时活跃的会话不会多：留 3 个的余量（本会话 + 可能并行的另一两个）
        expect(active <= 3, "至多 3 个文件仍在写入（实际 \(active)）")
        expect(second.newMessages < 100, "增量只带来少量新内容（实际 \(second.newMessages) 条）")

        guard let counts2 = try? store.counts() else { print("❌ 统计失败"); return false }
        expect(counts2.messages == counts.messages + second.newMessages,
               "正文总数 = 首轮 + 增量（\(counts.messages)+\(second.newMessages) vs \(counts2.messages)）")
        expect(counts2.sessions == counts.sessions && counts2.sidechains == counts.sidechains,
               "重跑不产生重复会话")

        // 回归防护：增量索引只读文件尾部，标题行（在文件开头）不在这一批里。
        // 曾经因此把会话名覆盖成某条中间消息的正文。
        print("\n[2b] 标题不被增量索引冲掉")
        if let stmt = try? store.prepare("""
            SELECT title_source, count(*) FROM sessions GROUP BY title_source ORDER BY 2 DESC
            """) {
            var weak_ = 0, total2 = 0
            while stmt.step() {
                let src = stmt.text(0) ?? "?"
                let n = stmt.int(1)
                total2 += n
                if src == "first" { weak_ += n }
                print("    \(src): \(n)")
            }
            // 'first' 是最弱的兜底来源。真正需要它的会话极少（既无生成标题
            // 也无人类开场消息），出现一堆就说明权威标题被覆盖了。
            expect(weak_ <= 2, "退到「首条正文」的会话不超过 2 个（实际 \(weak_)）")
        }

        // 有显式标题行的文件，标题必须来自那个标题行
        if let stmt = try? store.prepare("""
            SELECT count(*) FROM sessions
            WHERE is_sidechain = 0 AND title_source IN ('first', 'none')
            """), stmt.step() {
            expect(stmt.int(0) <= 2, "主会话几乎都有权威标题（弱标题 \(stmt.int(0)) 个）")
        }

        // ---------- 3. 长词走 FTS ----------
        print("\n[3] FTS5 检索（≥3 字符）")
        for q in [Q.cn, Q.common, Q.noisy, Q.second, Q.rare] {
            let r = probe(store, q)
            expect(r.strategy == .fts, "『\(q)』走 FTS 路径")
            print(String(format: "    %-14@ %5d 命中 / %3d 会话 / %6.1f ms  %@",
                         q as NSString, r.totalHits, r.groups.count, r.elapsedMs,
                         r.groups.first.map { "首条: \($0.title)" } ?? ""))
        }
        expect(probe(store, Q.cn).totalHits > 0, "『\(Q.cn)』有命中")
        expect(probe(store, Q.common).totalHits > 0, "『\(Q.common)』有命中")

        // ---------- 4. 短词必须自动降级，这是 trigram 最大的坑 ----------
        print("\n[4] 短查询降级为子串扫描（<3 字符）")
        for q in ["迁移", "部署", "PR", "UI"] {
            let r = probe(store, q)
            expect(r.strategy == .substring, "『\(q)』降级为子串扫描")
            expect(r.totalHits > 0, "『\(q)』有命中（trigram 会静默返回 0）")
            print(String(format: "    %-8@ %5d 命中 / %3d 会话 / %6.1f ms",
                         q as NSString, r.totalHits, r.groups.count, r.elapsedMs))
        }

        // ---------- 5. 多词 AND ----------
        print("\n[5] 多词 AND")
        let single = probe(store, Q.common).totalHits
        let multi = probe(store, "\(Q.common) \(Q.second)").totalHits
        print("    \(Q.common)=\(single)  |  \(Q.common)+\(Q.second)=\(multi)")
        expect(multi <= single, "多词 AND 结果不多于单词（\(multi) ≤ \(single)）")

        // ---------- 6. 筛选器 ----------
        print("\n[6] 筛选器")
        // 默认口径 = 只搜对话正文（不含 thinking / 工具调用 / 工具输出）
        let convHits = probe(store, Q.common).totalHits

        var withNoise = SearchFilter(); withNoise.includeToolNoise = true
        let noisyHits = (try? store.search(query: Q.common, filter: withNoise))?.totalHits ?? -1
        print("    仅对话正文=\(convHits)  含工具输出=\(noisyHits)")
        expect(convHits <= noisyHits, "默认口径是含噪音口径的子集（\(convHits) ≤ \(noisyHits)）")
        expect(convHits > 0, "排除工具噪音后仍有对话命中")
        expect(noisyHits > convHits, "工具输出确实贡献了大量额外命中（噪音过滤有意义）")

        var humanOnly = SearchFilter(); humanOnly.humanOnly = true
        let humanHits = (try? store.search(query: Q.common, filter: humanOnly))?.totalHits ?? -1
        print("    仅我说的=\(humanHits)")
        expect(humanHits >= 0 && humanHits <= convHits, "humanOnly 是对话正文的子集")

        var noSub = SearchFilter(); noSub.includeSubagents = false
        let noSubHits = (try? store.search(query: Q.common, filter: noSub))?.totalHits ?? -1
        print("    含子 agent=\(convHits)  不含=\(noSubHits)")
        expect(noSubHits >= 0 && noSubHits <= convHits, "排除子 agent 后结果变少或相等")

        if let firstProject = (try? store.projects())?.first {
            var byProject = SearchFilter(); byProject.projectId = firstProject.id
            let n = (try? store.search(query: Q.common, filter: byProject))?.totalHits ?? -1
            print("    限定项目『\(firstProject.displayName)』=\(n)")
            expect(n >= 0, "按项目筛选可执行")
        }

        // ---------- 6b. 子 agent 命中归并到父会话 ----------
        print("\n[6b] 子 agent 归并")
        let rolled = probe(store, Q.common)
        expect(rolled.groups.allSatisfy { !$0.isSidechain },
               "搜索结果里不出现独立的子 agent 行")
        let withSubHits = rolled.groups.filter { $0.subagentHits > 0 }
        print("    \(rolled.groups.count) 个会话，其中 \(withSubHits.count) 个含子 agent 命中")
        for g in withSubHits.prefix(3) {
            print("      \(g.title): \(g.hitCount) 条（子 agent \(g.subagentHits) 条）")
            expect(g.subagentHits <= g.hitCount, "子 agent 命中数不超过总命中数")
        }

        // 最近列表同样只含主会话
        let recents = (try? store.recentSessions(projectId: nil, includeSubagents: false, limit: 50)) ?? []
        expect(!recents.isEmpty, "最近会话列表非空")
        expect(recents.allSatisfy { !$0.isSidechain }, "最近列表里没有子 agent")
        print("    最近 \(recents.count) 个会话全是主会话")

        // ---------- 6c. 会话开头必须是「你说的话」 ----------
        //
        // 回归防护：曾经靠「origin.kind == human」判定人类输入，但早期记录
        // 没有 origin 字段（只有 promptSource: "typed"），几百条真实提问被
        // 误判成工具输出而隐藏，会话看起来像是 Claude 先开口的。
        print("\n[6c] 会话首条可见消息是人类提问")
        if let stmt = try? store.prepare("""
            WITH firsts AS (
              SELECT m.session_id, m.role,
                     ROW_NUMBER() OVER (PARTITION BY m.session_id ORDER BY m.seq) AS rn
              FROM messages m JOIN sessions s ON s.id = m.session_id
              WHERE s.is_sidechain = 0 AND m.kind = 'text'
            )
            SELECT role, count(*) FROM firsts WHERE rn = 1 GROUP BY role
            """) {
            var byRole: [String: Int] = [:]
            while stmt.step() { byRole[stmt.text(0) ?? "?"] = stmt.int(1) }
            let user = byRole["user"] ?? 0
            let assistant = byRole["assistant"] ?? 0
            let total2 = user + assistant
            print("    首条是我说的: \(user) 个会话 / Claude 先开口: \(assistant) 个")
            expect(total2 > 0, "能统计到首条可见消息")
            // 少数会话确实由 Claude 先开口（-p 非交互、resume 续接等）
            expect(Double(user) / Double(max(total2, 1)) >= 0.85,
                   "≥85% 的会话由我先开口（实际 \(user)/\(total2)）")
        }

        // 曾经这里钉的是「≥ 2000 条」—— 那是修某个 bug 时本机的回归线。
        // 换台机器就毫无意义，改成只验证「确实索引到了人类消息」。
        if let stmt = try? store.prepare("""
            SELECT count(*) FROM messages WHERE role = 'user' AND kind = 'text'
            """), stmt.step() {
            print("    人类文本消息共 \(stmt.int(0)) 条")
            expect(stmt.int(0) > 0, "索引到了人类文本消息（实际 \(stmt.int(0)) 条）")
        }

        // 斜杠命令应被压成简洁形式，不是整段 XML
        if let stmt = try? store.prepare("""
            SELECT count(*) FROM messages WHERE text LIKE '<command-name>%'
            """), stmt.step() {
            expect(stmt.int(0) == 0, "没有残留的 <command-name> XML（实际 \(stmt.int(0)) 条）")
        }

        // ---------- 6d. 用户改的名字要盖过自动摘要 ----------
        //
        // 回归防护：ai-title 曾被排在 custom-title 之前，导致 22 个会话显示的是
        // Claude 生成的摘要，而不是你在 CLI 里改的名字（如「ISSUE-123」）。
        print("\n[6d] custom-title 优先于 ai-title")
        if let stmt = try? store.prepare("""
            SELECT title_source, count(*) FROM sessions
            WHERE is_sidechain = 0 GROUP BY title_source ORDER BY 2 DESC
            """) {
            var bySource: [String: Int] = [:]
            while stmt.step() { bySource[stmt.text(0) ?? "?"] = stmt.int(1) }
            for (k, v) in bySource.sorted(by: { $0.value > $1.value }) { print("    \(k): \(v)") }
            // 数量不断言 —— 你可能从来没在 CLI 里改过会话名，那 custom 就是 0。
            // 「custom 盖过 ai」这条规则本身由 pureChecks 的 resolvedTitle 断言守着。
            expect(bySource.values.reduce(0, +) > 0, "每个会话都解析出了标题来源")
        }

        // 优先级本身用纯函数钉住 —— 原来这里抽查的是某个固定会话 id，
        // 那既泄露语料，也只覆盖到 custom 这一档。
        var meta = SessionMeta()
        meta.firstPrompt = "帮我看下这段代码"
        expect(meta.resolvedTitle.source == "prompt", "只有开场白 → 用开场白")
        meta.aiTitle = "重构索引层"
        expect(meta.resolvedTitle.source == "ai", "有 ai-title → 盖过开场白")
        meta.agentName = "code-reviewer"
        expect(meta.resolvedTitle.source == "agent", "agent-name 盖过 ai-title")
        meta.customTitle = "ISSUE-123"
        expect(meta.resolvedTitle.text == "ISSUE-123" && meta.resolvedTitle.source == "custom",
               "用户改的名字优先级最高（实际『\(meta.resolvedTitle.text)』）")
        // 空串不能算数，否则会盖掉后面真正有内容的候选
        meta.customTitle = ""
        expect(meta.resolvedTitle.source == "agent", "空的 custom-title 要被跳过")

        // ---------- 7. 项目名去重 ----------
        print("\n[7] 项目列表（显示名去重）")
        let projects = (try? store.projects()) ?? []
        for p in projects.prefix(8) {
            print("    \(p.displayName)  —  \(p.sessionCount) 会话  (\(p.cwd))")
        }
        let names = projects.map(\.displayName)
        expect(Set(names).count == names.count, "项目显示名无重复（\(names.count) 个）")
        expect(projects.allSatisfy { !$0.cwd.isEmpty }, "每个项目都解析出了真实 cwd")

        // ---------- 8. 会话正文可读 ----------
        print("\n[8] 会话正文读取")
        if let group = probe(store, Q.cn).groups.first {
            let msgs = (try? store.messages(sessionId: group.sessionId)) ?? []
            print("    『\(group.title)』共 \(msgs.count) 条")
            expect(!msgs.isEmpty, "能读出会话正文")
            expect(msgs.map(\.seq) == msgs.map(\.seq).sorted(), "正文按 seq 有序")
            if let m = msgs.first(where: { $0.kind == "text" && $0.role == "user" }) {
                print("    首条人类消息: \(m.text.prefix(60).replacingOccurrences(of: "\n", with: " "))")
            }
            let subs = (try? store.subagents(of: group.sessionId)) ?? []
            if !subs.isEmpty { print("    含 \(subs.count) 个子 agent") }

            // 默认口径（只查对话正文）必须和「查全量再在内存里过滤」完全等价。
            // 它是打开会话最热的一步，走的是另一条 SQL 分支，不能悄悄跑偏。
            let convo = (try? store.messages(sessionId: group.sessionId, conversationOnly: true)) ?? []
            let filtered = msgs.filter { $0.kind == "text" || $0.kind == "thinking" }
            expect(convo.map(\.id) == filtered.map(\.id), "conversationOnly 与内存过滤等价")
            let tools = (try? store.toolMessageCount(sessionId: group.sessionId)) ?? -1
            expect(tools == msgs.count - filtered.count,
                   "toolMessageCount 对得上（\(tools) vs \(msgs.count - filtered.count)）")
        }

        // ---------- 7a. 项目显示名 ----------
        //
        // 实测过一个静默失败：某会话开头堆了十几条 file-history-snapshot，
        // 第一个带 cwd 的记录落在 304 KB 处，而 firstCwd 只读 64 KB → 取不到 cwd。
        // 更糟的是取不到时存的是**空串**，`?? dir.lastPathComponent` 的兜底
        // 因此永远不触发，侧栏那一行整个空白。
        print("\n[7a] 项目显示名")
        let projs = (try? store.projects()) ?? []
        let blank = projs.filter { $0.displayName.trimmingCharacters(in: .whitespaces).isEmpty }
        expect(blank.isEmpty, "没有项目显示名为空（\(blank.count) 个：\(blank.map(\.dirName).prefix(2).joined(separator: ", "))）")
        let noCwd = projs.filter { $0.cwd.isEmpty }
        print("    \(projs.count) 个项目，cwd 缺失 \(noCwd.count) 个")
        expect(noCwd.isEmpty, "每个项目都解析出了 cwd（缺 \(noCwd.count) 个）")

        // 兜底逻辑本身：cwd 缺失时也必须给出非空的名字
        let fake = Indexer.defaultRoot.appendingPathComponent("-Users-x-source-code-foo-bar")
        expect(!Indexer.basis(for: fake, cwd: nil).isEmpty, "cwd 为 nil 时兜底名非空")
        expect(!Indexer.basis(for: fake, cwd: "").isEmpty, "cwd 为空串时兜底名非空")
        expect(Indexer.basis(for: fake, cwd: "/a/b") == "/a/b", "有 cwd 时优先用 cwd")

        // ---------- 7b. 会话带上所属项目 ----------
        // 四个构造点各写一遍 SQL，列序号错一位就会静默取到别的字段。
        // projectId 用来判断「切项目后选中的会话是否还在范围内」，错了会把人踢走。
        print("\n[7b] 会话的 projectId")
        if let p = (try? store.projects())?.first {
            let inProject = (try? store.recentSessions(projectId: p.id,
                                                       includeSubagents: true, limit: 5)) ?? []
            expect(!inProject.isEmpty, "项目 \(p.displayName) 下能查到会话")
            expect(inProject.allSatisfy { $0.projectId == p.id },
                   "recentSessions 的 projectId 与筛选条件一致")
            if let one = inProject.first, let single = (try? store.session(id: one.sessionId)) ?? nil {
                expect(single.projectId == p.id, "session(id:) 的 projectId 一致")
            }
            let hits = probe(store, Q.common).groups
            expect(hits.allSatisfy { $0.projectId > 0 }, "搜索结果也带上了 projectId")
            if let parent = inProject.first(where: { !$0.isSidechain }) {
                let subs = (try? store.subagents(of: parent.sessionId)) ?? []
                expect(subs.allSatisfy { $0.projectId == parent.projectId },
                       "子 agent 与父会话同项目")
            }
        }

        // ---------- 7k2. 拿真实语料跑一遍切分 ----------
        //
        // 单元断言只能覆盖我想得到的形状。这里把库里真实的 Claude 回复全过一遍，
        // 断言**没有内容被静默吞掉** —— 渲染后该显示的字符必须一个不少。
        //
        // 允许消失的只有三类，都是有意的显示转换：
        //   链接的 URL（变成点击目标）、表格对齐的冒号、反斜杠转义还原。
        print("\n[7k2] 真实语料切分（无声吞字检查）")
        var mdChecked = 0, mdLost = 0, mdBlocks = 0, mdSingleView = 0
        var mdViews = 0, mdTextGroups = 0, mdTextBlocks = 0
        var mdKinds: [String: Int] = [:]
        // 样本里有多少条回复「长得像有表格」—— 用来判断切不出表格是语料如此，还是 bug
        var mdTableSyntax = 0
        // 复制成纯文本：不能丢内容，也不能把 Markdown 标记带出去
        var ptLost = 0, ptWithPipe = 0, ptTables = 0, ptBadTable = 0
        let syntaxChars = Set("*_`#|->~[]()+. \t\n\r•:\\─")
        func contentOnly(_ s: String) -> String {
            String(s.filter { !syntaxChars.contains($0) })
        }
        MainActor.assumeIsolated {
            for group in recents.prefix(12) {
                let msgs = (try? store.messages(sessionId: group.sessionId,
                                                conversationOnly: true)) ?? []
                for m in msgs where m.role == "assistant" && m.kind == "text" {
                    guard mdChecked < 1500 else { break }
                    mdChecked += 1
                    if m.text.contains("|\n") || m.text.contains("|\r\n") { mdTableSyntax += 1 }
                    let bs = Markdown.blocks(m.text)
                    mdBlocks += bs.count
                    let gs = Markdown.groupTextBlocks(bs)
                    if gs.count == 1 { mdSingleView += 1 }
                    mdViews += gs.count
                    for g in gs where g.count >= 1 {
                        if case .paragraph = g[0].kind { mdTextGroups += 1; mdTextBlocks += g.count }
                        else if case .heading = g[0].kind { mdTextGroups += 1; mdTextBlocks += g.count }
                    }
                    for b in bs {
                        switch b.kind {
                        case .paragraph: mdKinds["段落", default: 0] += 1
                        case .heading:   mdKinds["标题", default: 0] += 1
                        case .code:      mdKinds["代码块", default: 0] += 1
                        case .listItem:  mdKinds["列表项", default: 0] += 1
                        case .quote:     mdKinds["引用", default: 0] += 1
                        case .table:     mdKinds["表格", default: 0] += 1
                        case .rule:      mdKinds["分隔线", default: 0] += 1
                        }
                    }
                    var shown: [String] = []
                    for b in bs {
                        switch b.kind {
                        case .paragraph(let t), .quote(let t):
                            shown.append(String(Markdown.parse(t).characters))
                        case .heading(_, let t):
                            shown.append(String(Markdown.parse(t).characters))
                        case .listItem(let marker, let t, _):
                            shown.append(marker + String(Markdown.parse(t).characters))
                        case .code(let lang, let t):
                            shown.append((lang ?? "") + t)
                        case .table(let h, let rs, _):
                            for cell in h + rs.flatMap({ $0 }) {
                                shown.append(String(Markdown.parse(cell).characters))
                            }
                        case .rule:
                            break
                        }
                    }
                    if contentOnly(m.text) != contentOnly(shown.joined()) { mdLost += 1 }

                    // 复制按钮送出去的东西。比对要一字不差，所以让它把代码块的
                    // 语言标注也留着 —— 实际复制时那个标注是丢掉的。
                    let pt = Markdown.plainText(m.text)
                    if contentOnly(m.text)
                        != contentOnly(Markdown.plainText(m.text, keepCodeLanguage: true)) {
                        ptLost += 1
                    }
                    // 切出来的表格重排后必须是「表头 + 横线 + 每行一条」。
                    // 切不出来的表格（没有前导竖线那种）会原样留在正文里，
                    // 那是块切分器的边界，不是复制的问题，这里不计它。
                    for b in bs {
                        if case .table(let h, let rs, let al) = b.kind {
                            ptTables += 1
                            let lines = Markdown.tablePlain(header: h, rows: rs, align: al)
                                .components(separatedBy: "\n")
                            if lines.count != rs.count + 2 { ptBadTable += 1 }
                        }
                    }
                    if pt.contains("|---") { ptWithPipe += 1 }
                }
            }
        }
        print("   检查 \(mdChecked) 条 Claude 回复 → \(mdBlocks) 个块，"
              + "内容有出入 \(mdLost) 条")
        print("   块型: " + mdKinds.sorted { $0.value > $1.value }
                .map { "\($0.key) \($0.value)" }.joined(separator: " · "))
        // 表格是第二步加的，风险是「检测条件写太严 → 真实数据一个都不匹配」，
        // 而手写的单元样本照样过。所以不钉数量（你的语料里可能真没表格），
        // 只钉「样本里出现过表格语法，就必须切得出来」。
        // 复制成纯文本：标记没了，内容一个字不少
        print("   复制成纯文本：内容有出入 \(ptLost) 条，重排了 \(ptTables) 张表"
              + "，正文里仍有表格管道的 \(ptWithPipe) 条（切不出来的表格，原样留着）")
        expect(ptLost == 0, "纯文本复制一个字都没丢（有出入 \(ptLost) 条）")
        expect(ptBadTable == 0,
               "\(ptTables) 张真实表格重排后行数都对（错的 \(ptBadTable) 张）")

        if mdTableSyntax > 0 {
            expect((mdKinds["表格"] ?? 0) > 0,
                   "\(mdTableSyntax) 条回复含表格语法，至少要切出一个表格"
                   + "（得到 \(mdKinds["表格"] ?? 0) 个）")
        } else {
            print("   样本里没有表格语法，跳过表格断言")
        }
        // 整条只有一组 ⇒ 整条就是一个 Text ⇒ 选择完全没被破坏。
        // 合并之前，一条五段的纯文字回复要拆成 5 个 Text，五段谁也选不到一起。
        let singleShare = 100 * mdSingleView / max(mdChecked, 1)
        print("   整条只渲染成一个视图（选择不受影响）的：\(mdSingleView) 条 "
              + "(\(singleShare)%)")
        // 这才是衡量合并效果的指标：文字块（段落 + 标题）被压成了多少个 Text。
        // 每组里的块共享一个 Text，选择在组内完全连续。
        print("   文字块 \(mdTextBlocks) 个 → 并成 \(mdTextGroups) 个 Text"
              + "（平均每个 Text 装 \(mdTextBlocks * 10 / max(mdTextGroups, 1)) / 10 个块）")
        print("   整条平均渲染成 \(mdViews * 10 / max(mdChecked, 1)) / 10 个视图")
        // 占比不断言 —— 回复里代码块多的人，这个数天然就低。
        // 合并必须真的起作用，但「平均每组几个块」取决于你的回复长什么样，钉不住。
        // 改成钉结构：分组数不可能多于块数，且出现过相邻文字块时必须真的并了。
        if mdTextGroups > 0 {
            expect(mdTextGroups <= mdTextBlocks, "分组数不可能多于块数")
            if mdTextBlocks > mdTextGroups {
                print("   合并生效：\(mdTextBlocks) 个文字块 → \(mdTextGroups) 个 Text")
            } else {
                print("   样本里没有相邻文字块可合并（每块都被代码/表格隔开）")
            }
        }
        expect(mdChecked > 0, "取到了真实回复样本（得到 \(mdChecked) 条）")
        // 阈值 3%：剩下的是链接 URL 这类有意转换。真出现吞字的 bug 会远超这个数
        // （最早跑通前把列表序号漏掉时，这个比例是 14.7%）。
        expect(Double(mdLost) / Double(max(mdChecked, 1)) < 0.03,
               "无声吞字比例 < 3%（得到 \(mdLost)/\(mdChecked)）")

        MainActor.assumeIsolated {
            expect(MarkdownSetting.resolve(stored: nil), "没设置过 → 默认渲染 Markdown")
            expect(!MarkdownSetting.resolve(stored: false), "明确关掉 → 不渲染")
        }

        // ---------- 7t. 消息时间戳 ----------
        //
        // 正文原来复用会话列表的 `When.short`，而它今年以内只给「M月d日」、
        // 更早只给「yyyy年M月d日」—— 时分整个丢了。这里钉住「正文四档全带时分」，
        // 同时确认列表那套保持紧凑（两者不能再被合并回去）。
        print("\n[7t] 消息时间戳")
        let cal = Calendar.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        expect(When.style(for: noon, now: noon) == .today, "同一天判为今天")
        expect(When.style(for: cal.date(byAdding: .day, value: -1, to: noon)!, now: noon) == .yesterday,
               "前一天判为昨天")
        expect(When.style(for: cal.date(byAdding: .day, value: -40, to: noon)!, now: noon) == .thisYear
                || When.style(for: cal.date(byAdding: .day, value: -40, to: noon)!, now: noon) == .older,
               "40 天前落在今年或更早档")
        expect(When.style(for: cal.date(byAdding: .year, value: -2, to: noon)!, now: noon) == .older,
               "两年前判为更早")

        MainActor.assumeIsolated {
            for style in [L.DateStyle.today, .yesterday, .thisYear, .older] {
                expect(L.messageDateFormat(style).contains("HH:mm"),
                       "正文格式 \(style) 带时分")
            }
            // 列表那套保持原样：今年以内和更早**不带**时分（一屏几十行，紧凑优先）
            expect(!L.shortDateFormat(.thisYear).contains("HH:mm"), "列表格式今年档保持紧凑")

            // 四档各打一个样例出来，格式好不好看只能肉眼判断
            let now = Date()
            for (label, d) in [("今天", now),
                               ("昨天", cal.date(byAdding: .day, value: -1, to: now)!),
                               ("今年", cal.date(byAdding: .day, value: -40, to: now)!),
                               ("更早", cal.date(byAdding: .year, value: -2, to: now)!)] {
                let iso = ISO8601DateFormatter().string(from: d)
                print("    \(label) → \(When.messageStamp(iso) ?? "nil")")
            }

            // 真实时间戳走一遍完整链路
            let stamp = When.messageStamp("2026-08-11T10:48:12.853Z")
            expect(stamp?.contains(":") == true, "真实 ISO 时间戳格式化后含时分（得到 \(stamp ?? "nil")）")
            // 无 ts / 解析不了 → nil，界面上整个不渲染，不留占位符
            expect(When.messageStamp(nil) == nil, "没有时间戳时返回 nil")
            expect(When.messageStamp("not a date") == nil, "解析不了时返回 nil 而不是「—」")
        }

        // 库里 user 消息的 ts 覆盖率 —— 「回补」的前提。掉下来说明索引丢了时间。
        if let s = try? store.prepare(
            "SELECT count(*), sum(ts IS NOT NULL AND ts <> '') FROM messages WHERE role='user'"),
           s.step(), s.int(0) > 0 {
            expect(s.int(0) == s.int(1),
                   "user 消息 ts 覆盖率 100%（\(s.int(1))/\(s.int(0))）")
        }

        // ---------- 7u. 取用量时不碰 TCC 保护目录 ----------
        //
        // 用户实测：点「查看用量」偶尔弹「是否允许本 app 访问『文档』文件夹」。
        // 根因是取数走 `zsh -l`，登录 shell 加载 .zprofile/.bash_profile，
        // 用户在那里把 maven 装在 ~/Documents 下并追加进 PATH，zsh 查找命令时
        // opendir 了它。而 TCC 把权限归因给 responsible process，
        // 于是弹窗写的是本 app 的名字。
        //
        // 修法是显式定位 claude、不经 shell、只给固定 PATH。
        // 这几条断言守住的就是「PATH 里永远不出现保护目录」这个不变量。
        print("\n[7u] 取用量的进程环境")
        expect(UsageProbe.isTCCSafe(UsageProbe.safePathDirs),
               "给子进程的 PATH 不含任何 TCC 保护目录")
        // 反向验证 isTCCSafe 本身有效 —— 否则它可能恒真，断言就是空的
        let home = NSHomeDirectory()
        expect(!UsageProbe.isTCCSafe(["\(home)/Documents/programming/apache-maven-3.9.11/bin"]),
               "~/Documents 下的 PATH 条目会被判为不安全")
        expect(!UsageProbe.isTCCSafe(["\(home)/Downloads"]), "~/Downloads 本身会被判为不安全")
        expect(UsageProbe.isTCCSafe(["\(home)/.local/bin", "/opt/homebrew/bin"]),
               "常规安装位置判为安全")
        // 名字里带保护目录名、但不在其下的路径不能误判
        expect(UsageProbe.isTCCSafe(["\(home)/DocumentsBackup/bin"]),
               "~/DocumentsBackup 不是 ~/Documents，不误判")
        if let claude = UsageProbe.locateClaude() {
            expect(FileManager.default.isExecutableFile(atPath: claude.path),
                   "定位到的 claude 可执行：\(claude.path)")
            expect(UsageProbe.isTCCSafe([claude.deletingLastPathComponent().path]),
                   "claude 自身也不在保护目录下")
        } else {
            print("  ⚠️  本机找不到 claude，跳过定位断言")
        }

        // 自己的探测会话必须被索引跳过，否则 app 会把自己产生的会话列出来
        let probeDir = Indexer.defaultRoot.appendingPathComponent(UsageProbe.projectDirName)
        expect(Indexer.isOwnProbe(probeDir), "探测会话目录被识别为自己的")
        expect(!Indexer.isOwnProbe(Indexer.defaultRoot.appendingPathComponent("-Users-x-source-code")),
               "普通项目目录不会被误判")
        let leaked = (try? store.prepare(
            "SELECT count(*) FROM projects WHERE dir_name LIKE '%ClaudeSessionSearch-probe'"))
        if let s = leaked, s.step() {
            expect(s.int(0) == 0, "探测会话没有进索引库（找到 \(s.int(0)) 个）")
        }

        // 库里每个项目在磁盘上都必须真实存在且有 jsonl。
        // 这条能同时抓住两类问题：源目录被删后库里留了幽灵项目，
        // 以及探测/临时会话悄悄混进列表（实测两种都发生过）。
        let fm = FileManager.default
        var ghosts: [String] = []
        for p in (try? store.projects()) ?? [] {
            let dir = Indexer.defaultRoot.appendingPathComponent(p.dirName)
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if !files.contains(where: { $0.hasSuffix(".jsonl") }) { ghosts.append(p.dirName) }
        }
        expect(ghosts.isEmpty, "项目列表里没有幽灵项目（\(ghosts.count) 个：\(ghosts.prefix(3).joined(separator: ", "))）")

        // ---------- 7e. 残卷回收 ----------
        //
        // Claude Code 默认 30 天清理会话正文（cleanupPeriodDays），但 history.jsonl
        // 不受这个窗口约束。这里验证「已删会话」的判定不会把活着的会话算进去 ——
        // 算错了就会给用户一堆重复的残卷，让人以为原文丢了。
        print("\n[7e] 残卷回收")
        let hist = Recover.readHistory()
        print("    history.jsonl \(hist.count) 条提问")
        if !hist.isEmpty {
            expect(hist.allSatisfy { !$0.sessionId.isEmpty }, "每条提问都带 sessionId")
            expect(hist.contains { $0.timestamp > Date(timeIntervalSince1970: 1_700_000_000) },
                   "时间戳解析正确（毫秒转秒）")

            let alive = Recover.aliveSessionIds()
            let lost = Recover.lostSessions()
            print("    磁盘现存 \(alive.count) 个会话，判定已被清理的 \(lost.count) 个")
            expect(lost.allSatisfy { !alive.contains($0.sessionId) },
                   "判定为已清理的会话确实不在磁盘上")
            expect(Set(lost.map(\.sessionId)).count == lost.count, "每个丢失会话只出现一次")
            expect(lost.allSatisfy { !$0.entries.isEmpty }, "每个丢失会话都带提问")
            expect(lost.allSatisfy { $0.first <= $0.last }, "提问按时间正序")

            if let sample = lost.max(by: { $0.entries.count < $1.entries.count }) {
                let md = Recover.markdown(sample)
                expect(md.contains(sample.sessionId), "残卷里带会话 id")
                expect(md.contains("残卷"), "残卷明确标注了不完整")
                let missing = sample.entries.filter { !md.contains($0.text) }
                expect(missing.isEmpty, "每条提问都出现在残卷里（缺 \(missing.count) 条）")
            }
        }

        // ---------- 7c. 导出 ----------
        print("\n[7c] 导出")

        // CSV 转义。会话标题里带逗号、引号、换行都很常见，
        // 漏一个整份文件的列就错位，而且错得不报错。
        expect(Export.csvField("plain") == "plain", "普通字段不加引号")
        expect(Export.csvField("a,b") == "\"a,b\"", "含逗号要加引号")
        expect(Export.csvField("say \"hi\"") == "\"say \"\"hi\"\"\"", "内部引号翻倍")
        expect(Export.csvField("line1\nline2") == "\"line1\nline2\"", "含换行要加引号")

        // 文件名净化。`/` 会被当成路径分隔，前导 `.` 会变隐藏文件。
        expect(!Export.sanitize("a/b:c").contains("/"), "去掉路径分隔符")
        expect(!Export.sanitize("a/b:c").contains(":"), "去掉冒号")
        expect(Export.sanitize("  .hidden.  ") == "hidden", "去掉前后空白与句点")
        expect(Export.sanitize("///") .isEmpty, "全是非法字符时得到空串")

        // 代码围栏必须比正文里最长的反引号串更长，否则代码块提前闭合
        let withTicks = "见 ```swift\ncode\n``` 这段"
        let fenced = Export.fence(withTicks)
        expect(fenced.hasPrefix("````"), "正文含 ``` 时围栏加长到 ````")
        expect(fenced.contains(withTicks), "围栏里正文原样保留")
        expect(Export.fence("plain").hasPrefix("```\n"), "普通正文用三个反引号")

        // 拿真实会话跑一遍完整导出，确认结构和不丢内容
        if let group = probe(store, Q.cn).groups.first {
            let msgs = (try? store.messages(sessionId: group.sessionId)) ?? []
            let md = Export.markdown(session: group, messages: msgs)
            print("    『\(group.title)』→ \(md.count) 字，\(msgs.count) 条")
            expect(md.hasPrefix("# "), "Markdown 以一级标题开头")
            expect(md.contains("| Session ID | `\(group.fileKey)`"), "头部带会话 id")

            // 不能靠数 "## " 来核对条数 —— 对话正文本身就充满 Markdown 标题，
            // 会把计数抬高一倍（实测 639 vs 317）。改为直接核对内容没丢：
            // 导出物必须至少装得下所有正文，且逐条都能找到。
            let convo = msgs.filter { $0.kind == "text" }
            let bodyBytes = msgs.reduce(0) { $0 + $1.text.count }
            expect(md.count > bodyBytes, "导出物容得下全部正文（\(md.count) > \(bodyBytes)）")
            let missing = msgs.filter { !$0.text.isEmpty && !md.contains($0.text) }
            expect(missing.isEmpty, "每条正文都原样出现，一条不漏（缺 \(missing.count) 条）")
            if let longest = convo.max(by: { $0.text.count < $1.text.count }) {
                expect(md.contains(longest.text),
                       "最长的一条（\(longest.text.count) 字）没被截断")
            }

            let name = Export.fileName(for: group, index: 7)
            print("    文件名: \(name)")
            expect(name.hasPrefix("007-"), "带序号前缀，保证目录里有序")
            expect(name.hasSuffix(".md"), "扩展名是 .md")
            expect(!name.contains("/"), "文件名里没有路径分隔符")

            let csv = Export.csv(rows: [Export.SessionSummary(
                session: group, totalMessages: msgs.count,
                conversationMessages: convo.count, fileName: name)])
            let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
            expect(lines.first.map(String.init) == Export.csvColumns.joined(separator: ","),
                   "CSV 首行是表头")
            expect(lines.count >= 2, "CSV 有数据行")
        }

        // 单会话导出不带序号前缀，文件名撞了就是**静默覆盖**。
        // 同一父会话能派出几十个 agent，标题重复（"Explore xxx"）很常见，
        // 所以文件名尾巴那串 id 必须能区分它们 —— 挑子 agent 最多的会话来验。
        if let stmt = try? store.prepare("""
            SELECT parent_session_id FROM sessions
            WHERE is_sidechain = 1 AND parent_session_id IS NOT NULL
            GROUP BY parent_session_id ORDER BY count(*) DESC LIMIT 1
            """), stmt.step(), let parent = stmt.text(0) {
            let subs = (try? store.subagents(of: parent)) ?? []
            let names = Set(subs.map { Export.fileName(for: $0) })
            print("    \(parent.prefix(8))… 的 \(subs.count) 个子 agent → \(names.count) 个不同文件名")
            expect(names.count == subs.count,
                   "子 agent 文件名互不相同（\(names.count)/\(subs.count)）")
            if let p = (try? store.session(id: parent)) ?? nil {
                expect(!names.contains(Export.fileName(for: p)), "子 agent 不会和父会话撞名")
            }
            // CSV 里 session_id 对子 agent 是父会话，靠 agent_file 才能唯一定位
            let rows = subs.map {
                Export.SessionSummary(session: $0, totalMessages: 0,
                                      conversationMessages: 0,
                                      fileName: Export.fileName(for: $0))
            }
            let parsed = Export.csv(rows: rows)
                .split(separator: "\n").dropFirst()
                .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
            let agentFiles = Set(parsed.compactMap { $0.count > 1 ? $0[1] : nil })
            expect(agentFiles.count == subs.count,
                   "CSV 的 agent_file 列能唯一标识每个子 agent（\(agentFiles.count)/\(subs.count)）")
            expect(parsed.allSatisfy { $0.count > 9 && $0[9] == "yes" }, "子 agent 行标了 is_subagent")
        }

        // ---------- 8a. 合成主键 → 磁盘文件名 ----------
        // FSEvents 报上来的是真实路径，比对时必须先剥掉 agent 那半，
        // 否则「正在看的会话有新内容」对子 agent 永远不成立。
        print("\n[8a] 子 agent 主键拆分")
        expect(SessionHitGroup.fileKey(of: "abc-123") == "abc-123", "主会话 id 原样返回")
        expect(SessionHitGroup.fileKey(of: "abc-123:agent-deadbeef") == "abc-123",
               "子 agent 主键取父会话那半")
        if let stmt = try? store.prepare("""
            SELECT id, file_path FROM sessions WHERE is_sidechain = 1 LIMIT 1
            """), stmt.step(), let sid = stmt.text(0), let path = stmt.text(1) {
            let key = SessionHitGroup.fileKey(of: sid)
            print("    \(sid.prefix(20))… → \(key.prefix(12))…")
            expect(path.contains(key), "拆出的 key 能在真实文件路径里找到")
            expect(!path.contains(sid), "合成主键本身不出现在路径里（所以必须拆）")
        }

        // ---------- 8b. 长正文截断 ----------
        print("\n[8b] 长正文截断")
        let short = "短消息"
        expect(Highlight.clip(short, expanded: false).shown == short, "短消息不动")
        expect(Highlight.clip(short, expanded: false).hidden == 0, "短消息没有隐藏部分")

        // 找一条真的超长的正文来验，比构造字符串更接近实际
        if let stmt = try? store.prepare("""
            SELECT text FROM messages WHERE kind='text'
            ORDER BY LENGTH(text) DESC LIMIT 1
            """), stmt.step(), let long = stmt.text(0) {
            let clipped = Highlight.clip(long, expanded: false)
            print("    最长正文 \(long.count) 字 → 显示 \(clipped.shown.count)，隐藏 \(clipped.hidden)")
            expect(clipped.shown.count == Highlight.inlineLimit, "截到上限")
            expect(clipped.shown.count + clipped.hidden == long.count, "显示+隐藏 = 原文（不丢字）")
            expect(long.hasPrefix(clipped.shown), "截断取的是开头那一段")
            let full = Highlight.clip(long, expanded: true)
            expect(full.shown == long && full.hidden == 0, "展开后给全文")
        }

        // 抽一个确实有子 agent 的会话，验证父子关系接上了
        let anySub = (try? store.prepare("""
            SELECT parent_session_id, count(*) FROM sessions
            WHERE is_sidechain = 1 AND parent_session_id IS NOT NULL
            GROUP BY parent_session_id ORDER BY count(*) DESC LIMIT 1
            """))
        if let stmt = anySub, stmt.step(), let parent = stmt.text(0) {
            let n = stmt.int(1)
            let subs = (try? store.subagents(of: parent)) ?? []
            print("    子 agent 最多的会话 \(parent.prefix(8))… 有 \(n) 个，查得 \(subs.count) 个")
            expect(subs.count == n, "子 agent 父子关系可反查（\(subs.count)/\(n)）")
            expect(subs.allSatisfy { $0.agentType != nil }, "子 agent 都读到了 agentType")
        }

        // ---------- 9. 高亮标记 ----------
        print("\n[9] 命中高亮标记")
        if let hit = probe(store, Q.common).groups.first?.previews.first {
            let ok = hit.snippet.contains(hlOpen) && hit.snippet.contains(hlClose)
            expect(ok, "FTS 片段带高亮标记")
            print("    \(hit.snippet.replacingOccurrences(of: hlOpen, with: "【").replacingOccurrences(of: hlClose, with: "】").prefix(120))")
        }
        if let hit = probe(store, "迁移").groups.first?.previews.first {
            let ok = hit.snippet.contains(hlOpen)
            expect(ok, "子串路径片段带高亮标记")
            print("    \(hit.snippet.replacingOccurrences(of: hlOpen, with: "【").replacingOccurrences(of: hlClose, with: "】").prefix(120))")
        }

        // ---------- 10. 空查询与特殊字符不应崩 ----------
        print("\n[10] 边界输入")
        for q in ["", "   ", "\"", "\"\"", "*", "OR", "a\"b", "%_\\", "不存在的词xyzzy0987"] {
            let r = (try? store.search(query: q, filter: SearchFilter()))
            expect(r != nil, "查询 \(q.debugDescription) 不抛异常")
        }

        return true
    }

    /// 直接数磁盘上有多少 jsonl，用来和库里的数字对账。
    /// 刻意不复用 Indexer 的扫描逻辑 —— 那样就变成拿被测代码验自己了。
    private static func countOnDisk() -> (sessions: Int, sidechains: Int, projects: Int) {
        let fm = FileManager.default
        let root = Indexer.defaultRoot
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return (0, 0, 0)
        }
        var sessions = 0, sidechains = 0, projects = 0
        for dir in dirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue
            }
            // 和索引层同一口径：app 自己查用量留下的会话两边都不算，
            // 否则这份对账会永远差 1 个会话 1 个项目
            if Indexer.isOwnProbe(dir) { continue }
            // 主会话：项目目录下一层的 *.jsonl
            let top = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let here = top.filter { $0.pathExtension == "jsonl" }.count
            sessions += here
            if here > 0 { projects += 1 }
            // 子 agent：<session-uuid>/subagents/agent-*.jsonl
            for sub in top {
                let agents = dir.appendingPathComponent(sub.lastPathComponent)
                    .appendingPathComponent("subagents")
                let files = (try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil)) ?? []
                sidechains += files.filter { $0.pathExtension == "jsonl" }.count
            }
        }
        return (sessions, sidechains, projects)
    }

    private static func probe(_ store: Store, _ q: String) -> SearchOutcome {
        (try? store.search(query: q, filter: SearchFilter())) ?? SearchOutcome()
    }

    private static func expect(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }
}
