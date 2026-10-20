import Foundation

/// Historical imports yield to interaction without disabling cached conversation search.
final class AITopicImportGate {
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let quietInterval: TimeInterval
    private var quietUntil: TimeInterval = 0
    private var epoch = 0
    private var pressured = false

    init(quietInterval: TimeInterval = 8, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.quietInterval = quietInterval; self.now = now
    }
    func userActivity() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1; quietUntil = now() + quietInterval
    }
    func memoryPressure(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard pressured != value else { return }
        pressured = value; epoch += 1; quietUntil = now() + quietInterval
    }
    var delay: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return pressured ? max(1, quietInterval) : max(0, quietUntil - now())
    }
    func ticket() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return !pressured && now() >= quietUntil ? epoch : nil
    }
    func permits(_ ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !pressured && ticket == epoch && now() >= quietUntil
    }
}
