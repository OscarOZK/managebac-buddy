import Foundation

/* ======================================================================
   全应用统一搜索
   ----------------------------------------------------------------------
   之前每个板块各写各的（而且只有一个板块真的接了），结果是：
     · 在 Teams / 课程 / 成绩页打字完全没反应
     · 只认「连续子串」，打 "corner english" 或 "english corner" 之外的词一律不中
     · 大小写、全角、多余空格都会让它失手
   这里统一成一套：

     1) 归一化：转小写、去变音符号、全角转半角、空白压成一个空格
     2) 分词：英数连续为一词，中文一字一词（这样「英语」这样的两字词也能当短语匹配）
     3) 别名统一（词级、最长优先）：EC ⇄ English Corner、hw ⇄ homework、ddl ⇄ due…
        查询与文本都过一遍，之后就是普通匹配 —— 多词别名、词序颠倒都不会漏
     4) 多关键词 AND：空格分开的每个词都要命中
     5) 单复数宽松：quiz / quizzes、task / tasks 互相都能命中
     6) **按词边界比对，绝不子串比对**：否则查 "ec"（english corner 的统一写法）
        会命中 dir"ec"tly、ch"ec"k —— Teams 页搜索"不灵"就是这么来的

   注意：替换**只在词边界上做**。早前用纯子串替换，结果 "quizzes" 会被
   切成 "examzes" —— 这正是「搜索不灵」的典型来源，别再那样写。
   ====================================================================== */

enum Search {

    // MARK: - 别名表
    //
    // 每个词只能出现在一个组里（否则替换结果会随字典顺序变化而不稳定）。
    // 左边的 key 是「主写法」，右边是它的各种写法。

    private static let groups: [String: [String]] = [
        "ec":                 ["english corner", "englishcorner"],
        "homework":           ["hw", "assignment", "作业"],
        "task":               ["todo", "待办", "任务"],
        "due":                ["ddl", "deadline", "截止", "到期"],
        "exam":               ["test", "quiz", "考试", "测试", "小测"],
        "managebac":          ["mb"],
        "biology":            ["bio", "生物"],
        "chemistry":          ["chem", "化学"],
        "physics":            ["phys", "物理"],
        "economics":          ["econ", "经济"],
        "psychology":         ["psych", "心理"],
        "computer science":   ["cs", "comp", "信息技术"],
        "english":            ["ela", "英语"],
        "mathematics":        ["math", "maths", "数学", "calculus", "calc", "微积分"],
        "mail":               ["email", "邮件"],
        "event":              ["calendar", "日程"],
    ]

    // MARK: - 归一化

