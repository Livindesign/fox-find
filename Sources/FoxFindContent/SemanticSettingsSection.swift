import SwiftUI

struct SemanticSettingsSection: View {
    @ObservedObject var model: ContentSettings
    @ObservedObject var models: SemanticModels
    let rebuild: () -> Void
    let chooseFolder: () -> Void
    @State private var confirmClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.text("本地语义搜索 · 实验功能", "Local semantic search · Experimental"),isOn:$model.semanticEnabled)
            Text(model.text("用一句话描述图片或文档；在「… 更多操作」直接选择参考图找相似。只搜索你添加的内容文件夹，不会自动搜索全盘内容；文件和查询均不上传。", "Describe images or documents, or choose a reference image directly from More (…). Searches only your selected content folders; files and queries stay on this Mac."))
                .font(.footnote).foregroundStyle(.secondary)
            if model.folders.isEmpty {
                Text(model.text("尚未添加内容文件夹，所以描述搜索和相似图片暂时没有结果。", "No content folders have been added, so description and similar-image searches have nothing to search."))
                    .font(.footnote)
                Button(model.text("添加要搜索的文件夹…", "Add a Folder to Search…"), action: chooseFolder)
            } else {
                Text(model.text("搜索范围：", "Search folders: ") + model.folders.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、"))
                    .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                if model.semanticPieces == 0 && model.semanticEnabled {
                    Text(model.text(model.paused ? "索引已暂停，请先继续内容索引。" : "正在等待首批内容就绪。建好一部分即可开始搜索。", model.paused ? "Indexing is paused. Resume Content Indexing first." : "Waiting for the first indexed batch. You can search as soon as part of it is ready."))
                        .font(.footnote)
                }
            }
            if !models.ready {
                Text(model.text("需下载约 865 MB 模型；首次索引后可离线使用。", "Requires a 865 MB model download. Works offline after initial indexing."))
                    .font(.footnote).foregroundStyle(.secondary)
                if models.downloading {
                    ProgressView(value:models.progress)
                    HStack { Text("\(Int(models.progress * 100))%").monospacedDigit(); Button(model.text("取消下载", "Cancel Download")) { models.cancel() } }
                } else { Button(model.text("下载本地模型", "Download Local Models")) { models.download() } }
            } else {
                HStack {
                    Image(systemName:model.semanticRunning ? "arrow.triangle.2.circlepath" : "sparkles")
                    Text(model.text("\(model.semanticFiles) 个文件 · \(model.semanticPieces) 个片段", "\(model.semanticFiles) files · \(model.semanticPieces) segments"))
                    Spacer()
                    if model.semanticRunning { ProgressView().controlSize(.small) }
                }.font(.footnote)
                if !model.semanticStatus.isEmpty { Text(model.semanticStatus).font(.caption).lineLimit(1).foregroundStyle(.secondary) }
                if model.semanticIncomplete > 0 {
                    Text(model.text("\(model.semanticIncomplete) 个文件等待续建或未完整处理。", "\(model.semanticIncomplete) files pending or partially processed."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button(model.text("重建语义索引…", "Rebuild Semantic Index…")) { confirmClear = true }
                    .confirmationDialog(model.text("只重建语义缓存，原文件和文字索引不受影响。", "Rebuild semantic cache. Source files and text index are kept."),isPresented:$confirmClear) {
                        Button(model.text("重建", "Rebuild"),action:rebuild)
                    }
            }
            Text(model.text("PDF 只有在搜索结果标出「可能相关 · 第 N 页」时，才可打开对应页。选中该结果 →「…」→「查看第 N 页的相关内容」，或按 ⌘⇧Y。普通 PDF 结果的 ⌘⇧Y 用于查看识别文字。", "Only a PDF result labeled Possibly related · Page N has a semantic match page. Select it, then More (…) → View Related Content, or press ⌘⇧Y. For other PDFs, ⌘⇧Y shows extracted text."))
                .font(.caption).foregroundStyle(.secondary)
            if !models.error.isEmpty { Text(models.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if !model.semanticError.isEmpty { Text(model.semanticError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Text(model.text("输入时让出资源；节能或温度较高时暂缓。暂停内容索引也会暂停语义索引。PDF 分页续建，最多 5000 页；其他文档沿用文字提取上限。相似结果不代表精确匹配。", "Yields while typing; waits during Low Power Mode or thermal pressure. Pause Content Indexing also pauses semantics. PDFs resume by page, up to 5000 pages; other documents keep the extraction limits above. Similarity is not an exact match."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
