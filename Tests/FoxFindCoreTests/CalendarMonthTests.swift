import XCTest
@testable import FoxFindCore

final class CalendarMonthTests: XCTestCase {
    private func fixture(_ stamps: [UInt32], kinds: [UInt8]? = nil) -> IndexStore {
        let count = stamps.count + 1, name = Array("sample.jpg".utf8)
        let store = IndexStore(rootPath: "/synthetic-month", count: count, namesLen: name.count * stamps.count,
                               altCount: 0, altLen: 0, fingerprint: 0, homeIndex: .max, finishedAt: 0)
        store.nameOff[0] = 0; store.parent[0] = 0; store.flags[0] = SiftFlag.dir
        store.depth[0] = 0; store.kind[0] = 1; store.sizeC[0] = 0; store.mtime[0] = 0; store.altOff[0] = 0
        for (i, stamp) in stamps.enumerated() {
            let id = i + 1, offset = i * name.count
            store.nameOff[id] = UInt32(offset)
            name.withUnsafeBufferPointer { store.names.advanced(by: offset).update(from: $0.baseAddress!, count: name.count) }
            store.parent[id] = 0; store.depth[id] = 1; store.kind[id] = kinds?[i] ?? 4
            store.sizeC[id] = IndexStore.encodeSize(2048); store.mtime[id] = stamp; store.flags[id] = SiftFlag.userArea
        }
        store.nameOff[count] = UInt32(name.count * stamps.count)
        return store
    }
    func testRecurringMonthMatchesCalendarAcrossYearsTimeZonesAndBoundaries() throws {
        var stamps: [UInt32] = [0, 1, .max]
        var seed: UInt64 = 137
        for _ in 0..<2000 { seed = seed &* 6364136223846793005 &+ 1; stamps.append(UInt32(truncatingIfNeeded: seed >> 16)) }
        let iso = ISO8601DateFormatter()
        for value in ["2024-02-29T23:59:59Z", "2026-07-31T15:59:59Z", "2026-07-31T16:00:00Z", "2026-08-31T15:59:59Z", "2026-08-31T16:00:00Z"] {
            stamps.append(UInt32(try XCTUnwrap(iso.date(from: value)).timeIntervalSince1970))
        }
        let store = fixture(stamps)
        for identifier in ["Asia/Shanghai", "America/Los_Angeles", "Pacific/Kiritimati", "UTC"] {
            let zone = try XCTUnwrap(TimeZone(identifier: identifier))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            for month in 1...12 {
                let query = Query.parse("kind:image dm:month\(month)", timeZone: zone)
                let result = try XCTUnwrap(Searcher.search(query, in: store))
                let expected = Set(stamps.enumerated().filter { $0.element > 0 && calendar.component(.month, from: Date(timeIntervalSince1970: Double($0.element))) == month }.map { UInt32($0.offset + 1) })
                XCTAssertEqual(Set(result.items), expected, "\(identifier) \(month)")
            }
        }
    }
    func testModifiedMonthRejectsInvalidValuesAndKeepsExistingMonthSyntax() throws {
        for value in ["month0", "month13", "month-1", "month99999999999999999999", "monthx"] {
            XCTAssertFalse(Query.parse("dm:" + value).diagnostics.isEmpty, value)
        }
        let current = Query.parse("dm:month")
        XCTAssertTrue(current.diagnostics.isEmpty)
        guard case .modified = current.clauses.first?.alternatives.first?.matcher else { return XCTFail("Existing month syntax changed") }
        let august = UInt32(ISO8601DateFormatter().date(from: "2025-08-12T00:00:00Z")!.timeIntervalSince1970)
        let july = august - 31 * 86400
        let store = fixture([august, august, july, 0], kinds: [4, 3, 4, 4])
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(Searcher.search(Query.parse("kind:image dm:month8", timeZone: zone), in: store)?.items, [1])
        XCTAssertEqual(Set(try XCTUnwrap(Searcher.search(Query.parse("kind:image !dm:month8", timeZone: zone), in: store)).items), [3, 4])
    }
    func testSizeBoundaryOperatorsAndDateTimeZoneAreExact() throws {
        for (raw, lower, upper) in [("<=10mb", UInt64(0), UInt64(10_000_000)), (">=1.5gb", 1_500_000_000, UInt64.max), ("1mb..2mb", 1_000_000, 2_000_000), ("<1tb", 0, 999_999_999_999), ("0b", 0, 0)] {
            let query = Query.parse("size:" + raw)
            XCTAssertTrue(query.diagnostics.isEmpty)
            guard case .size(let range) = query.clauses.first?.alternatives.first?.matcher else { return XCTFail(raw) }
            XCTAssertEqual(range, lower...upper)
        }
        for raw in ["size:10mb..1mb", "size:<=-1", "size:>=nan", "size:1e30tb"] { XCTAssertFalse(Query.parse(raw).diagnostics.isEmpty, raw) }
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let query = Query.parse("dm:2026-03-08", timeZone: zone)
        guard case .modified(let range) = query.clauses.first?.alternatives.first?.matcher else { return XCTFail("Missing date predicate") }
        XCTAssertEqual(range.upperBound - range.lowerBound + 1, 23 * 3600)
        XCTAssertEqual(range.lowerBound, UInt32(ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")!.timeIntervalSince1970))
    }
    func testMillionEntryIndexedMonthBenchmark() throws {
        guard ProcessInfo.processInfo.environment["FOX_FIND_MONTH_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in release benchmark") }
        let iso = ISO8601DateFormatter(), zone = TimeZone(secondsFromGMT: 0)!
        let dates = (1...12).map { UInt32(iso.date(from: String(format: "2025-%02d-15T12:00:00Z", $0))!.timeIntervalSince1970) }
        let count = 1_000_000
        let stamps = (0..<count).map { dates[$0 % 12] }, kinds: [UInt8] = (0..<count).map { $0 % 5 == 0 ? 3 : 4 }
        let store = fixture(stamps, kinds: kinds), query = Query.parse("kind:image dm:month8", timeZone: zone)
        let expected = (0..<count).filter { $0 % 12 == 7 && $0 % 5 != 0 }.count
        var samples: [Double] = []
        for _ in 0..<8 {
            let started = Date(), result = try XCTUnwrap(Searcher.search(query, in: store))
            samples.append(Date().timeIntervalSince(started) * 1000)
            XCTAssertEqual(result.total, expected)
        }
        samples.sort()
        print("MONTH_INDEX entries=\(count) matches=\(expected) median_ms=\(samples[4]) max_ms=\(samples.last!) disk_reads=0")
    }
}
