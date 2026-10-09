import Foundation

/// Owns the configured Capture Session and protects an active session from settings replacement.
/// The builder is the internal seam for platform recorder assembly and local test stand-ins.
public final class CaptureSessionRuntime {
    public private(set) var service: MeetingCaptureService?
    private var configurationKey: String?
    private let build: (AppSettings) -> MeetingCaptureService
    private let onSnapshot: (CaptureSnapshot) -> Void

    public init(
        build: @escaping (AppSettings) -> MeetingCaptureService,
        onSnapshot: @escaping (CaptureSnapshot) -> Void
    ) {
        self.build = build
        self.onSnapshot = onSnapshot
    }

    /// Returns true when callers should refresh their presentation. An unconfigured
    /// root refreshes even when there was no previous session, matching startup behavior.
    @discardableResult
    public func configure(_ settings: AppSettings) -> Bool {
        guard let rootURL = settings.stillmatterRootURL else {
            guard !isActive else { return false }
            service = nil
            configurationKey = nil
            return true
        }
        let key = [
            rootURL.standardizedFileURL.path,
            settings.recordingMediaURL?.standardizedFileURL.path ?? "<no-media>"
        ].joined(separator: "\n")
        guard key != configurationKey, !isActive else { return false }

        let next = build(settings)
        // A replaced session can still emit from its observer. Only the current one
        // may update app attention, status or presentation.
        next.observe { [weak self, weak next] snapshot in
            guard let self, let next, next === self.service else { return }
            self.onSnapshot(snapshot)
        }
        service = next
        configurationKey = key
        return true
    }

    private var isActive: Bool {
        guard let state = service?.snapshot.state else { return false }
        return state == .starting || state == .recording || state == .stopping || state == .finalizing
    }
}
