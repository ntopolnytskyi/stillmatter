import Foundation

public enum AudioCapturePreflightStatus: String, Codable, Equatable {
    case ready
    case degraded
    case blocked
}

public enum AudioCaptureSettingsAction: String, Codable, Equatable {
    case openMicrophonePrivacy
    case openScreenRecordingPrivacy
    case chooseMediaFolder
    case freeDiskSpace
}

public struct AudioCapturePreflightItem: Codable, Equatable {
    public let id: String
    public let title: String
    public let status: AudioCapturePreflightStatus
    public let detail: String
    public let settingsAction: AudioCaptureSettingsAction?

    public init(
        id: String,
        title: String,
        status: AudioCapturePreflightStatus,
        detail: String,
        settingsAction: AudioCaptureSettingsAction? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.settingsAction = settingsAction
    }

    public static func ready(id: String, title: String, detail: String) -> AudioCapturePreflightItem {
        AudioCapturePreflightItem(id: id, title: title, status: .ready, detail: detail)
    }
}

public struct AudioCapturePreflightReport: Codable, Equatable {
    public let items: [AudioCapturePreflightItem]

    public init(items: [AudioCapturePreflightItem]) {
        self.items = items
    }

    public var canStart: Bool {
        !items.contains { $0.status == .blocked }
    }

    public var summary: String {
        let relevant = items.filter { $0.status != .ready }
        if relevant.isEmpty { return "Audio capture preflight passed." }
        return relevant.map { "\($0.title): \($0.detail)" }.joined(separator: " ")
    }

    public var hasSettingsActions: Bool {
        items.contains { $0.settingsAction != nil }
    }

    /// Explicit all-ready report for callers whose environment has already been validated.
    public static let readyForTesting = AudioCapturePreflightReport(items: [
        .ready(id: "test-environment", title: "Test environment", detail: "Audio capture prerequisites are ready.")
    ])
}

public enum MicrophoneAuthorization: Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unknown
}

public enum CapturePermissionRequestResult: Equatable {
    case granted
    case denied
}

/// Requests an unavailable macOS capture permission at most once per app session. A newly
/// granted permission is used immediately; an already-granted permission never requests again.
public final class CapturePermissionRequestGate {
    private let hasAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let lock = NSLock()
    private var requestAttempted = false

    public init(hasAccess: @escaping () -> Bool, requestAccess: @escaping () -> Bool) {
        self.hasAccess = hasAccess
        self.requestAccess = requestAccess
    }

    public func resolve() -> CapturePermissionRequestResult {
        if hasAccess() { return .granted }
        lock.lock()
        defer { lock.unlock() }
        if hasAccess() { return .granted }
        guard !requestAttempted else { return .denied }
        requestAttempted = true
        return requestAccess() ? .granted : .denied
    }
}

/// Evaluates the capture prerequisites while leaving macOS permission and device discovery
/// behind injected providers. This keeps the fail-closed policy deterministic and testable.
public final class AudioCapturePreflightChecker {
    public typealias WriteProbe = (URL) throws -> Void

    private let microphoneAuthorization: () -> MicrophoneAuthorization
    private let microphoneDeviceName: () -> String?
    private let systemAudioItem: () -> AudioCapturePreflightItem
    private let mediaOutputURL: () -> URL?
    private let availableCapacity: (URL) throws -> Int64
    private let writeProbe: WriteProbe
    private let minimumAvailableBytes: Int64

    public init(
        microphoneAuthorization: @escaping () -> MicrophoneAuthorization,
        microphoneDeviceName: @escaping () -> String?,
        systemAudioItem: @escaping () -> AudioCapturePreflightItem,
        mediaOutputURL: @escaping () -> URL?,
        minimumAvailableBytes: Int64 = 1_073_741_824,
        availableCapacity: ((URL) throws -> Int64)? = nil,
        writeProbe: WriteProbe? = nil
    ) {
        self.microphoneAuthorization = microphoneAuthorization
        self.microphoneDeviceName = microphoneDeviceName
        self.systemAudioItem = systemAudioItem
        self.mediaOutputURL = mediaOutputURL
        self.minimumAvailableBytes = minimumAvailableBytes
        self.availableCapacity = availableCapacity ?? AudioCapturePreflightChecker.defaultAvailableCapacity
        self.writeProbe = writeProbe ?? AudioCapturePreflightChecker.defaultWriteProbe
    }

    public func check() -> AudioCapturePreflightReport {
        AudioCapturePreflightReport(items: [
            microphonePermissionItem(),
            microphoneDeviceItem(),
            systemAudioItem(),
            mediaOutputItem()
        ])
    }

    private func microphonePermissionItem() -> AudioCapturePreflightItem {
        switch microphoneAuthorization() {
        case .authorized:
            return .ready(id: "microphone-permission", title: "Microphone permission", detail: "Microphone access is granted.")
        case .notDetermined:
            return blockedMicrophone("Microphone access has not been granted. Open Settings and use Test Mic to request access.")
        case .denied:
            return blockedMicrophone("Enable Stillmatter in System Settings > Privacy & Security > Microphone.")
        case .restricted:
            return blockedMicrophone("Microphone access is restricted by this Mac's policy.")
        case .unknown:
            return blockedMicrophone("macOS returned an unknown microphone permission state.")
        }
    }

    private func blockedMicrophone(_ detail: String) -> AudioCapturePreflightItem {
        AudioCapturePreflightItem(
            id: "microphone-permission",
            title: "Microphone permission",
            status: .blocked,
            detail: detail,
            settingsAction: .openMicrophonePrivacy
        )
    }

    private func microphoneDeviceItem() -> AudioCapturePreflightItem {
        guard let name = microphoneDeviceName(), !name.isEmpty else {
            return AudioCapturePreflightItem(
                id: "microphone-device",
                title: "Microphone device",
                status: .blocked,
                detail: "No audio input device is available. Connect or enable a microphone before recording."
            )
        }
        return .ready(id: "microphone-device", title: "Microphone device", detail: "Selected input: \(name).")
    }

    private func mediaOutputItem() -> AudioCapturePreflightItem {
        guard let url = mediaOutputURL() else {
            return AudioCapturePreflightItem(
                id: "media-output",
                title: "Media output",
                status: .blocked,
                detail: "Choose a recording media location in Settings.",
                settingsAction: .chooseMediaFolder
            )
        }

        do {
            try writeProbe(url)
            let bytes = try availableCapacity(url)
            guard bytes >= minimumAvailableBytes else {
                return AudioCapturePreflightItem(
                    id: "media-capacity",
                    title: "Media capacity",
                    status: .blocked,
                    detail: "The recording media location has less than \(Self.gigabytes(minimumAvailableBytes)) GB available. Free space or choose another folder.",
                    settingsAction: .freeDiskSpace
                )
            }
            return .ready(
                id: "media-output",
                title: "Media output",
                detail: "\(url.path) is writable with \(Self.gigabytes(bytes)) GB available."
            )
        } catch {
            return AudioCapturePreflightItem(
                id: "media-output",
                title: "Media output",
                status: .blocked,
                detail: "Stillmatter cannot write to \(url.path): \(error.localizedDescription)",
                settingsAction: .chooseMediaFolder
            )
        }
    }

    private static func defaultAvailableCapacity(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity else {
            throw CocoaError(.fileReadUnknown)
        }
        return Int64(capacity)
    }

    private static func defaultWriteProbe(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        let probeURL = url.appendingPathComponent(".stillmatter-capture-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: probeURL) }
        try Data("preflight".utf8).write(to: probeURL, options: .atomic)
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_073_741_824)
    }
}
