import Foundation
import OilFindApp
import OilFindCore

extension ContentSearch {
    func contentStatus(in folder: String?) -> SupplementarySearchStatus? {
        guard var value = semanticStatus, let folder, settings.enabled,
              !settings.folders.contains(where: { ExcludedFolders.contains($0, path: folder) || ExcludedFolders.contains(folder, path: $0) }) else { return semanticStatus }
        let t = settings.text
        value = SupplementarySearchStatus(title: t("这个文件夹还没有识别内容", "Content is not recognized in this folder"),
                                          message: t("\(folder) 未加入内容搜索范围。可以按文件名查找，或在设置中添加这个文件夹。", "\(folder) is outside your content folders. Search by filename, or add this folder in settings."),
                                          actionTitle: t("添加文件夹…", "Add a Folder…"), canSearch: false, indexedFiles: settings.semanticFiles)
        value.folders = settings.folders
        value.summary = t("当前位置尚未识别内容", "Content not recognized in this location")
        return value
    }

    var semanticStatus: SupplementarySearchStatus? {
        let t = settings.text
        let action = t("查看内容搜索范围…", "Manage Content Folders…")
        func status(_ title: String, _ message: String, ready: Bool = false) -> SupplementarySearchStatus {
            var value = SupplementarySearchStatus(title: title, message: message, actionTitle: settings.folders.isEmpty ? t("添加文件夹…", "Add a Folder…") : action, canSearch: ready, indexedFiles: settings.semanticFiles)
            value.folders = settings.folders
            let location = settings.folders.count == 1 ? URL(fileURLWithPath: settings.folders[0]).lastPathComponent : t("\(settings.folders.count) 个文件夹", "\(settings.folders.count) folders")
            if settings.folders.isEmpty { value.summary = t("尚未添加内容文件夹", "No content folders") }
            else if !settings.enabled || !settings.semanticEnabled { value.summary = t("描述搜索未开启", "Description search is off") }
            else { value.summary = location + t(" · 已识别 \(settings.semanticFiles) 个文件", " · \(settings.semanticFiles) files recognized") + (settings.semanticRunning ? t("，仍在继续", "; processing more") : settings.paused ? t("，已暂停", "; paused") : "") }
            if !settings.semanticError.isEmpty || !settings.error.isEmpty { value.summary += t(" · 部分处理失败", " · Some processing failed") }
            return value
        }
        if settings.folders.isEmpty {
            return status(t("还没有添加内容文件夹", "No content folders yet"), t("文件名索引不包含图片和文档内容。添加要搜索的文件夹，才能按描述或参考图查找。", "The filename index does not include file contents. Add folders before searching by description or reference image."))
        }
        if !settings.enabled || !settings.semanticEnabled {
            return status(t("按描述和相似图片搜索尚未开启", "Description and similar-image search is off"), t("在设置中启用内容搜索和描述搜索；文件与查询都留在本机。", "Enable content and description search in settings. Files and queries stay on this Mac."))
        }
        guard let models = semantic?.engine.models else {
            return status(t("图片与描述搜索暂不可用", "Image and description search unavailable"), settings.semanticError)
        }
        if !models.ready {
            return status(t("本地搜索模型尚未就绪", "Local search models are not ready"), models.downloading ? t("模型正在下载，完成后开始处理已选文件夹。", "Models are downloading. Selected folders will be processed when ready.") : t("在设置中下载或验证本地模型后，即可处理所选文件夹。", "Download or verify the local models in settings to process your selected folders."))
        }
        if !settings.semanticError.isEmpty {
            return status(t("部分内容未能完成搜索或处理", "Some content could not be searched or processed"), t("部分文件处理失败。已完成的内容仍可搜索；请在设置中查看失败项目并重试。", "Some files could not be processed. Completed content remains searchable. Review the failed items and retry in settings."), ready: supportsSimilarity)
        }
        if settings.semanticPieces == 0 {
            if settings.paused {
                return status(t("内容索引已暂停", "Content indexing is paused"), t("还没有可供描述搜索的内容。请在设置中继续内容索引。", "No content is ready for description search. Resume Content Indexing in settings."))
            }
            if settings.semanticRunning {
                return status(t("正在准备可搜索的内容", "Preparing searchable content"), t("正在本机处理已选文件夹；首批完成后即可搜索，无需等全部完成。", "Processing selected folders locally. Search becomes available after the first batch."))
            }
            return status(t("所选文件夹尚无可搜索的内容", "No searchable content in selected folders yet"), t("首次处理需要时间；也请检查文件夹内有支持的图片或文档，并已授予读取权限。", "Initial processing takes time. Check for supported images or documents and allow folder access."))
        }
        if !settings.error.isEmpty {
            return status(t("部分文件夹未能完成内容识别", "Some folders could not be processed"), t("已完成的内容仍可搜索。请在设置中检查文件夹访问权限和失败详情。", "Completed content remains searchable. Check folder access and error details in settings."), ready: true)
        }
        if settings.semanticRunning {
            return status(t("已完成的内容中暂未找到匹配", "No match in the content processed so far"), t("已识别 \(settings.semanticFiles) 个文件，仍在继续。结果会在识别完成后自动补充。", "\(settings.semanticFiles) files recognized; processing continues. Results update as more content becomes available."), ready: true)
        }
        let count = settings.semanticFiles, folders = settings.folders.count
        return status(t("当前条件下没有找到相近内容", "No similar content under the current filters"), t("已建索引 \(count) 个文件，来自 \(folders) 个文件夹。试试更直接的描述，或添加素材所在文件夹。", "\(count) indexed files in \(folders) folders. Try a direct description or add the folder containing your material."), ready: true)
    }
}
