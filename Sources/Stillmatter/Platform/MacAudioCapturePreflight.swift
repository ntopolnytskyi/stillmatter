import AVFoundation
import CoreGraphics
#if SWIFT_PACKAGE
import StillmatterCore
#endif

enum MacAudioCapturePreflight {
    private static let screenCapturePermission = CapturePermissionRequestGate(
        hasAccess: { CGPreflightScreenCaptureAccess() },
        requestAccess: { CGRequestScreenCaptureAccess() }
    )

    static func makeChecker(settingsStore: SettingsStore) -> AudioCapturePreflightChecker {
        AudioCapturePreflightChecker(
            microphoneAuthorization: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .authorized
                case .notDetermined: return .notDetermined
                case .denied: return .denied
                case .restricted: return .restricted
                @unknown default: return .unknown
                }
            },
            microphoneDeviceName: {
                AVCaptureDevice.default(for: .audio)?.localizedName
            },
            systemAudioItem: {
                guard #available(macOS 13.0, *) else {
                    return AudioCapturePreflightItem(
                        id: "system-audio",
                        title: "System audio",
                        status: .degraded,
                        detail: "Separate system-audio capture requires macOS 13 or newer; this Capture Session will continue microphone-only."
                    )
                }
                guard screenCapturePermission.resolve() == .granted else {
                    return AudioCapturePreflightItem(
                        id: "system-audio",
                        title: "System audio",
                        status: .degraded,
                        detail: "Screen & System Audio Recording permission was not granted. Capture will remain microphone-only; enable Stillmatter in System Settings to add a separate system track.",
                        settingsAction: .openScreenRecordingPrivacy
                    )
                }
                return .ready(
                    id: "system-audio",
                    title: "System audio",
                    detail: "Screen & System Audio Recording permission is available for a separate system track."
                )
            },
            mediaOutputURL: {
                settingsStore.settings.recordingMediaURL
            }
        )
    }
}
