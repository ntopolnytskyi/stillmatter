import Foundation

/// Feature-owned serial reads. Delivery and revision checks run on the main queue.
/// Stale work may finish, but cannot publish after a newer request or disposal.
public final class WorkbenchReadLoader<Value> {
    private let queue: DispatchQueue
    private var revision = 0
    private var active = true
    private let deliver: (Value) -> Void

    public init(label: String, deliver: @escaping (Value) -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.deliver = deliver
    }

    public func reload(_ read: @escaping () -> Value) {
        precondition(Thread.isMainThread)
        guard active else { return }
        revision += 1
        let request = revision
        queue.async { [weak self] in
            guard let self else { return }
            let value = read()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.revision == request else { return }
                self.deliver(value)
            }
        }
    }

    public func invalidate() {
        precondition(Thread.isMainThread)
        revision += 1
    }

    public func stop() {
        precondition(Thread.isMainThread)
        active = false
        revision += 1
    }
}