    /// 小写 + 去变音符号 + 全角转半角 + 空白压一个空格
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                               locale: Locale(identifier: "en_US"))
        return folded
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 分词

    private static func isCJK(_ sc: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(sc.value)
            || (0x4E00...0x9FFF).contains(sc.value)
            || (0xF900...0xFAFF).contains(sc.value)
    }

    /// 英数连续为一词；中文/日文汉字一字一词；其余字符当分隔符丢掉
    static func words(_ s: String) -> [String] {
        var out: [String] = []
        var buf = ""
        for ch in s {
            guard let sc = ch.unicodeScalars.first else { continue }
            let alnum = CharacterSet.alphanumerics.contains(sc)
            if alnum && isCJK(sc) {
                if !buf.isEmpty { out.append(buf); buf = "" }
                out.append(String(ch))
            } else if alnum {
                buf.append(ch)
            } else if !buf.isEmpty {
                out.append(buf); buf = ""
            }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    // MARK: - 词级别名统一

    /// 单写法（可能多词）→ 主写法。长的优先，避免短词把长词切碎。
    ///
    /// key 必须用与 `canon` **完全相同**的分词方式生成：
    /// 中文「化学」要变成 "化 学" 才能和句子里切出来的词序列对上。
    private static let variantMap: [String: String] = {
        var pairs: [(String, String)] = []
        for (key, syns) in groups {
            let k = words(norm(key)).joined(separator: " ")
            guard !k.isEmpty else { continue }
            for alt in syns {
                let a = words(norm(alt)).joined(separator: " ")
                if !a.isEmpty && a != k { pairs.append((a, k)) }
                // 两词短语允许颠倒顺序：用户很可能打成 "corner english"
                let parts = a.split(separator: " ").map(String.init)
                if parts.count == 2 {
                    pairs.append((parts.reversed().joined(separator: " "), k))
                }
            }
        }
        var m: [String: String] = [:]
        for (from, to) in pairs.sorted(by: { $0.0.count > $1.0.count }) where m[from] == nil {
            m[from] = to
        }
        return m
    }()

    /// 变形还原：把常见复数/时态形态还原成词干，供别名表查询
    private static func stems(_ w: String) -> [String] {
        guard w.count >= 3 else { return [] }
        var out: [String] = []
        if w.hasSuffix("ies"), w.count > 4 { out.append(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("es") {
            let d = String(w.dropLast(2))
            out.append(d)
            out.append(String(w.dropLast(1)))
            if d.count > 2, d.last == d.dropLast().last { out.append(String(d.dropLast())) }
        }
        if w.hasSuffix("s") { out.append(String(w.dropLast())) }
        return out.filter { $0.count >= 3 && $0 != w }
    }

    /// 单个词 → 主写法；查不到就试词干；都不行就原样返回
    private static func canonWord(_ w: String) -> String {
        if let k = variantMap[w] { return k }
        for s in stems(w) where variantMap[s] != nil { return variantMap[s]! }
        return w
    }

    /// 整段文本 → 统一写法；多词别名在词序列上做最长匹配
    private static func canon(_ s: String) -> String {
        let ws = words(norm(s))          // 先归一，否则大小写对不上别名表
        guard !ws.isEmpty else { return "" }
        var out: [String] = []
        var i = 0
        while i < ws.count {
            var matched = false
            let maxN = min(3, ws.count - i)
            if maxN >= 1 {
                for n in stride(from: maxN, through: 1, by: -1) {
                    let phrase = ws[i..<(i + n)].joined(separator: " ")
                    if let k = variantMap[phrase] {
                        out.append(k)
                        i += n
                        matched = true
                        break
                    }
                }
            }
            if !matched {
                out.append(canonWord(ws[i]))
                i += 1
            }
        }
        return out.joined(separator: " ")
    }

    // MARK: - 查询

    struct Query: Equatable {
        let raw: String
        /// 归一 + 别名统一之后的整串（用于整串快路径）
        let canoned: String
        let tokens: [String]
        var isEmpty: Bool { tokens.isEmpty }
    }

    static let empty = Query(raw: "", canoned: "", tokens: [])

    static func parse(_ raw: String) -> Query {
        let c = canon(raw)
        guard !c.isEmpty else { return empty }
        var seen = Set<String>()
        let toks = c.split(separator: " ").map(String.init).filter { seen.insert($0).inserted }
        return Query(raw: raw, canoned: c, tokens: toks)
    }

    // MARK: - 匹配

    /// 单个词按**词边界**比对（绝不是子串比对）
    ///
    /// 这里曾经写的是 `hay.contains(tok)`。后果非常具体：查 "english corner"
    /// 会被统一成 "ec"，而 "ec" 是 dir**ec**tly / ch**ec**k / r**ec**eived /
    /// s**ec**tion 的子串 —— 于是 Teams 页一搜就冒出一大半无关任务，这就是
    /// 「搜索非常不灵」的主因。改成按词比对后：
    ///   · 完全相同
    ///   · 前缀命中（token ≥3 字）：plan → planck、home → homework
    ///   · 复数/后缀回收（词 ≥4 字）：tasks → task
    /// 中文在 `words()` 里已被切成单字，所以这里同样适用（王/淑/娟 各自对齐）。
    private static func wordHit(_ tok: String, _ hay: [String]) -> Bool {
        if tok.isEmpty { return true }
        for w in hay {
            if w == tok { return true }
            if tok.count >= 3, w.hasPrefix(tok) { return true }
            if w.count >= 4, tok.hasPrefix(w) { return true }
        }
        return false
    }

    /// hay 的词序列里是否**连续**出现该短语（整串快路径用）
    private static func containsPhrase(_ hay: [String], _ phrase: [String]) -> Bool {
        guard !phrase.isEmpty, hay.count >= phrase.count else { return false }
        for i in 0...(hay.count - phrase.count) where Array(hay[i..<(i + phrase.count)]) == phrase {
            return true
        }
        return false
    }

    /// 全部 token 都命中才算命中（AND）；空查询恒真
    static func hit(_ q: Query, _ fields: [String?]) -> Bool {
        guard !q.isEmpty else { return true }
        let joined = fields.compactMap { $0 }.joined(separator: " \u{1}")
        let hay = canon(joined).split(separator: " ").map(String.init)
        // 整串先试一次（连续短语），再退到多词 AND
        if containsPhrase(hay, q.tokens) { return true }
        return q.tokens.allSatisfy { wordHit($0, hay) }
    }

    /// 可变参数版本，写起来顺手
    static func hit(_ q: Query, _ fields: String?...) -> Bool { hit(q, fields) }

    // MARK: - 排序

    /// 命中强度：把最相关的结果排前面（词级，标题命中权重最高）
    static func score(_ q: Query, title: String?, fields: [String?]) -> Int {
        guard !q.isEmpty else { return 0 }
        let t = canon(title ?? "").split(separator: " ").map(String.init)
        let hay = canon(fields.compactMap { $0 }.joined(separator: " "))
            .split(separator: " ").map(String.init)
        var s = 0
        for tok in q.tokens {
            if t.contains(tok) { s += 12 }
            else if tok.count >= 3, t.contains(where: { $0.hasPrefix(tok) }) { s += 8 }
            if hay.contains(tok) { s += 2 }
        }
        return s
    }

    // MARK: - 高亮

    struct Segment: Identifiable {
        let id = UUID()
        let text: String
        let highlighted: Bool
    }

    /// 在原文上按**用户原始输入**的词切段并标出命中区间。
    ///
    /// 这里故意不用统一后的 token：用户打 "english corner" 时，
    /// 我们要高亮原文里的 "English Corner"，而不是高亮替换后的 "ec"。
    static func segments(_ q: Query, _ text: String) -> [Segment] {
        guard !q.isEmpty, !text.isEmpty else {
            return [Segment(text: text, highlighted: false)]
        }
        let lower = norm(text)
        var needles: [String] = []
        for w in words(q.raw) where w.count >= 2 { needles.append(w) }
        // 别名展开也一起高亮
        for w in words(q.raw) {
            if let ex = groups[w] { needles += ex }
            for (k, list) in groups where list.contains(w) { needles.append(k) }
        }
        needles = Array(Set(needles.filter { $0.count >= 2 }))
        guard !needles.isEmpty else { return [Segment(text: text, highlighted: false)] }

        var ranges: [Range<Int>] = []
        for tok in needles {
            var start = lower.startIndex
            while let r = lower.range(of: tok, range: start..<lower.endIndex) {
                ranges.append(lower.distance(from: lower.startIndex, to: r.lowerBound)
                              ..< lower.distance(from: lower.startIndex, to: r.upperBound))
                start = r.upperBound
            }
        }
        guard !ranges.isEmpty else { return [Segment(text: text, highlighted: false)] }

        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else { merged.append(r) }
        }

        let chars = Array(text)
        var out: [Segment] = []
        var cursor = 0
        for r in merged {
            let a = min(r.lowerBound, chars.count), b = min(r.upperBound, chars.count)
            if a > cursor { out.append(Segment(text: String(chars[cursor..<a]), highlighted: false)) }
            if b > a { out.append(Segment(text: String(chars[a..<b]), highlighted: true)) }
            cursor = max(cursor, b)
        }
        if cursor < chars.count { out.append(Segment(text: String(chars[cursor...]), highlighted: false)) }
        return out.isEmpty ? [Segment(text: text, highlighted: false)] : out
    }
}
