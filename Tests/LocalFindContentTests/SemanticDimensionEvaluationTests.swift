import XCTest
import FoxFindSemanticCore

/// Opt-in evaluation, not a quality claim or a change to the shipped index format.
/// Uses only authored synthetic documents; never reads the user's content index.
final class SemanticDimensionEvaluationTests: XCTestCase {
    struct Example {
        let id: String
        let title: String
        let body: String
        let query: String
    }
    private let examples: [Example] = [
        .init(id: "crystal-light", title: "水晶拍摄", body: "透明水晶手链采用柔光箱和侧逆光。用黑旗控制反射，避免正面强光掩盖晶体内部细节。", query: "怎样布光才能拍出水晶的通透感"),
        .init(id: "metal-light", title: "银饰拍摄", body: "银色金属首饰使用大面积柔光反射板塑造光泽，白卡补光，保留金属边缘的明暗层次。", query: "银首饰怎么拍才有金属质感"),
        .init(id: "portrait-light", title: "人像摄影", body: "单人肖像使用伦勃朗三角光，主灯放在面部侧上方，背景灯分离头发与暗色背景。", query: "拍人像脸上那个小三角光怎么打"),
        .init(id: "package-print", title: "包装印前检查", body: "包装交付印刷前检查 CMYK 色彩模式、三毫米出血、刀模线、字体转曲和图片分辨率。", query: "包装送印前要检查哪些技术参数"),
        .init(id: "package-copy", title: "包装文字", body: "包装正面的文案保持简洁，只保留品牌名与产品特点。背面列出配料、产地、使用方法和保质期。", query: "包装上应该写些什么信息"),
        .init(id: "contract-delivery", title: "设计服务合同", body: "设计项目交付日期为十月三十日。尾款在客户验收源文件后七个工作日内支付。", query: "设计稿验收完多久需要付尾款"),
        .init(id: "contract-rent", title: "房屋租赁协议", body: "房屋租金按月支付，押金为一个月租金。退租前提前三十天通知房东，结清水电后退还押金。", query: "退租时提前多久通知房东"),
        .init(id: "swift-cancel", title: "Swift 搜索任务取消", body: "输入新查询时递增请求代次并取消旧任务。异步结果返回主线程后校验代次，避免旧结果覆盖新输入。", query: "快速输入的时候怎样防止过期搜索结果回填"),
        .init(id: "sqlite-wal", title: "数据库并发", body: "SQLite 使用 WAL 模式和独立读写连接。读事务读取快照，写入分成短事务，避免长期持锁。", query: "索引写入时怎样让查询不被数据库锁住"),
        .init(id: "thumbnail", title: "缩略图队列", body: "图片用 ImageIO 按目标尺寸解码，限制并发数量，取消不可见单元的请求，并复用缓存中的缩略图。", query: "滚动图片宫格时如何降低解码开销"),
        .init(id: "exif", title: "拍摄日期元数据", body: "照片的原始拍摄日期来自 EXIF DateTimeOriginal。复制文件会改变文件系统日期，不能把修改时间当拍摄时间。", query: "为什么复制过来的照片时间不能直接当拍摄时间"),
        .init(id: "backup", title: "备份操作", body: "每周备份项目到外置硬盘，每月再保存一份离线副本。恢复演练需要检查文件是否完整且可以打开。", query: "怎样确认备份真的能恢复"),
        .init(id: "travel", title: "京都旅行安排", body: "京都三日行程包含清水寺、岚山竹林和伏见稻荷。早上去竹林避开人流，最后一天预留购买伴手礼的时间。", query: "去岚山什么时候人比较少"),
        .init(id: "invoice", title: "报销资料", body: "差旅报销需提供发票、支付凭证和行程单。财务核对金额及抬头，审核后合并打款。", query: "出差报销需要交哪些凭证"),
        .init(id: "audio", title: "录音降噪", body: "访谈录音先保留原始文件，再用短段底噪估计进行温和降噪。过强处理会产生金属声并损伤人声。", query: "采访录音降噪后声音发金属音怎么办"),
        .init(id: "video", title: "视频剪辑节奏", body: "访谈视频删除长停顿，用相关画面覆盖剪辑点。保留观点上下文，避免剪断一句话改变原意。", query: "访谈剪辑怎样减少停顿又不改变说话的意思"),
        .init(id: "onboarding", title: "首次使用引导", body: "首次引导只帮助用户完成一次真实搜索。关闭后记录状态，用户可从菜单主动重新打开。", query: "用户已经关过的新手引导不要每次启动都弹出"),
        .init(id: "update", title: "应用更新", body: "下载新版本后验证签名和散列，保留旧应用备份。新版本启动失败时恢复旧版本，不覆盖用户索引。", query: "自动更新失败怎么退回原来的版本"),
        .init(id: "ui-glass", title: "搜索窗口外观", body: "搜索窗口采用中性灰毛玻璃，减少分割线，工具按钮共享一致间距，选中项使用柔和的强调色。", query: "那个偏灰的磨砂透明搜索界面设计"),
        .init(id: "password", title: "账号安全", body: "为每个账号使用不同密码并启用多因素验证。恢复代码离线保存，不把密码或令牌写入项目日志。", query: "恢复账号的备用验证码应该放哪里"),
        .init(id: "coffee", title: "手冲咖啡记录", body: "浅烘咖啡使用九十二度水温，粉水比一比十五。若味道太酸可略微磨细，并适当延长萃取。", query: "手冲喝起来太酸怎么调整"),
        .init(id: "plants", title: "室内植物养护", body: "龟背竹喜欢明亮散射光。表层土壤干燥后浇透水，花盆避免积水，冬季减少浇水频率。", query: "龟背竹冬天还要每天浇水吗"),
        .init(id: "sql-plan", title: "SQL query performance", body: "Use EXPLAIN QUERY PLAN to inspect table scans. Add a composite index matching frequent filters and ordering, then measure the same workload again.", query: "怎么判断数据库查询有没有走索引"),
        .init(id: "search-scope", title: "搜索范围设置", body: "用户在内容搜索中明确选择文件夹。关闭某个来源后立刻撤销排队查询与原文读取，不继续展示已禁用来源。", query: "禁用了一个文件夹来源之后旧查询还返回内容怎么办")
    ]

