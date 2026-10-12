import Foundation
import StillmatterCore

/// Navigation is the only mutable shell state. Domain events do not publish navigation.
public enum ShellChange: Hashable {
    case navigation
    case search
    case recordingStatus
    case jobStatus
    case teamsStatus
    case tasks
    case meetings
    case workspace
    case searchIndex

    /// Filesystem notifications remain domain-scoped, including directory events.
    public static func workspaceChanges(for relativePath: String) -> Set<ShellChange> {
        if relativePath == "Todos" || relativePath.hasPrefix("Todos/") { return [.tasks] }
        return [] // Meetings have an independent revisioned read-model monitor.
    }
}

public final class ShellObservation {
    private var removal: (() -> Void)?

    init(_ removal: @escaping () -> Void) { self.removal = removal }
    public func cancel() {
        removal?()
        removal = nil
    }
    deinit { removal?() }
}

public final class ShellStateStore {
    public var state: ShellState {
        didSet {
            precondition(Thread.isMainThread, "Shell navigation must be changed on the main thread")
            if state.selectedTab != oldValue.selectedTab { publish(.navigation) }
            if state.searchText != oldValue.searchText { publish(.search) }
        }
    }

    private var observers: [UUID: (ShellChange) -> Void] = [:]
    public var observerCount: Int { observers.count }

    public init(state: ShellState = ShellState()) { self.state = state }

    @discardableResult
    public func observe(_ changes: Set<ShellChange>, initial: ShellChange? = nil,
                        _ observer: @escaping (ShellChange) -> Void) -> ShellObservation {
        precondition(Thread.isMainThread, "Shell observation must be installed on the main thread")
        let id = UUID()
        observers[id] = { change in if changes.contains(change) { observer(change) } }
        if let initial, changes.contains(initial) { observer(initial) }
        return ShellObservation { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    public func publish(_ change: ShellChange) {
        precondition(Thread.isMainThread, "Shell events must be delivered on the main thread")
        // An observer may cancel itself during delivery.
        for id in Array(observers.keys) { observers[id]?(change) }
    }
}
