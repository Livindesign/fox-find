import Foundation

/// Month-of-year matching against the existing timestamp index. Calendar work is
/// done once per query, never once per file; the hot loop binary-searches bounds.
public struct CalendarMonthFilter {
    public let month: Int
    let bounds: [UInt64]

    public init?(month: Int, timeZone: TimeZone = .current) {
        guard (1...12).contains(month) else { return nil }
        self.month = month
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let ceiling = Double(UInt32.max) + 1
        var values: [UInt64] = []
        // Index timestamps are UInt32 Unix seconds. Include boundary years for
        // positive/negative timezone offsets; unknown timestamp zero is excluded.
        for year in 1969...2106 {
            guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let end = calendar.date(byAdding: .month, value: 1, to: start) else { continue }
            let lower = max(1, start.timeIntervalSince1970), upper = min(ceiling, end.timeIntervalSince1970)
            if lower < upper { values += [UInt64(lower), UInt64(upper)] }
        }
        bounds = values
    }
}