    func testEvaluatePinnedModelDimensions() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FOX_SEMANTIC_DIMENSION_EVAL"] == "1",
              let directory = env["FOX_FIND_TEST_MODELS"], let executable = env["FOX_FIND_TEST_HELPER"] else {
            throw XCTSkip("Opt-in dimension evaluation requires existing pinned local weights and helper")
        }
        let models = URL(fileURLWithPath: directory)
        XCTAssertEqual(try ModelFiles.sha256(of: models.appendingPathComponent(ModelFiles.text.name)), ModelFiles.text.sha256)
        let worker = SemanticWorkerClient(executable: URL(fileURLWithPath: executable), models: models, textOnly: true)
        defer { worker.close() }
        func embedBatches(_ inputs: [String]) throws -> [[Float]] {
            var output = [[Float]]()
            for start in stride(from: 0, to: inputs.count, by: 8) {
                output.append(contentsOf: try worker.embed(Array(inputs[start..<min(start + 8, inputs.count)])))
            }
            return output
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let documents = try embedBatches(examples.map { Prompts.document(title: $0.title, text: $0.body) })
        let queries = try embedBatches(examples.map { Prompts.query($0.query) })
        let inferenceMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(documents.count, examples.count); XCTAssertEqual(queries.count, examples.count)
        for vector in documents + queries {
            XCTAssertEqual(vector.count, 768); XCTAssertTrue(vector.allSatisfy(\.isFinite))
        }
        var evaluations = [[String: Any]]()
        for dimensions in [128, 256, 512, 768] {
            func normalized(_ vector: [Float]) -> [Double] {
                let prefix = vector.prefix(dimensions).map(Double.init)
                let norm = sqrt(prefix.reduce(0) { $0 + $1 * $1 })
                return prefix.map { $0 / max(norm, 1e-12) }
            }
            let candidates = documents.map(normalized), queryVectors = queries.map(normalized)
            var rows = [[String: Any]](), top1 = 0, top3 = 0, reciprocal = 0.0
            for (i, query) in queryVectors.enumerated() {
                var scores: [(Int, Double)] = []
                for (index, vector) in candidates.enumerated() {
                    var score = 0.0
                    for dimension in 0..<dimensions { score += query[dimension] * vector[dimension] }
                    scores.append((index, score))
                }
                scores.sort { left, right in left.1 == right.1 ? left.0 < right.0 : left.1 > right.1 }
                let rank = try XCTUnwrap(scores.firstIndex { $0.0 == i }) + 1
                if rank == 1 { top1 += 1 }; if rank <= 3 { top3 += 1 }
                reciprocal += 1.0 / Double(rank)
                rows.append(["query": examples[i].query, "expected": examples[i].id, "rank": rank,
                             "top3": scores.prefix(3).map { ["id": examples[$0.0].id, "score": $0.1] as [String: Any] }])
            }
            let count = Double(examples.count)
            evaluations.append(["dimensions": dimensions, "float32_bytes_per_vector": dimensions * 4,
                                "top1": Double(top1) / count, "recall_at_3": Double(top3) / count,
                                "mrr": reciprocal / count, "queries": rows])
            print("FOX_DIMENSION_EVAL dims=\(dimensions) queries=\(examples.count) top1=\(top1) top3=\(top3) mrr=\(reciprocal / count)")
        }
        let report: [String: Any] = ["corpus": "synthetic-zh-text-v1", "documents": examples.count, "queries": examples.count,
            "model_revision": ModelFiles.revision, "text_model_sha256": ModelFiles.text.sha256,
            "mode": "textOnly", "inference_total_ms": inferenceMs, "evaluations": evaluations,
            "limits": "Small synthetic text set; no image/video/audio quality claim. Production remains 768 dimensions. Truncated vectors are L2-normalized."]
        if let output = env["FOX_SEMANTIC_EVAL_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
