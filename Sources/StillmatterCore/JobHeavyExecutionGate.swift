import Foundation

/// Coordinates heavy work between schedulers that share a JobStore but own different job types.
public final class JobHeavyExecutionGate {
    private let lock = NSLock()
    private var owner: UUID?
    private var waiters: [UUID: () -> Void] = [:]

    public init() {}

    func acquire(owner id: UUID, onAvailable: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil else {
            waiters[id] = onAvailable
            return false
        }
        owner = id
        waiters.removeValue(forKey: id)
        return true
    }

    func release(owner id: UUID) {
        lock.lock()
        guard owner == id else {
            lock.unlock()
            return
        }
        owner = nil
        let callbacks = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
