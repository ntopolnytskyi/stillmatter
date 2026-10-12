import Foundation

public final class SettingsStore {
    public static let defaultStorageKey = "works.stillmatter.settings.v1"

    /// Persist only effective settings; a pending workspace is never activated on relaunch.
    public var settings: AppSettings {
        get { effectiveSettings }
        set {
            var next = newValue
            let requested = WorkspaceSelection(root: next.stillmatterRootURL, media: next.recordingMediaURL)
            if workspaceChangeHeld && requested != workspaceSelection {
                pendingWorkspace = requested
                pendingWorkspaceError = nil
                next.stillmatterRootURL = effectiveSettings.stillmatterRootURL
                next.recordingMediaURL = effectiveSettings.recordingMediaURL
            }
            if requested != workspaceSelection && !workspaceChangeHeld {
                do { try onWorkspaceWillChange?(next) }
                catch {
                    pendingWorkspace = requested
                    pendingWorkspaceError = "Could not switch workspace: \(error). Check the destination in Settings and retry or cancel the pending change."
                    next.stillmatterRootURL = effectiveSettings.stillmatterRootURL
                    next.recordingMediaURL = effectiveSettings.recordingMediaURL
                }
            }
            effectiveSettings = next
            persist()
            notifyObservers()
        }
    }

    public struct WorkspaceSelection: Equatable {
        public let root: URL?
        public let media: URL?
        public init(root: URL?, media: URL?) { self.root = root; self.media = media }
    }

    /// Synchronous handoff before publishing a new effective workspace to observers.
    /// The application installs this on its UI executor; tests may omit it.
    public var onWorkspaceWillChange: ((AppSettings) throws -> Void)?
    private var effectiveSettings: AppSettings
    public private(set) var pendingWorkspace: WorkspaceSelection?
    public private(set) var pendingWorkspaceError: String?
    public var workspaceChangeHeld = false
    public var workspaceSelection: WorkspaceSelection {
        WorkspaceSelection(root: settings.stillmatterRootURL, media: settings.recordingMediaURL)
    }

    public func requestWorkspace(_ selection: WorkspaceSelection) {
        pendingWorkspace = selection
        pendingWorkspaceError = nil
        notifyObservers()
    }

    public func reportPendingWorkspaceFailure(_ message: String) {
        reportPendingWorkspaceBlocked("Recording did not finish safely: \(message). Inspect Recording and recovery, then retry or cancel the pending workspace change.")
    }

    public func reportPendingWorkspaceBlocked(_ message: String) {
        guard pendingWorkspace != nil else { return }
        pendingWorkspaceError = message
        notifyObservers()
    }

    public func cancelPendingWorkspace() {
        pendingWorkspace = nil
        pendingWorkspaceError = nil
        notifyObservers()
    }

    /// Validation precedes any effective configuration change. Failure retains the request.
    @discardableResult
    public func applyPendingWorkspace(validate: (WorkspaceSelection) throws -> Void) -> Bool {
        guard let pendingWorkspace, !workspaceChangeHeld else { return false }
        do { try validate(pendingWorkspace) }
        catch {
            pendingWorkspaceError = "Could not switch workspace: \(error). Check the destination in Settings and retry or cancel the pending change."
            notifyObservers()
            return false
        }
        self.pendingWorkspace = nil
        pendingWorkspaceError = nil
        var next = settings
        next.stillmatterRootURL = pendingWorkspace.root
        next.recordingMediaURL = pendingWorkspace.media
        settings = next
        // Preparation can fail independently of destination validation. In that case
        // the setter restores the pending selection and retains the old effective root.
        return workspaceSelection == pendingWorkspace && self.pendingWorkspace == nil
    }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var observers: [UUID: (AppSettings) -> Void] = [:]
    public var observerCount: Int { observers.count }

    public init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = SettingsStore.defaultStorageKey
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.effectiveSettings = SettingsStore.load(from: userDefaults, storageKey: storageKey)
    }

    public func observe(_ observer: @escaping (AppSettings) -> Void) {
        _ = observeScoped(observer)
    }

    @discardableResult
    public func observeScoped(_ observer: @escaping (AppSettings) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(settings)
        return id
    }

    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    public func reset() {
        settings = AppSettings()
    }

    private func notifyObservers() {
        for id in Array(observers.keys) { observers[id]?(settings) }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(effectiveSettings)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            assertionFailure("Failed to persist Stillmatter settings: \(error)")
        }
    }

    private static func load(from userDefaults: UserDefaults, storageKey: String) -> AppSettings {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return AppSettings()
        }

        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            return AppSettings()
        }
    }
}
