import Foundation

/// Calendar constraints are resolved locally, never by embedding similarity.
enum NaturalCaptureDate {
    struct Match { let range: NSRange; let interval: DateInterval?; var month: Int? = nil }
    static func match(_ text: String, now: Date, timeZone: TimeZone, verb: String = "(?:拍摄|拍下|拍照|拍)(?:过)?") -> Match? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        func resolve(_ pattern: String, recurringMonth: Bool = false, _ interval: ([String]) -> DateInterval?) -> Match? {
            guard let match = NaturalSearch.regex(pattern)?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let ns = text as NSString
            let groups = (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
            guard let dates = interval(groups) else { return nil }
            if recurringMonth && groups[1].isEmpty && groups[3].isEmpty {
                return Match(range: match.range, interval: nil, month: calendar.component(.month, from: dates.start))
            }
            return Match(range: match.range, interval: dates)
        }
        if let result = resolve("(?:最近|近)\\s*([0-9]{1,4})\\s*(天|周|个月|月)(?:内)?\\s*(?:的)?" + verb + "(?:的)?", { g in
            guard let n = Int(g[1]), n > 0 else { return nil }
            let start: Date?
            switch g[2] {
            case "天": start = n <= 3650 ? now.addingTimeInterval(-Double(n) * 86400) : nil
            case "周": start = n <= 520 ? calendar.date(byAdding: .day, value: -n * 7, to: now) : nil
            default: start = n <= 120 ? calendar.date(byAdding: .month, value: -n, to: now) : nil
            }
            return start.map { DateInterval(start: $0, end: now) }
        }) { return result }
        let relativeBoundary = verb.isEmpty ? "(?!\\s*[0-9一二三四五六七八九十]+月)" : ""
        if let result = resolve("(今天|昨天|前天|本周|这周|上周|本月|这个月|上个月|上月|今年|去年|前年)" + relativeBoundary + "\\s*(?:的)?" + verb + "(?:的)?", { g in
            let component: Calendar.Component, offset: Int
            switch g[1] {
            case "今天": component = .day; offset = 0
            case "昨天": component = .day; offset = -1
            case "前天": component = .day; offset = -2
            case "本周", "这周": component = .weekOfYear; offset = 0
            case "上周": component = .weekOfYear; offset = -1
            case "本月", "这个月": component = .month; offset = 0
            case "上个月", "上月": component = .month; offset = -1
            case "今年": component = .year; offset = 0
            case "去年": component = .year; offset = -1
            default: component = .year; offset = -2
            }
            guard let date = calendar.date(byAdding: component, value: offset, to: now) else { return nil }
            return calendar.dateInterval(of: component, for: date)
        }) { return result }
        // A bare month spans all years; explicit years retain exact calendar boundaries.
        let date = "(?:(今年|去年|前年|[0-9]{4}年)\\s*)?([0-9]{1,2}|[一二三四五六七八九十]{1,3})月(?:份)?(?:\\s*([0-9]{1,2})[日号])?"
        func dates(_ g: [String]) -> DateInterval? {
            let currentYear = calendar.component(.year, from: now)
            let year: Int
            switch g[1] {
            case "", "今年": year = currentYear
            case "去年": year = currentYear - 1
            case "前年": year = currentYear - 2
            default: guard let value = Int(g[1].dropLast()), (1900...9998).contains(value) else { return nil }; year = value
            }
            let chinese = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12]
            guard let month = Int(g[2]) ?? chinese[g[2]], (1...12).contains(month) else { return nil }
            let day = g[3].isEmpty ? 1 : (Int(g[3]) ?? 0)
            guard (1...31).contains(day), let start = calendar.date(from: DateComponents(year: year, month: month, day: day)),
                  calendar.component(.month, from: start) == month, calendar.component(.day, from: start) == day else { return nil }
            return calendar.dateInterval(of: g[3].isEmpty ? .month : .day, for: start)
        }
        let boundary = "(?<![0-9年月日号至到一二三四五六七八九十])"
        if let result = resolve(boundary + date + "\\s*(?:的)?" + verb + "(?:的)?", recurringMonth: true, dates) { return result }
        return resolve(verb + "于\\s*" + date + "(?:的)?", recurringMonth: true, dates)
    }
}
