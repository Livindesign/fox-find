import Foundation
import OilFindCore

/// Shared with the extractor: the UI must not advertise formats it cannot read.
public enum ContentFileFormats {
    public static let images = Set("png jpg jpeg heic heif tif tiff bmp gif webp avif".split(separator: " ").map(String.init))
    public static let text = Set("txt md markdown csv tsv log swift c h m mm cpp hpp cc js jsx ts tsx py rb go rs java kt php css scss vue svelte sh zsh bash json yaml yml toml xml sql lua dart cs r tex html htm".split(separator: " ").map(String.init))
    public static let documents = text.union(["pdf", "docx", "pptx", "xlsx", "odt", "ods", "odp", "rtf", "doc"])
    public static let maximumBytes: UInt64 = 64 * 1024 * 1024
}

/// Cheap snapshot-only checks. No filesystem calls or extraction while opening a menu.
struct FileActionCapabilities {
    let isApplication: Bool
    let isFolder: Bool
    let isPackage: Bool
    let supportsText: Bool
    let supportsSimilarity: Bool
    let supportsOpenWith: Bool
    let exceedsTextLimit: Bool
    let isRoot: Bool

    init(_ file: ResultItem) {
        let ext = (file.path as NSString).pathExtension.lowercased()
        isApplication = file.kind == 2 || ext == "app"
        isPackage = file.flags & SiftFlag.package != 0 || isApplication
        let directory = file.flags & SiftFlag.dir != 0
        isFolder = directory && !isPackage
        let regular = !directory && !isPackage && file.flags & SiftFlag.symlink == 0
        supportsText = regular && (ContentFileFormats.documents.contains(ext) || ContentFileFormats.images.contains(ext))
        supportsSimilarity = regular && ContentFileFormats.images.contains(ext)
        supportsOpenWith = !isFolder && !isApplication
        exceedsTextLimit = file.size > ContentFileFormats.maximumBytes
        isRoot = file.id == 0 || file.path == file.source.store.rootPath
    }
    var textUnavailableReason: String {
        supportsText ? L10n.local("文件超过文字提取上限（64 MB），可使用快速查看", "File exceeds the 64 MB text extraction limit; use Quick Look")
                     : L10n.local("此类型不支持提取文字，可使用快速查看", "Text extraction is not supported for this type; use Quick Look")
    }
}
