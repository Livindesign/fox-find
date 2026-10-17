import Foundation
import OilFindCore

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
}

/// Conservative local grammar. Unrecognized text stays in the filename/content query.
enum NaturalSearch {
    private static let patterns: NSCache<NSString, NSRegularExpression> = { let cache = NSCache<NSString, NSRegularExpression>(); cache.countLimit = 64; return cache }()
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
        let pattern = temporal + ".{0,12}(?:拍摄|拍下|拍照|拍|修改|更新|创建|下载|照片|图片)|(?:拍摄|拍下|拍照|拍)于|(?:不要|不包含|不含|排除|除了|不是)|(?:大于|小于|超过|不少于|不超过)\\s*[0-9]"
        guard regex(pattern)?.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil else { return nil }
        return L10n.local("部分条件未识别，暂按文字查找；请用筛选菜单设置条件", "Some conditions were not understood. Searching literal text; use Filters to set conditions.")
    }
    static func parse(_ input: String, projects: [ProjectFolder] = [], home: String = NSHomeDirectory(), now: Date = Date(), timeZone: TimeZone = .current) -> NaturalSearchPlan? {
        guard input.utf8.count <= 2048, !input.contains(":"), !input.contains("/"),
              !input.contains("\""), !input.contains("“"), !input.contains("'") else { return nil }
        var remaining = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // Parse negation before positive comparisons, so "不超过10MB" cannot
        // accidentally become "超过10MB" after the matching words are removed.
        guard regex("(?:不要|不包含|不含|排除|除了|不是|不超过|不大于|不少于|不小于)")?.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) == nil else { return nil }
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
        if let capture = NaturalCaptureDate.match(remaining, now: now, timeZone: timeZone) {
            refinement.captured = capture.interval; labels.append(refinement.captureDescription)
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
        take("(?:文件)?(?:大小)?(?:大于|超过)\\s*([0-9]+(?:\\.[0-9]+)?)\\s*(KB|MB|GB|TB)(?:的)?") { groups in
            guard let value = Double(groups[1]), value.isFinite, value > 0, value < 1e9 else { return false }
            tokens.append("size:>" + groups[1] + groups[2].lowercased())
            labels.append(L10n.text("workspace.sizeOver", groups[1] + " " + groups[2].uppercased()))
            conditions.append(.init(token: tokens.last!, title: labels.last!)); return true
        }
        take("(宽度|高度)(?:大于|超过)\\s*([0-9]{1,6})(?:像素|px)?(?:的)?") { groups in
            guard let value = Int(groups[2]), value > 0 else { return false }
            if groups[1] == "宽度" { refinement.minWidth = value + 1 }
            else { refinement.minHeight = value + 1 }
            labels.append(L10n.text(groups[1] == "宽度" ? "workspace.widthOver" : "workspace.heightOver", groups[2])); return true
        }
        // Reject partial interpretation of unsupported constraints (for example a range
        // ending in a valid month, or "不要照片"). Never silently relax them.
        guard unresolvedConstraint(remaining) == nil else { return nil }
        take("(?:所有|全部)(?:的)?(?=PDF|图片|照片|相片|视频|音频|文档|文件夹|应用)") { _ in labels.append(L10n.text("workspace.all")); return true }
        if remaining.range(of: "\\.[a-zA-Z0-9]{1,8}\\s*$", options: .regularExpression) == nil {
            take("(?:的)?\\s*(PDF|图片|照片|相片|视频|音频|文档|文件夹|应用)(?:文件)?\\s*$") { groups in
                let kinds = ["图片": "image", "照片": "image", "相片": "image", "视频": "video", "音频": "audio", "文档": "doc", "文件夹": "folder", "应用": "app"]
                tokens.append(groups[1].uppercased() == "PDF" ? "ext:pdf" : "kind:" + (kinds[groups[1]] ?? "doc"))
                labels.append(groups[1]); conditions.append(.init(token: tokens.last!, title: groups[1])); return true
            }
        }
        guard !labels.isEmpty else { return nil }
        remaining = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        // Separators left solely between recognized conditions are not filename keywords.
        // Keep mixed residual text (for example C++ notes) literal.
        if remaining.allSatisfy({ $0.isWhitespace || "+＋，,".contains($0) }) { remaining = "" }
        remaining = remaining.replacingOccurrences(of: "^(?:帮我)?(?:查找|搜索|找)\\s*", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { tokens.insert(remaining, at: 0) }
        return NaturalSearchPlan(query: tokens.isEmpty ? "*" : tokens.joined(separator: " "), folder: folder, refinement: refinement, explanation: labels.joined(separator: " · "), conditions: conditions, filtersOnly: remaining.isEmpty)
    }
}
