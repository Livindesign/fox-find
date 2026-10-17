import Foundation
import LlamaRuntime
import FoxFindSemanticCore

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}
do {
    let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: CommandLine.arguments.contains("--text-only"))
    defer { embedder.close() }
    emit(["ready": true, "dim": embedder.info.dim, "revision": ModelFiles.revision])
    while let line = readLine() {
        guard line.utf8.count < 1_000_000, let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? Int, let op = request["op"] as? String else { continue }
        if op == "quit" { break }
        do {
            let inputs = request["inputs"] as? [String] ?? []
            guard (1...8).contains(inputs.count), inputs.allSatisfy({ $0.utf8.count < 32_000 }) else { throw WorkerError.failed("invalid input size") }
            let embeddings: [Embedding]
            switch op {
            case "text": embeddings = try embedder.embedTexts(inputs).map { Embedding(vector: $0, error: nil) }
            case "image":
                embeddings = inputs.map { path in
                    do {
                        let prepared = try preparedImage(path)
                        defer { try? FileManager.default.removeItem(at:prepared.deletingLastPathComponent()) }
                        return try embedder.embedImages([prepared.path],budget:140)[0]
                    } catch { return Embedding(vector:nil,error:String(error.localizedDescription.prefix(300))) }
                }
            default: throw WorkerError.failed("unsupported operation")
            }
            let floats = embeddings.flatMap { $0.vector ?? [Float](repeating: 0, count: embedder.info.dim) }
            emit(["id": id, "ok": true, "dim": embedder.info.dim, "count": inputs.count,
                  "vectors": floats.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString(),
                  "errors": embeddings.map { $0.error.map { $0 as Any } ?? NSNull() }])
        } catch { emit(["id": id, "ok": false, "error": String("\(error)".prefix(500))]) }
    }
} catch { emit(["ready": false, "error": String("\(error)".prefix(500))]); exit(1) }
