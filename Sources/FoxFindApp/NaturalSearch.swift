import Foundation
import FoxFindCore

struct NaturalQueryCondition: Equatable {
    var token: String
    var title: String
}

struct NaturalSearchPlan: Equatable {
    var query: String
    var folder: String?
    var refinement = AssetRefinement()
    var explanation: String
    var conditions: [NaturalQueryCondition] = []
    var filtersOnly = false
    var warning: String? = nil
}

/// Conservative local grammar. Unrecognized text stays in the filename/content query.
enum NaturalSearch {
    private static let patterns: NSCache<NSString, NSRegularExpression> = { let cache = NSCache<NSString, NSRegularExpression>(); cache.countLimit = 128; return cache }()
    static func regex(_ pattern: String) -> NSRegularExpression? {
        if let cached = patterns.object(forKey: pattern as NSString) { return cached }
        guard let value = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        patterns.setObject(value, forKey: pattern as NSString); return value
    }
    /// Do not turn an unparsed date, comparison or exclusion into approximate matches.
    /// Literal filename/content search remains available and the UI explains the limitation.
    static func unresolvedConstraint(_ input: String) -> String? {
        guard input.utf8.count <= 2048, !input.contains("\""), !input.contains("/"),
              input.range(of: "\\.[a-zA-Z0-9]{1,8}$", options: .regularExpression) == nil else { return nil }
        let temporal = "(?:[0-9一二三四五六七八九十]+[年月日天周]|今天|昨天|前天|本周|这周|上周|本月|上月|上个月|今年|去年|前年|最近|近期)"
        let pattern = temporal + "|[0-9]+(?:\\.[0-9]+)?\\s*(?:至|到|[-~～])\\s*[0-9]+(?:\\.[0-9]+)?\\s*(?:TB|GB|MB|KB|B)|" + temporal + ".{0,12}(?:拍摄|拍下|拍照|拍|修改|更新|创建|下载|照片|图片)|(?:拍摄|拍下|拍照|拍)于|(?:不要|不包含|不含|排除|除了|不是)|(?:大于|小于|超过|不少于|不超过|不大于|不小于|至少|最多)\\s*[0-9]"
        guard regex(pattern)?.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil else { return nil }
        return L10n.local("部分条件未识别，暂按文字查找；请用筛选菜单设置条件", "Some conditions were not understood. Searching literal text; use Filters to set conditions.")
    }
    static func parse(_ input: String, projects: [ProjectFolder] = [], home: String = NSHomeDirectory(), now: Date = Date(), timeZone: TimeZone = .current) -> NaturalSearchPlan? {
        guard input.utf8.count <= 2048 else { return nil }
        // A terminal decimal size (图片不超过1.5MB) is not a file extension.
        let decimalSize = regex("(?:不超过|不大于|最多|至多|不少于|不小于|至少|大于|超过|小于|低于|等于|>=|<=|>|<|=|至|到|[-~～])\\s*[0-9]+\\.[0-9]+\\s*(?:TB|GB|MB|KB|B)\\s*$")?.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
        guard !input.contains(":"), !input.contains("/"),
              !input.contains("\""), !input.contains("“"), !input.contains("'"), !input.contains(where: { "*!?|".contains($0) }),
              (decimalSize || input.range(of: "\\.[a-zA-Z0-9]{1,8}\\s*$", options: .regularExpression) == nil) else { return nil }
        let normalized = String(String.UnicodeScalarView(input.unicodeScalars.map { scalar in
            (0xFF10...0xFF19).contains(scalar.value) ? UnicodeScalar(scalar.value - 0xFEE0)! : scalar
        }))
        var remaining = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        // A negated date needs a date-set complement. Do not accidentally parse it
        // as a positive capture constraint while that grammar is unsupported.
        if regex("(?:不要|排除|不是)\\s*(?:[0-9一二三四五六七八九十]+月|今天|昨天|今年|去年)")?.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) != nil { return nil }
        var tokens: [String] = [], labels: [String] = [], folder: String?
        var refinement = AssetRefinement()
        var conditions: [NaturalQueryCondition] = []
        func take(_ pattern: String, _ consume: ([String]) -> Bool) {
            guard let regex = regex(pattern),
                  let match = regex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) else { return }
            let ns = remaining as NSString
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            if consume(groups) { remaining = ns.replacingCharacters(in: match.range, with: " ") }
        }
        func add(_ token: String, _ title: String) {
            tokens.append(token); labels.append(title); conditions.append(.init(token: token, title: title))
        }
        // Consume explicit exclusions before types and positive comparisons.
        for _ in 0..<12 {
            let before = remaining
            take("(?:不要|排除|不是)\\s*((?:" + NaturalQueryRules.types + ")(?:文件)?(?:\\s*(?:或者|或|和|、)\\s*(?:" + NaturalQueryRules.types + ")(?:文件)?)*)($|(?=[，,；;\\s]))") { g in
                add(NaturalQueryRules.typeTokens(g[1]).map { "!" + $0 }.joined(separator: " "), L10n.local("排除类型：", "Exclude types: ") + g[1]); return true
            }
            take("(?:不要|不包含|不含|排除)(?:包含)?\\s*([\\p{L}\\p{N}_-]+?)(?=(?:的)?(?:" + NaturalQueryRules.types + ")(?:文件)?(?:$|[，,；;\\s])|$|[，,；;\\s])") { g in
                // Quoted and punctuation-bearing names are left to explicit query syntax.
                let words = g[1].components(separatedBy: CharacterSet(charactersIn: "和或、")).filter { !$0.isEmpty }
                guard !words.isEmpty else { return false }
                for word in words {
                    let negatives = word == "微信" ? NaturalQueryRules.wechat.map { "!" + $0 } : ["!" + word]
                    add(negatives.joined(separator: " "), L10n.local(word == "微信" ? "排除路径：" : "排除文字：", word == "微信" ? "Exclude path: " : "Exclude text: ") + word)
                }
                return true
            }
            if remaining == before { break }
        }
        // Longest operators first: “不超过” must never become “超过”.
        let amount = "([0-9]+(?:\\.[0-9]+)?)\\s*(TB|GB|MB|KB|B)"
        take("(?:文件)?(?:大小)?(?:在)?\\s*" + amount + "\\s*(?:至|到|[-~～])\\s*" + amount + "(?:之间|以内)?(?:的)?") { g in
            let token = "size:" + g[1] + g[2].lowercased() + ".." + g[3] + g[4].lowercased()
            guard Query.parse(token).diagnostics.isEmpty else { return false }
            add(token, L10n.local("大小：", "Size: ") + g[1] + g[2].uppercased() + "–" + g[3] + g[4].uppercased()); return true
        }
        // A shared unit (“1到10MB”) is common when typing quickly.
        take("(?:文件)?(?:大小)?(?:在)?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(?:至|到|[-~～])\\s*" + amount + "(?:之间|以内)?(?:的)?") { g in
            let token = "size:" + g[1] + g[3].lowercased() + ".." + g[2] + g[3].lowercased()
            guard Query.parse(token).diagnostics.isEmpty else { return false }
            add(token, L10n.local("大小：", "Size: ") + g[1] + "–" + g[2] + g[3].uppercased()); return true
        }
        for _ in 0..<4 {
            let before = remaining
            take("(?:文件)?(?:大小)?(不超过|不大于|最多|至多|不少于|不小于|至少|大于|超过|小于|低于|等于|>=|<=|>|<|=)\\s*" + amount + "(?:的)?") { g in
                let operators = ["不超过": "<=", "不大于": "<=", "最多": "<=", "至多": "<=", "不少于": ">=", "不小于": ">=", "至少": ">=", "大于": ">", "超过": ">", "小于": "<", "低于": "<", "等于": "", "=": ""]
                let comparison = operators[g[1]] ?? g[1]
                let token = "size:" + comparison + g[2] + g[3].lowercased()
                guard Query.parse(token).diagnostics.isEmpty else { return false }
                add(token, L10n.local("大小：", "Size: ") + (comparison.isEmpty ? "=" : comparison) + g[2] + g[3].uppercased()); return true
            }
            if remaining == before { break }
        }
        take(amount + "\\s*(以内|以下|以上)(?:的)?") { g in
            let token = "size:" + (g[3] == "以上" ? ">=" : "<=") + g[1] + g[2].lowercased()
            guard Query.parse(token).diagnostics.isEmpty else { return false }
            add(token, L10n.local("大小：", "Size: ") + g[1] + g[2].uppercased() + g[3]); return true
        }
        let scopes = [("下载", "Downloads"), ("桌面", "Desktop"), ("文稿", "Documents"), ("图片文件夹", "Pictures")]
            .map { ($0.0, (home as NSString).appendingPathComponent($0.1)) } + projects.map { ($0.name, $0.path) }
        for (name, path) in scopes.sorted(by: { $0.0.count > $1.0.count }) where folder == nil {
            let baseName = name == "图片文件夹" ? "图片" : name
            let escaped = NSRegularExpression.escapedPattern(for: baseName)
            take("(?:在)?" + escaped + "(?:文件夹|目录)?(?:里面|之内|中|里|内|下)(?:的)?") { _ in
                folder = path; labels.append(name); return true
            }
            if folder == nil {
                take("^(?:找|查找|搜索)?\\s*(?:在)?" + escaped + "(?:文件夹|目录)(?:的)?(?=[\\s+＋，,]*(?:[0-9一二三四五六七八九十]|最近|近|今天|昨天|前天|今年|去年|前年|本月|上月|上个月|本周|这周|上周|拍摄|宽度|高度|大小|大于|超过|PDF|图片|照片|相片|视频|音频|文档|应用))") { _ in
                    folder = path; labels.append(name); return true
                }
            }
        }
        var hasModifiedRange = false
        if let range = NaturalQueryRules.modifiedRange(remaining, now: now, timeZone: timeZone) {
            add(range.token, range.title); hasModifiedRange = true
            remaining = (remaining as NSString).replacingCharacters(in: range.range, with: " ")
        }
        let dateParts = regex("[0-9一二三四五六七八九十]+月")?.numberOfMatches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) ?? 0
        if dateParts <= 1, let capture = NaturalCaptureDate.match(remaining, now: now, timeZone: timeZone) {
            refinement.captured = capture.interval; refinement.captureMonth = capture.month
            labels.append(refinement.captureDescription)
            remaining = (remaining as NSString).replacingCharacters(in: capture.range, with: " ")
        }
        take("(?:最近|近)\\s*([0-9]{1,4})\\s*天(?:内)?(?:修改|更新)(?:过)?(?:的)?") { groups in
            guard let days = Int(groups[1]), (1...3650).contains(days) else { return false }
            tokens.append("dm:\(days)d")
            let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"
            labels.append(L10n.text("workspace.modifiedRange", formatter.string(from: now.addingTimeInterval(-Double(days) * 86400)), formatter.string(from: now)))
            conditions.append(.init(token: tokens.last!, title: labels.last!))
            return true
        }
        take("(今天|昨天)(?:修改|更新)(?:过)?(?:的)?") { groups in
            tokens.append("dm:" + (groups[1] == "今天" ? "today" : "yesterday"))
            let cal = Calendar.current, day = cal.date(byAdding: .day, value: groups[1] == "今天" ? 0 : -1, to: now) ?? now
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
            labels.append(L10n.text("workspace.modifiedDay", formatter.string(from: day)))
            conditions.append(.init(token: tokens.last!, title: labels.last!)); return true
        }
        if !refinement.hasCaptureFilter && !hasModifiedRange && dateParts <= 1 {
            // Bare date + file type uses the already indexed modification date.
            // Never infer EXIF/creation/download dates from file modification time.
            let hasType = regex("(?:" + NaturalQueryRules.types + ")(?:文件)?")?.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) != nil
            let unsupportedTime = regex("(?:拍摄|拍下|拍照|拍|创建|下载|接收|保存|之前|之后|以前|以后|截至|起至)")?.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) != nil
            let explicit = NaturalCaptureDate.match(remaining, now: now, timeZone: timeZone, verb: "(?:修改|更新)(?:过)?")
            let implicit = hasType && !unsupportedTime ? NaturalCaptureDate.match(remaining, now: now, timeZone: timeZone, verb: "") : nil
            if let date = explicit ?? implicit {
                let token: String, title: String
                if let month = date.month {
                    token = "dm:month\(month)"
                    title = L10n.local("修改时间：所有年份的 \(month) 月", "Modified in month \(month) · All years")
                } else if let interval = date.interval {
                    let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
                    let start = f.string(from: interval.start), end = f.string(from: interval.end.addingTimeInterval(-1))
                    token = "dm:" + start + (start == end ? "" : ".." + end)
                    title = L10n.local("修改时间：", "Modified: ") + start + (start == end ? "" : "–" + end)
                } else { return nil }
                tokens.append(token); labels.append(title); conditions.append(.init(token: token, title: title))
                remaining = (remaining as NSString).replacingCharacters(in: date.range, with: " ")
            }
        }
        take("(宽度|高度)(?:大于|超过)\\s*([0-9]{1,6})(?:像素|px)?(?:的)?") { groups in
            guard let value = Int(groups[2]), value > 0 else { return false }
            if groups[1] == "宽度" { refinement.minWidth = value + 1 }
            else { refinement.minHeight = value + 1 }
            labels.append(L10n.text(groups[1] == "宽度" ? "workspace.widthOver" : "workspace.heightOver", groups[2])); return true
        }
        // Types can precede or follow other constraints; alternatives form one OR
        // clause, while size/date/source/exclusion clauses are still ANDed.
        take("(?:所有|全部)(?:的)?(?=" + NaturalQueryRules.types + ")") { _ in labels.append(L10n.text("workspace.all")); return true }
        take("(?:的)?\\s*((?:" + NaturalQueryRules.types + ")(?:文件)?(?:\\s*(?:或者|或|和|、)\\s*(?:" + NaturalQueryRules.types + ")(?:文件)?)*)(?=$|[，,；;\\s])") { g in
            let choices = NaturalQueryRules.typeTokens(g[1])
            guard !choices.isEmpty else { return false }
            add(choices.joined(separator: "|"), g[1]); return true
        }
        take("(?:来自|来源于|来源是|从)?\\s*(微信|WeChat|Weixin)(?:中|里)?(?:的)?") { _ in
            add(NaturalQueryRules.wechat.joined(separator: "|"), L10n.local("微信：文件名或路径", "WeChat in name or path")); return true
        }
        if tokens.contains(where: { $0.contains("kind:image") || $0.hasPrefix("ext:png") || $0.hasPrefix("ext:jpg") || $0.hasPrefix("ext:heic") }) {
            take("(横向|横版|横图|竖向|竖版|竖图|正方形|方图)(?:的)?") { g in
                refinement.media = ["横向", "横版", "横图"].contains(g[1]) ? .landscape : (["竖向", "竖版", "竖图"].contains(g[1]) ? .portrait : .square)
                labels.append(refinement.media.title); return true
            }
        }
        take("(?:标签为|标签是|带标签)\\s*([\\p{L}\\p{N}_-]+?)(?=的|$|[，,；;\\s])(?:的)?") { g in
            refinement.tag = g[1]; labels.append(g[1]); return true
        }
        guard !labels.isEmpty else { return nil }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        let unresolved = unresolvedConstraint(remaining)
        let warning = unresolved == nil ? nil : L10n.local("已应用识别出的条件；其余内容仍按文字查找，尚未完整理解这句话", "Recognized filters applied; remaining text is searched literally. This query was not fully understood.")
        // Separators left solely between recognized conditions are not filename keywords.
        // Keep mixed residual text (for example C++ notes) literal.
        if remaining.allSatisfy({ $0.isWhitespace || "+＋，,；;的且并".contains($0) }) { remaining = "" }
        remaining = remaining.replacingOccurrences(of: "^(?:帮我)?(?:查找|搜索|找)\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        remaining = remaining.replacingOccurrences(of: "[，,；;]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tokens.insert(remaining, at: 0) }
        return NaturalSearchPlan(query: tokens.isEmpty ? "*" : tokens.joined(separator: " "), folder: folder, refinement: refinement, explanation: labels.joined(separator: " · "), conditions: conditions, filtersOnly: remaining.isEmpty, warning: warning)
    }
}
