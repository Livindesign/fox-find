import Foundation

/// Small, deterministic rules produce the same indexed predicates as manual filters.
/// A source name is evidence in a filename/path, not a claim about download history.
enum NaturalQueryRules {
    static let types = "电子表格|演示文稿|压缩文件|文件夹|应用程序|图片|照片|相片|视频|音频|文档|应用|表格|幻灯片|压缩包|代码|PDF|PNG|JPG|JPEG|HEIC|GIF|DOCX|XLSX|PPTX"
    static func typeToken(_ name: String) -> String {
        let kinds = ["图片": "image", "照片": "image", "相片": "image", "视频": "video", "音频": "audio", "文档": "doc", "文件夹": "folder", "应用": "app", "应用程序": "app", "代码": "code", "压缩包": "archive", "压缩文件": "archive"]
        if let kind = kinds[name] { return "kind:" + kind }
        switch name {
        case "电子表格", "表格": return "ext:xls;xlsx;csv;numbers;ods"
        case "演示文稿", "幻灯片": return "ext:ppt;pptx;key;odp"
        default: return "ext:" + name.lowercased()
        }
    }
    static let wechat = ["path:微信", "path:wechat", "path:weixin"]
    static func isPositiveType(_ token: String) -> Bool {
        token.split(separator: "|").allSatisfy { $0.hasPrefix("kind:") || $0.hasPrefix("ext:") }
    }
    static func typeTokens(_ text: String) -> [String] {
        guard let regex = NaturalSearch.regex(types) else { return [] }
        let ns = text as NSString
        var result: [String] = []
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = typeToken(ns.substring(with: match.range))
            if !result.contains(token) { result.append(token) }
        }
        return result
    }
    static func modifiedRange(_ text: String, now: Date, timeZone: TimeZone) -> (range: NSRange, token: String, title: String)? {
        // Capture ranges need EXIF; never substitute the indexed modification date.
        guard !text.contains("拍"), !text.contains("创建"), !text.contains("下载"), !text.contains("接收"), !text.contains("保存") else { return nil }
        let endpoint = "(?:(?:今年|去年|前年|[0-9]{4}年)\\s*)?(?:[0-9]{1,2}|[一二三四五六七八九十]{1,3})月(?:份)?(?:[0-9]{1,2}[日号])?"
        let pattern = "(?<![0-9年月日号至到一二三四五六七八九十])(" + endpoint + ")\\s*(至|到|或|和|、|-)\\s*(" + endpoint + ")(?:修改|更新)?(?:的)?"
        guard let match = NaturalSearch.regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let ns = text as NSString, first = ns.substring(with: match.range(at: 1)), separator = ns.substring(with: match.range(at: 2))
        var second = ns.substring(with: match.range(at: 3))
        let isRange = ["至", "到", "-"].contains(separator)
        if isRange, let year = NaturalSearch.regex("^(今年|去年|前年|[0-9]{4}年)")?.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
           NaturalSearch.regex("^(今年|去年|前年|[0-9]{4}年)")?.firstMatch(in: second, range: NSRange(second.startIndex..., in: second)) == nil {
            second = (first as NSString).substring(with: year.range) + second
        }
        guard let a = NaturalCaptureDate.match(first, now: now, timeZone: timeZone, verb: ""), a.range.length == first.utf16.count,
              let b = NaturalCaptureDate.match(second, now: now, timeZone: timeZone, verb: ""), b.range.length == second.utf16.count else { return nil }
        let token: String
        if let am = a.month, let bm = b.month {
            // November–February is a recurring span across the year boundary.
            let months = isRange ? (am <= bm ? Array(am...bm) : Array(am...12) + Array(1...bm)) : [am, bm]
            token = months.enumerated().filter { index, month in !months.prefix(index).contains(month) }.map(\.element).map { "dm:month\($0)" }.joined(separator: "|")
        } else if let ai = a.interval, let bi = b.interval {
            let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
            func intervalToken(_ value: DateInterval) -> String {
                "dm:" + formatter.string(from: value.start) + ".." + formatter.string(from: value.end.addingTimeInterval(-1))
            }
            if isRange {
                guard ai.start < bi.end else { return nil }
                token = intervalToken(DateInterval(start: ai.start, end: bi.end))
            } else { token = intervalToken(ai) + "|" + intervalToken(bi) }
        } else { return nil }
        return (match.range, token, L10n.local("修改时间：", "Modified: ") + ns.substring(with: match.range).replacingOccurrences(of: "(?:修改|更新)?的$", with: "", options: .regularExpression))
    }
}
