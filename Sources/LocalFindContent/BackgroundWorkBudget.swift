import Foundation
import FoxFindSemanticCore

/// One expensive background lane. Foreground embedding preempts it, and waits
/// off the UI thread until its worker has actually released the model.
final class BackgroundWorkBudget {
    enum Unavailable: Error { case memoryPressure, backgroundBusy }
    private let condition = NSCondition()
    private var background: ContentCancellation?
    private var foreground = 0
    private var pressure = false
    private var quietUntil: TimeInterval = 0
    private let clock: () -> TimeInterval
    private var pressureSource: DispatchSourceMemoryPressure?
    var prepareBackground: (() -> Void)?
    var onMemoryPressure: (() -> Void)?

    init(monitorMemory: Bool = false, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
        if monitorMemory {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, let source = self.pressureSource else { return }
                self.setMemoryPressure(!source.data.intersection([.warning, .critical]).isEmpty)
            }
            pressureSource = source; source.resume()
        }
    }
    deinit { pressureSource?.cancel() }
    var underMemoryPressure: Bool {
        condition.lock(); defer { condition.unlock() }; return pressure
    }
    func setMemoryPressure(_ value: Bool) {
        condition.lock()
        pressure = value
        if value { background?.cancel() }
        quietUntil = max(quietUntil, clock() + 8)
        condition.broadcast(); condition.unlock()
        if value { onMemoryPressure?() }
    }
    func userActivity() {
        condition.lock(); defer { condition.unlock() }
        quietUntil = max(quietUntil, clock() + 8); background?.cancel()
    }
    func beginBackground(_ token: ContentCancellation) -> Bool {
        condition.lock(); defer { condition.unlock() }
        guard background == nil, foreground == 0, !pressure, clock() >= quietUntil else { return false }
        background = token; return true
    }
    func endBackground(_ token: ContentCancellation) {
        condition.lock(); defer { condition.unlock() }
        if background === token { background = nil; condition.broadcast() }
    }
    func withForeground<T>(cancelled: () -> Bool, _ work: () throws -> T) throws -> T {
        condition.lock()
        foreground += 1; background?.cancel()
        let deadline = Date().addingTimeInterval(1)
        while background != nil && !pressure && !cancelled() && Date() < deadline {
            _ = condition.wait(until: Date().addingTimeInterval(0.05))
        }
        let pressured = pressure, stopped = cancelled(), busy = background != nil
        condition.unlock()
        defer {
            condition.lock(); foreground -= 1
            quietUntil = max(quietUntil, clock() + 8)
            condition.broadcast(); condition.unlock()
        }
        if stopped { throw SemanticError.cancelled }
        if pressured { throw Unavailable.memoryPressure }
        if busy { throw Unavailable.backgroundBusy }
        return try work()
    }
}
