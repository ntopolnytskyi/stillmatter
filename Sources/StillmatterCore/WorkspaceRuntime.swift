import Foundation

/// Effective workspace lifetime; SettingsStore owns the memory-only pending request.
/// Call from the UI executor. Every asynchronous publisher captures `generation` and
/// `identity` before work and checks both before presenting its result.
public final class WorkspaceRuntime {
    public private(set) var identity: String?
    private var mediaIdentity: String?
    public private(set) var generation = 0
    public private(set) var isStopped = false
    public private(set) var processingPausedForPendingSwitch = false

    public init() {}

    @discardableResult
    public func activate(_ settings: AppSettings) -> Bool {
        guard !isStopped else { return false }
        let next = settings.stillmatterRootURL?.standardizedFileURL.resolvingSymlinksInPath().path
        let nextMedia = settings.recordingMediaURL?.standardizedFileURL.resolvingSymlinksInPath().path
        guard identity != next || mediaIdentity != nextMedia else { return false }
        generation += 1
        identity = next
        mediaIdentity = nextMedia
        return true
    }

    public func isCurrent(identity: String?, generation: Int) -> Bool {
        !isStopped && self.generation == generation && self.identity == identity
    }

    /// Synchronous handoff barrier. Existing stages finish on their captured root; their
    /// persisted completion is observed before the pending selection is published.
    /// Invalid destinations resume the old schedulers, without changing effective settings.
    @discardableResult
    public func retryPendingSelection(settingsStore: SettingsStore, jobStore: JobStore?,
                                      schedulers: [JobScheduler]) -> Bool {
        guard !isStopped, settingsStore.pendingWorkspace != nil, !settingsStore.workspaceChangeHeld else { return false }
        schedulers.forEach { $0.pauseSynchronously() }
        processingPausedForPendingSwitch = true
        let running = (try? jobStore?.jobs(status: .running)) ?? []
        if running.contains(where: { $0.manifest.workspaceOwner == identity || $0.manifest.workspaceOwner == nil }) {
            settingsStore.reportPendingWorkspaceBlocked("Old-workspace processing is finishing. The change will apply after its current Job stage completes; you may cancel the pending change in Settings.")
            return false
        }
        let applied = settingsStore.applyPendingWorkspace { [self] selection in try validate(selection) }
        if !applied {
            processingPausedForPendingSwitch = false
            schedulers.forEach { $0.start() }
        }
        return applied
    }

    /// A cancelled pending request must never leave the effective workspace paused.
    public func resumeAfterCancellation(settingsStore: SettingsStore, schedulers: [JobScheduler]) {
        guard processingPausedForPendingSwitch, settingsStore.pendingWorkspace == nil,
              !settingsStore.workspaceChangeHeld, !isStopped else { return }
        processingPausedForPendingSwitch = false
        schedulers.forEach { $0.start() }
    }

    public func didActivateSelection() { processingPausedForPendingSwitch = false }

    public func stop() {
        isStopped = true
        generation += 1
        processingPausedForPendingSwitch = false
    }

    /// Validate the requested destination before any old resources are disposed.
    public func validate(_ selection: SettingsStore.WorkspaceSelection) throws {
        for (label, url) in [("workspace", selection.root), ("recording media", selection.media)] {
            guard let url else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
                throw NSError(domain: "Stillmatter.Workspace", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The \(label) directory does not exist: \(url.path)"])
            }
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
    }
}
