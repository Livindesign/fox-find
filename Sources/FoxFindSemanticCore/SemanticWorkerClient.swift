import Foundation
import Darwin

public enum SemanticError: Error, LocalizedError {
    case cancelled, timeout, invalidResponse, unavailable(String), input(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Cancelled"
        case .timeout: return "Local model timed out"
        case .invalidResponse: return "Invalid local model response"
        case .unavailable(let message), .input(let message): return message
        }
    }
}

/// Serial use only. All pipe reads are bounded and cancellable; no AppKit work belongs here.
public final class SemanticWorkerClient {
    private var process: Process?
    private var workspace: URL?
    private var input: FileHandle?, output: FileHandle?
    private var buffered = Data(), sequence = 0
    private let executable: URL, models: URL, textOnly: Bool
    public init(executable: URL, models: URL, textOnly: Bool) {
        self.executable = executable; self.models = models; self.textOnly = textOnly
    }
    deinit { close() }
    public func close() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
        try? input?.close(); try? output?.close()
        input = nil; output = nil; process = nil; buffered.removeAll(keepingCapacity: false)
        if let workspace { try? FileManager.default.removeItem(at:workspace) }; workspace = nil
    }
    public func embed(_ inputs: [String], image: Bool = false, cancelled: () -> Bool = { false }) throws -> [[Float]] {
        do {
            if cancelled() { throw SemanticError.cancelled }
            if process?.isRunning != true { try start(cancelled: cancelled) }
            sequence += 1
            let data = try JSONSerialization.data(withJSONObject: ["id": sequence, "op": image ? "image" : "text", "inputs": inputs])
            guard data.count < 1_000_000, let input else { throw SemanticError.invalidResponse }
            try input.write(contentsOf: data + Data([10]))
            let response = try read(deadline: Date().addingTimeInterval(90), cancelled: cancelled)
            guard response["id"] as? Int == sequence, response["ok"] as? Bool == true,
                  response["dim"] as? Int == 768, response["count"] as? Int == inputs.count,
                  let base64 = response["vectors"] as? String, let bytes = Data(base64Encoded: base64),
                  bytes.count == inputs.count * 768 * 4 else { throw SemanticError.invalidResponse }
            if let errors = response["errors"] as? [Any], let error = errors.compactMap({ $0 as? String }).first {
                throw SemanticError.input(error)
            }
            var floats = [Float](repeating: 0, count: inputs.count * 768)
            _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
            guard floats.allSatisfy(\.isFinite) else { throw SemanticError.invalidResponse }
            return stride(from: 0, to: floats.count, by: 768).map { Array(floats[$0..<$0 + 768]) }
        } catch { close(); throw error }
    }
    private func start(cancelled: () -> Bool) throws {
        close()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw SemanticError.unavailable("Semantic helper is missing; reinstall Fox Find.") }
        let p = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.executableURL = executable; p.arguments = textOnly ? ["--text-only"] : []
        var env = ProcessInfo.processInfo.environment
        env["FOX_FIND_MODELS"] = models.path
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("fox-model-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        self.workspace = workspace; env["FOX_FIND_WORKER_TEMP"] = workspace.path; p.environment = env
        p.standardInput = stdinPipe; p.standardOutput = stdoutPipe; p.standardError = FileHandle.nullDevice
        p.qualityOfService = textOnly ? .userInitiated : .utility
        try p.run(); process = p; input = stdinPipe.fileHandleForWriting; output = stdoutPipe.fileHandleForReading
        // Close parent copies of the child ends so EOF is observable after a crash.
        try? stdinPipe.fileHandleForReading.close(); try? stdoutPipe.fileHandleForWriting.close()
        let ready = try read(deadline: Date().addingTimeInterval(120), cancelled: cancelled)
        guard ready["ready"] as? Bool == true, ready["dim"] as? Int == 768,
              ready["revision"] as? String == ModelFiles.revision else {
            throw SemanticError.unavailable(ready["error"] as? String ?? "Model could not start")
        }
    }
    private func read(deadline: Date, cancelled: () -> Bool) throws -> [String: Any] {
        guard let output else { throw SemanticError.invalidResponse }
        while true {
            if cancelled() { throw SemanticError.cancelled }
            if let end = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: end); buffered.removeSubrange(...end)
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw SemanticError.invalidResponse }
                return object
            }
            if Date() >= deadline { throw SemanticError.timeout }
            var fd = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let status = poll(&fd, 1, 50)
            if status < 0 { if errno == EINTR { continue }; throw SemanticError.invalidResponse }
            if status == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(fd.fd, &bytes, bytes.count)
            guard count > 0 else { throw SemanticError.unavailable("Local model stopped unexpectedly") }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= 1_000_000 else { throw SemanticError.invalidResponse }
        }
    }
}
