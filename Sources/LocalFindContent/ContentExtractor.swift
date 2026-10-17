import AppKit
import Foundation
import Vision
import PDFKit
import ImageIO
import Darwin
import OilFindApp

struct ExtractedContent { var text: String; var category: String; var note = ""; var segments: [ContentTextSegment] = [] }
enum ExtractionFailure: String, Error { case unsupported, tooLarge, unavailable, encrypted, cancelled, malformed, timeout, noText }

struct ContentExtractor {
    static let imageTypes = Set("png jpg jpeg heic heif tif tiff bmp gif webp avif".split(separator: " ").map(String.init))
    static let textTypes = Set("txt md markdown csv tsv log swift c h m mm cpp hpp cc js jsx ts tsx py rb go rs java kt php css scss vue svelte sh zsh bash json yaml yml toml xml sql lua dart cs r tex html htm".split(separator: " ").map(String.init))
    static let documentTypes = textTypes.union(["pdf", "docx", "pptx", "xlsx", "odt", "ods", "odp", "rtf", "doc"])
    static let maxBytes: Int64 = 64 * 1024 * 1024
    static let maxCharacters = 200_000
    static func supports(_ ext: String, options: ExtractionOptions) -> Bool {
        (options.documents && documentTypes.contains(ext)) || ((options.images || options.labels) && imageTypes.contains(ext))
    }
    static func stamp(_ url: URL) throws -> String {
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFREG,
              s.st_flags & UInt32(SF_DATALESS) == 0 else { throw ExtractionFailure.unavailable }
        guard s.st_size <= maxBytes else { throw ExtractionFailure.tooLarge }
        return "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec)"
    }
    func extract(_ url: URL, options: ExtractionOptions, cancelled: () -> Bool = { false }) throws -> ExtractedContent {
        _ = try Self.stamp(url)
        if cancelled() { throw ExtractionFailure.cancelled }
        let ext = url.pathExtension.lowercased()
        guard Self.supports(ext, options: options) else { throw ExtractionFailure.unsupported }
        var result: ExtractedContent
        if Self.imageTypes.contains(ext) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw ExtractionFailure.malformed }
            var parts = [String](), failures = [String]()
            if options.images {
                do { parts.append(try recognize(cg)) } catch { failures.append("ocr-failed") }
            }
            if !cancelled(), options.labels {
                do { parts.append(try classify(cg)) } catch { failures.append("labels-failed") }
            }
            result = ExtractedContent(text: parts.joined(separator: "\n"), category: "image", note: failures.joined(separator: ","))
        } else if ext == "pdf" {
            result = try pdf(url, ocr: options.images, cancelled: cancelled)
        } else if ["docx", "pptx", "xlsx", "odt", "ods", "odp"].contains(ext) {
            result = try office(url, cancelled: cancelled)
        } else if ["rtf", "doc"].contains(ext) {
            let data = try Self.command("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path], maxOutput: 4 * 1024 * 1024)
            result = ExtractedContent(text: String(decoding: data, as: UTF8.self), category: "document")
        } else {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            if ["html", "htm"].contains(ext) {
                text = text.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            }
            result = ExtractedContent(text: text, category: "document", note: data.count == 4 * 1024 * 1024 ? "text-byte-limit" : "")
        }
        if cancelled() { throw ExtractionFailure.cancelled }
        result.text = result.text.replacingOccurrences(of: "\0", with: " ").precomposedStringWithCanonicalMapping
        if result.text.count > Self.maxCharacters { result.text = String(result.text.prefix(Self.maxCharacters)); result.note = "text-limit" }
        if result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.note.isEmpty { result.note = "no-text" }
        let length = (result.text as NSString).length
        result.segments = result.segments.filter { $0.offset < length }.map { ContentTextSegment(offset: $0.offset, length: min($0.length, length - $0.offset), page: $0.page) }
        return result
    }
    private func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    private func classify(_ image: CGImage) throws -> String {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        let aliases = ["cat": "猫", "dog": "狗", "food": "食物 美食", "flower": "花", "plant": "植物", "tree": "树",
                       "beach": "海滩", "ocean": "海洋", "mountain": "山", "sky": "天空", "car": "汽车", "building": "建筑",
                       "bird": "鸟", "person": "人物", "animal": "动物", "landscape": "风景", "city": "城市", "document": "文档"]
        return (request.results ?? []).filter { $0.confidence >= 0.2 }.prefix(12).map {
            let label = $0.identifier.replacingOccurrences(of: "_", with: " ")
            let chinese = label.split(separator: " ").compactMap { aliases[String($0)] }.joined(separator: " ")
            return label + (chinese.isEmpty ? "" : " " + chinese)
        }.joined(separator: " · ")
    }
    private func pdf(_ url: URL, ocr: Bool, cancelled: () -> Bool) throws -> ExtractedContent {
        guard let document = PDFDocument(url: url) else { throw ExtractionFailure.malformed }
        guard !document.isLocked else { throw ExtractionFailure.encrypted }
        var parts = [String](), segments = [ContentTextSegment](), offset = 0, scanned = 0, length = 0, limited = document.pageCount > 200
        for i in 0..<min(200, document.pageCount) {
            if cancelled() { throw ExtractionFailure.cancelled }
            guard let page = document.page(at: i) else { continue }
            var text = page.string ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ocr {
                if scanned < 20 {
                    scanned += 1
                    text = try autoreleasepool {
                        let bounds = page.bounds(for: .mediaBox), scale = min(2, 2048 / max(1, max(bounds.width, bounds.height)))
                        let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                        let bitmap = page.thumbnail(of: size, for: .mediaBox)
                        guard let cg = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
                        return try recognize(cg)
                    }
                } else { limited = true }
            }
            text = text.replacingOccurrences(of: "\0", with: " ").precomposedStringWithCanonicalMapping
            segments.append(ContentTextSegment(offset: offset, length: (text as NSString).length, page: i + 1))
            offset += (text as NSString).length + 1
            parts.append(text); length += text.count
            if length >= Self.maxCharacters { limited = true; break }
        }
        return ExtractedContent(text: parts.joined(separator: "\n"), category: "document", note: limited ? "pdf-limit" : "", segments: segments)
    }
    private func office(_ url: URL, cancelled: () -> Bool) throws -> ExtractedContent {
        let names = String(decoding: try Self.command("/usr/bin/unzip", ["-Z1", url.path], maxOutput: 1024 * 1024), as: UTF8.self).split(separator: "\n").map(String.init)
        let members = names.filter {
            $0 == "word/document.xml" || $0.hasPrefix("word/header") || $0.hasPrefix("word/footer") ||
            $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") ||
            $0.hasPrefix("ppt/notesSlides/notesSlide") && $0.hasSuffix(".xml") ||
            $0 == "xl/sharedStrings.xml" || $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") || $0 == "content.xml"
        }.sorted()
        guard !members.isEmpty else { throw ExtractionFailure.malformed }
        var parts = [String](), total = 0
        for member in members.prefix(512) {
            if cancelled() { throw ExtractionFailure.cancelled }
            let data = try Self.command("/usr/bin/unzip", ["-p", url.path, member], maxOutput: 8 * 1024 * 1024)
            let delegate = OfficeXMLText(), parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() || delegate.output.count >= Self.maxCharacters else { throw ExtractionFailure.malformed }
            let text = delegate.output; parts.append(text); total += text.count
            if total >= Self.maxCharacters { break }
        }
        return ExtractedContent(text: parts.joined(separator: "\n"), category: "document", note: total >= Self.maxCharacters || members.count > 512 ? "office-limit" : "")
    }
    static func command(_ executable: String, _ arguments: [String], maxOutput: Int) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 15)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume(); defer { timer.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= maxOutput else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit()
                throw ExtractionFailure.tooLarge
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtractionFailure.malformed }
        return data
    }
}

private final class OfficeXMLText: NSObject, XMLParserDelegate {
    var output = "", capture = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if ["t", "v", "p", "h", "span"].contains(name) { capture += 1 }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if capture > 0 { output += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ["t", "v", "p", "h", "span"].contains(name) { capture = max(0, capture - 1) }
        if ["p", "h", "row", "tr", "c"].contains(name) { output += "\n" }
        if output.count > ContentExtractor.maxCharacters { parser.abortParsing() }
    }
}
