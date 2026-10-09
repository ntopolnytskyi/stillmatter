public struct AppLifecyclePolicy {
    public init() {}

    public var shouldTerminateAfterLastWindowClosed: Bool {
        false
    }

    public var shouldCloseMainWindow: Bool {
        false
    }

    public func shouldTerminate(quitRequested: Bool) -> Bool {
        quitRequested
    }
}
