import Foundation
import XCTest
@testable import FoxFindCore

final class PublicSearchBenchmarkTests: XCTestCase {
    func testSyntheticFilenameSearch() throws {
        guard ProcessInfo.processInfo.environment["FOX_SEARCH_BENCHMARK"] == "1" else { throw XCTSkip("Opt-in public synthetic search benchmark") }
        let count = 300_001
        var b = ScanBuffer()
        b.ids = (0..<count).map(UInt32.init); b.parents = Array(repeating: 0, count: count)
        b.sizes = Array(repeating: 4096, count: count); b.mtimes = Array(repeating: 1_790_000_000, count: count)
        b.flags = Array(repeating: 128, count: count); b.depths = Array(repeating: 1, count: count)
        b.kinds = Array(repeating: 3, count: count); b.flags[0] = 1; b.kinds[0] = 1
        let prefixes = ["Product plan", "产品规划", "Image", "README", "Meeting notes", "Budget"]
        let extensions = ["pdf", "docx", "jpg", "md", "txt", "xlsx"]
        for i in 0..<count {
            let name = i == 0 ? "" : String(format: "%@-%06d.%@", prefixes[i % 6], i, extensions[i % 6])
            b.nameLens.append(UInt32(name.utf8.count)); b.nameBytes.append(contentsOf: name.utf8)
            if i % 6 == 2 { b.kinds[i] = 4 }
        }
        let store = IndexStore(scan: ScanOutput(buffers: [b], count: count, homeIndex: .max, elapsed: 0, finishedAt: 0), config: IndexConfig(rootPath: "/FoxFindSyntheticBenchmark"))
        _ = Pinyin.shared
        let queue = DispatchQueue(label: "foxfind.public-benchmark", qos: .userInteractive)
        var rows: [[String: Any]] = []
        for text in ["Product", "产品", "ext:pdf", "kind:image", "README-000003", "not-a-real-file"] {
            let query = Query.parse(text, home: "/Demo", store: store)
            _ = queue.sync { Searcher.search(query, in: store) }
            var samples: [Double] = [], matches = 0
            for _ in 0..<60 {
                let start = CFAbsoluteTimeGetCurrent()
                let result = try XCTUnwrap(queue.sync { Searcher.search(query, in: store) })
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000); matches = result.total
            }
            samples.sort()
            rows.append(["query": text, "matches": matches, "p50_ms": samples[29], "p95_ms": samples[56]])
        }
        let report: [String: Any] = ["entries": count - 1, "runs_per_query": 60, "configuration": "debug", "index": "memory-resident synthetic filenames", "queries": rows]
        print("FOX_SEARCH_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }
}
