import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class ShellStateStore {
    var state: ShellState {
        didSet { notifyObservers() }
    }

    private var observers: [() -> Void] = []

    init(state: ShellState = ShellState()) {
        self.state = state
    }

    func observe(_ observer: @escaping () -> Void) {
        observers.append(observer)
        observer()
    }

    func refresh() {
        notifyObservers()
    }

    private func notifyObservers() {
        observers.forEach { $0() }
    }
}
