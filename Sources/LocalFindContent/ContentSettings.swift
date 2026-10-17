import Foundation
import Combine

struct ExtractionOptions: Equatable {
    var images = true, labels = true, documents = true
    var fingerprint: String { "extract-v1-\(images)-\(labels)-\(documents)" }
}

struct ContentIssue: Identifiable {
    let path: String, note: String
    var id: String { path + note }
    func reason(chinese: Bool) -> String {
        let reasons: [String: (String, String)] = [
            "tooLarge": ("超过 64 MB，已跳过", "Over 64 MB; skipped"),
            "unavailable": ("文件未下载、无读取权限或已不可用", "Not downloaded, unreadable, or unavailable"),
            "encrypted": ("加密 PDF，无法读取", "Encrypted PDF"),
            "malformed": ("格式损坏或暂不支持", "Malformed or unsupported format"),
            "timeout": ("读取超时", "Extraction timed out"),
            "unsupported": ("此格式暂不支持文字提取", "Text extraction is not supported for this format"),
            "no-text": ("没有识别出可用文字或标签", "No text or labels detected"),
            "ocr-failed": ("文字识别失败，保留已识别标签", "OCR failed; available labels retained"),
            "labels-failed": ("场景识别失败，保留已识别文字", "Classification failed; available text retained"),
            "pdf-limit": ("已索引部分内容，达到 PDF 页数或文字上限", "Partial contents; PDF page or text limit reached"),
            "text-limit": ("已索引前 20 万字", "First 200k characters indexed"),
            "text-byte-limit": ("已索引前 4 MB 文字", "First 4 MB of text indexed"),
            "office-limit": ("已索引部分内容，达到 Office 处理上限", "Partial contents; Office extraction limit reached")]
        return note.split(separator: ",").map { part in
            guard let pair = reasons[String(part)] else { return String(part) }
            return chinese ? pair.0 : pair.1
        }.joined(separator: " · ")
    }
}

final class ContentSettings: ObservableObject {
    @Published var chinese = false
    @Published var semanticEnabled: Bool { didSet { save() } }
    @Published var semanticStatus = ""
    @Published var semanticFiles = 0
    @Published var semanticPieces = 0
    @Published var semanticIncomplete = 0
    @Published var semanticRunning = false
    @Published var semanticError = ""
    @Published var enabled: Bool { didSet { save() } }
    @Published var paused: Bool { didSet { save() } }
    @Published var images: Bool { didSet { save() } }
    @Published var labels: Bool { didSet { save() } }
    @Published var documents: Bool { didSet { save() } }
    @Published var offline: Bool { didSet { save() } }
    @Published var folders: [String] { didSet { save() } }
    @Published var status = ""
    @Published var currentFile = ""
    @Published var completed = 0
    @Published var total = 0
    @Published var indexed = 0
    @Published var skipped = 0
    @Published var running = false
    @Published var error = ""
    var onChange: (() -> Void)?
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        semanticEnabled = defaults.bool(forKey: "content.semanticEnabled")
        defaults.register(defaults: ["content.enabled": true, "content.images": true, "content.labels": true,
                                    "content.documents": true, "content.offline": true])
        enabled = defaults.bool(forKey: "content.enabled"); images = defaults.bool(forKey: "content.images")
        paused = defaults.bool(forKey: "content.paused")
        labels = defaults.bool(forKey: "content.labels"); documents = defaults.bool(forKey: "content.documents")
        offline = defaults.bool(forKey: "content.offline"); folders = defaults.stringArray(forKey: "content.folders") ?? []
    }
    var options: ExtractionOptions { ExtractionOptions(images: images, labels: labels, documents: documents) }
    func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private func save() {
        defaults.set(semanticEnabled, forKey: "content.semanticEnabled")
        defaults.set(enabled, forKey: "content.enabled"); defaults.set(images, forKey: "content.images")
        defaults.set(paused, forKey: "content.paused")
        defaults.set(labels, forKey: "content.labels"); defaults.set(documents, forKey: "content.documents")
        defaults.set(offline, forKey: "content.offline"); defaults.set(folders, forKey: "content.folders")
        onChange?()
    }
}
