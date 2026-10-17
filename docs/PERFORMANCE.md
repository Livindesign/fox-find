# Performance / 性能实测

Fox Find 0.8.6 build 26 · 2026-10-17 · Apple M1 Pro, 16 GB · macOS 27.0.1 · Swift 6.2.3 · Debug.

固定合成数据，不扫描用户目录。下列数字表示指定测试的处理耗时，并不代表所有文件、所有设备或每次查询的速度。
These fixed synthetic workloads do not scan user folders. Results describe this device and these workloads, not every file, device or query.

## Filename search / 文件名搜索

300,000 filenames split evenly across six document/image categories. The index is already in memory; pinyin initialization and one warm-up query are excluded. Each query runs 60 times without a result cache. Timing covers the complete search call on a serial background queue, including dispatch overhead. Query results are materialized, not just counted.

| Query | Matches | Median | P95 |
| --- | ---: | ---: | ---: |
| `Product` | 50,000 | 28.35 ms | 30.39 ms |
| `产品` | 50,000 | 29.21 ms | 33.27 ms |
| `ext:pdf` | 50,000 | 125.56 ms | 133.80 ms |
| `kind:image` | 50,000 | 26.57 ms | 28.21 ms |
| `README-000003` | 1 | 8.20 ms | 8.26 ms |
| `not-a-real-file` | 0 | 8.08 ms | 8.36 ms |

Includes only indexed filename search. Initial disk scanning, index loading, UI debounce/presentation, OCR extraction and semantic inference are outside this measurement. 文件名查询中，返回大量结果的筛选耗时明显更长，不能用单文件查询代表全部场景。

## Scrolling / 滚动

300,000 index entries including one root and 1,500 synthetic apps. Four scenarios each perform 180 scroll steps in a native window. Timed work includes updating the viewport, layout/drawing and layer-transaction submission. It does not measure final compositor/GPU presentation, display FPS, physical input latency, or loading real app bundles.

| Scenario | Result count | Main-thread work P95 | Maximum | Main-loop intervals >25 ms |
| --- | ---: | ---: | ---: | ---: |
| List | 299,999 | 3.38 ms | 15.15 ms | 0 |
| Grid | 299,999 | 9.79 ms | 12.37 ms | 0 |
| Apps list | 1,500 | 5.61 ms | 9.25 ms | 0 |
| Apps grid | 1,500 | 9.30 ms | 12.12 ms | 0 |

## Thumbnails / 缩略图

12 generated gradient JPEGs at 4032 × 3024 pixels, newly created on each run. Timer starts when scrolling settles and ends when the actual image replaces the icon in the grid. First image: **23.21 ms**; all 12: **44.34 ms**. Another scroll cycle reuses those same image objects in **0.54 ms**, without decoding them again.

| Same fixture script | All 12 thumbnails |
| --- | ---: |
| Historical record before the build 25 preview-pipeline change | 190.30 ms |
| Current build 26 run | 44.34 ms |

This is approximately **77% less time**. The baseline is a retained historical measurement from the same script, **not a fresh A/B run in this session**. See the [build 25 record](validation/2026-10-17-grid-menu-build25.md). JPEG gradients compress differently from real photographs; these values do not predict RAW, network, cloud-only or third-party document-provider latency.

对比采用相同生成脚本的历史基线与本次测量，未重新运行旧版本。缓存复用和首次解码是两种操作；0.54 ms 不代表冷启动加载速度。

## Reproduce / 复测

```sh
bash scripts/build-llama.sh
CI=true FOX_SEARCH_BENCHMARK=1 swift test --filter PublicSearchBenchmarkTests
CI=true FOX_THUMBNAIL_WORKLOAD=1 FOX_SCROLL_WORKLOAD=1 swift test --filter 'GridIconTests|ScrollWorkloadTests'
```

These opt-in checks create synthetic fixtures and local test windows; they do not post keyboard or pointer events into other apps. The source tree and compile configuration, OS, concurrent work and hardware affect the numbers. No competing-product speed claim or measured human time-saving claim is made.

[Machine-readable measurements](benchmarks/build26.json) · [Benchmark code](../Tests/OilFindCoreTests/PublicSearchBenchmarkTests.swift) · [Scroll workload](../Tests/OilFindUITests/ScrollWorkloadTests.swift) · [Thumbnail workload](../Tests/OilFindUITests/GridIconTests.swift).
