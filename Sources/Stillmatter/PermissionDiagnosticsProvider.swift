import AppKit
import AVFoundation
import EventKit
import UserNotifications
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class PermissionDiagnosticsProvider {
    private let settingsStore: SettingsStore
    private let piIntegration: PiIntegration
    private let transcriptionComponentInstaller: TranscriptionComponentInstaller
    private let hardwareModel: String

    init(
        settingsStore: SettingsStore,
        transcriptionComponentInstaller: TranscriptionComponentInstaller,
        hardwareModel: String,
        piIntegration: PiIntegration = PiIntegration()
    ) {
        self.settingsStore = settingsStore
        self.transcriptionComponentInstaller = transcriptionComponentInstaller
        self.hardwareModel = hardwareModel
        self.piIntegration = piIntegration
    }

    func refresh(completion: @escaping (DiagnosticsSnapshot) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { notificationSettings in
            let snapshot = DiagnosticsSnapshot(
                permissions: self.permissionItems(notificationAuthorizationStatus: notificationSettings.authorizationStatus),
                components: self.componentItems()
            )
            DispatchQueue.main.async {
                completion(snapshot)
            }
        }
    }

    func performAction(for id: String, completion: @escaping (String) -> Void) {
        switch id {
        case "microphone":
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion(granted ? "Microphone access is granted." : "Microphone access is missing. Enable it in System Settings > Privacy & Security > Microphone.")
                }
            }
        case "calendar":
            EKEventStore().requestAccess(to: .event) { granted, error in
                DispatchQueue.main.async {
                    if let error = error {
                        completion("Calendar permission test failed: \(error.localizedDescription)")
                    } else {
                        completion(granted ? "Calendar access is granted." : "Calendar access is missing. Enable it in System Settings > Privacy & Security > Calendars.")
                    }
                }
            }
        case "notifications":
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                if let error = error {
                    DispatchQueue.main.async {
                        completion(self.notificationAuthorizationErrorMessage(error))
                    }
                    return
                }

                guard granted else {
                    DispatchQueue.main.async {
                        completion("Notifications are missing. Enable them in System Settings > Notifications for Stillmatter.")
                    }
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = "Stillmatter notification test"
                content.body = "Notifications are configured."
                let request = UNNotificationRequest(identifier: "stillmatter-test-notification", content: content, trigger: nil)
                center.add(request) { addError in
                    DispatchQueue.main.async {
                        if let addError = addError {
                            completion(self.notificationAuthorizationErrorMessage(addError))
                        } else {
                            completion("Notifications are granted. A test notification was sent.")
                        }
                    }
                }
            }
        case "vaultAccess":
            completion(testDirectoryAccess(settingsStore.settings.stillmatterRootURL, name: "Stillmatter root"))
        case "mediaAccess":
            completion(testDirectoryAccess(settingsStore.settings.recordingMediaURL, name: "recording media location"))
        case "localTranscription":
            if transcriptionComponentInstaller.state().isBusy {
                transcriptionComponentInstaller.cancel()
                completion("Cancellation requested. Stillmatter will remove temporary setup files when the active transfer stops.")
            } else {
                let model = settingsStore.settings.transcriptionModelChoice
                guard TranscriptionModelCompatibility.isSupported(model, hardwareModel: hardwareModel) else {
                    completion("Local faster-whisper transcription is not supported on this Mac.")
                    return
                }
                transcriptionComponentInstaller.install(model: model)
                completion("Local transcription setup started. You can keep using Stillmatter while the model downloads.")
            }
        case "pi":
            DispatchQueue.global(qos: .userInitiated).async { [piIntegration] in
                let message: String
                switch piIntegration.testCodex() {
                case let .available(path, version):
                    message = "Pi/Codex integration is ready. Found pi \(version) at \(path)."
                case let .unavailable(reason):
                    message = reason
                }
                DispatchQueue.main.async { completion(message) }
            }
        default:
            completion("No setup action is available for this item yet.")
        }
    }

    private func permissionItems(notificationAuthorizationStatus: UNAuthorizationStatus) -> [DiagnosticItem] {
        [
            microphoneItem(),
            calendarItem(),
            notificationItem(notificationAuthorizationStatus),
            directoryItem(id: "vaultAccess", title: "Stillmatter root folder access", url: settingsStore.settings.stillmatterRootURL, feature: "vault-backed workspace", actionTitle: "Test Vault"),
            directoryItem(id: "mediaAccess", title: "Recording media folder access", url: settingsStore.settings.recordingMediaURL, feature: "meeting recording storage", actionTitle: "Test Media"),
            launchAtLoginItem()
        ]
    }

    private func componentItems() -> [DiagnosticItem] {
        let piURL = piIntegration.detectedExecutableURL()
        let piStatus: DiagnosticStatus = piURL == nil ? .unavailable : .granted
        let piExplanation = piURL == nil
            ? "App-owned AI work is disabled until the pi CLI is installed and available on PATH. Other settings and local vault features still work."
            : "Found pi CLI at \(piURL!.path). Test Pi verifies the configured OpenAI Codex integration with a bounded tool-free request."

        let selectedModel = settingsStore.settings.transcriptionModelChoice
        var transcriptionItem = TranscriptionComponentDiagnostic.item(
            for: transcriptionComponentInstaller.state(),
            selectedModel: selectedModel,
            installedModel: transcriptionComponentInstaller.installedModelChoice()
        )
        if !TranscriptionModelCompatibility.isSupported(selectedModel, hardwareModel: hardwareModel) {
            transcriptionItem.status = .unavailable
            transcriptionItem.explanation += " Local faster-whisper transcription is unavailable on this Mac."
            transcriptionItem.affectedFeatures = ["automatic meeting transcription"]
            transcriptionItem.actionTitle = nil
        }

        return [
            DiagnosticItem(
                id: "pi",
                title: "Pi CLI detection",
                status: piStatus,
                explanation: piExplanation,
                affectedFeatures: ["AI proposals, summaries, and Contextual Ask"],
                actionTitle: "Test Pi"
            ),
            transcriptionItem
        ]
    }

    private func microphoneItem() -> DiagnosticItem {
        let status: DiagnosticStatus
        let explanation: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            status = .granted
            explanation = "Stillmatter can use the microphone for meeting capture."
        case .denied, .restricted:
            status = .missing
            explanation = "Meeting microphone capture is disabled until access is granted in System Settings."
        case .notDetermined:
            status = .missing
            explanation = "Microphone access has not been requested yet."
        @unknown default:
            status = .unknown
            explanation = "Microphone authorization returned an unknown system state."
        }
        return DiagnosticItem(id: "microphone", title: "Microphone", status: status, explanation: explanation, affectedFeatures: ["meeting microphone recording"], actionTitle: "Test Mic")
    }

    private func calendarItem() -> DiagnosticItem {
        let status: DiagnosticStatus
        let explanation: String
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            status = .granted
            explanation = "Stillmatter can read calendar events for meeting context and briefs."
        case .writeOnly:
            status = .missing
            explanation = "Stillmatter needs read access to use calendar events for meeting context and briefs."
        case .denied, .restricted:
            status = .missing
            explanation = "Calendar-backed meeting context is disabled until calendar access is granted."
        case .notDetermined:
            status = .missing
            explanation = "Calendar access has not been requested yet."
        @unknown default:
            status = .unknown
            explanation = "Calendar authorization returned an unknown system state."
        }
        return DiagnosticItem(id: "calendar", title: "Calendar", status: status, explanation: explanation, affectedFeatures: ["calendar-aware meetings and briefs"], actionTitle: "Test Calendar")
    }

    private func notificationItem(_ authorizationStatus: UNAuthorizationStatus) -> DiagnosticItem {
        let status: DiagnosticStatus
        let explanation: String
        switch authorizationStatus {
        case .authorized, .provisional:
            status = .granted
            explanation = "Stillmatter can show reminders and setup prompts."
        case .denied:
            status = .missing
            explanation = "Reminders and approval prompts are disabled until notifications are enabled."
        case .notDetermined:
            status = .missing
            explanation = "Notification access has not been requested yet."
        @unknown default:
            status = .unknown
            explanation = "Notification authorization returned an unknown system state."
        }
        return DiagnosticItem(id: "notifications", title: "Notifications", status: status, explanation: explanation, affectedFeatures: ["reminders and approval prompts"], actionTitle: "Test Notifications")
    }

    private func directoryItem(id: String, title: String, url: URL?, feature: String, actionTitle: String) -> DiagnosticItem {
        guard let url = url else {
            return DiagnosticItem(id: id, title: title, status: .notConfigured, explanation: "Choose this folder before dependent features can write there.", affectedFeatures: [feature], actionTitle: actionTitle)
        }

        let writable = FileManager.default.isWritableFile(atPath: url.path)
        return DiagnosticItem(
            id: id,
            title: title,
            status: writable ? .granted : .missing,
            explanation: writable ? "Stillmatter can write to \(url.path)." : "Stillmatter cannot currently write to \(url.path). Choose a writable folder or grant access.",
            affectedFeatures: [feature],
            actionTitle: actionTitle
        )
    }

    private func launchAtLoginItem() -> DiagnosticItem {
        let enabled = settingsStore.settings.launchAtLoginEnabled
        return DiagnosticItem(
            id: "launchAtLogin",
            title: "Launch at login",
            status: enabled ? .granted : .notConfigured,
            explanation: enabled ? "Preference is enabled. OS registration is represented here and will be hardened later." : "Stillmatter will not attempt login launch until this setting is enabled.",
            affectedFeatures: [],
            actionTitle: nil
        )
    }

    private func notificationAuthorizationErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == UNErrorDomain && nsError.code == 1 {
            return "Notifications are not available for this launch mode yet. Open the built app bundle with ./scripts/build-app.sh && open .build/Stillmatter.app, then enable Stillmatter in System Settings > Notifications. Other features are unaffected."
        }
        return "Notification test could not complete: \(error.localizedDescription) Enable Stillmatter in System Settings > Notifications."
    }

    private func testDirectoryAccess(_ url: URL?, name: String) -> String {
        guard let url = url else { return "Choose a \(name) before testing access." }
        do {
            let testURL = url.appendingPathComponent(".stillmatter-access-test-\(UUID().uuidString)")
            try "ok".write(to: testURL, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(at: testURL)
            return "Stillmatter can write to the \(name)."
        } catch {
            return "Stillmatter cannot write to the \(name): \(error.localizedDescription)"
        }
    }

}
