import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class SharedControlsHostedTests: XCTestCase {
    @MainActor
    func testOneSharedStyleReachesBothRealConsumersAndPreservesTheirState() throws {
        let fixture = try ControlsHostedFixture()
        defer { fixture.cleanup() }
        let controls = GraphiteFocusControls(style: GraphiteFocusControlStyle(
            font: .monospacedSystemFont(ofSize: 17, weight: .medium), controlSize: .small))
        let recording = fixture.recording(controls: controls)
        let settings = fixture.settings(controls: controls)
        recording.refresh(isVisible: true)
        let settingField: NSTextField = try control("settings-search-exclusions", in: settings)
        let settingButton: NSButton = try control("settings-workspace-root", in: settings)
        let settingToggle: NSButton = try control("settings-launch-at-login", in: settings)
        let settingPopup: NSPopUpButton = try control("settings-teams-recording", in: settings)
        let recordingPopup: NSPopUpButton = try control("recording-language", in: recording)
        for consumer in [recording.startButton, recording.noteField, recordingPopup, settingField, settingButton, settingToggle, settingPopup] as [NSControl] {
            XCTAssertEqual(consumer.font, controls.style.font)
            XCTAssertEqual(consumer.controlSize, .small)
        }
        XCTAssertEqual(recording.startButton.keyEquivalent, "\r")
        XCTAssertFalse(recording.noteField.isEnabled)
        XCTAssertEqual(settingField.placeholderString, "Private/**, Archive/Old/**")
        XCTAssertEqual(recording.artifactsDisclosure.bezelStyle, .rounded)
        XCTAssertFalse(recording.artifactsDisclosure.isBordered)
        recording.artifactsDisclosure.performClick(nil)
        XCTAssertFalse(recording.artifactsContainer.isHidden)
        recording.artifactsDisclosure.performClick(nil)
        XCTAssertTrue(recording.artifactsContainer.isHidden)
        let palette = GraphiteFocusPresentation.Colors(environment: .system(window: nil))
        XCTAssertEqual(recording.startButton.bezelColor, palette.accent)
        XCTAssertEqual(recording.stopButton.bezelColor, palette.destructive)
    }

    @MainActor
    func testDisabledLoadingControlsAndPreflightSettingsActionUseNativeSemantics() throws {
        let fixture = try ControlsHostedFixture()
        defer { fixture.cleanup() }
        let recording = fixture.recording()
        recording.refresh(isVisible: true)
        let language: NSPopUpButton = try control("recording-language", in: recording)
        XCTAssertTrue(language.isEnabled)
        recording.render(.init(state: .finalizing, stateTitle: "Finalizing", stateDetail: "Controlled finalization",
            elapsedSeconds: 1, meetingPath: nil, preflight: nil, artifactRows: [], failureMessage: nil,
            isConfigured: true, canRegenerateTranscript: false))
        XCTAssertFalse(recording.startButton.isEnabled)
        XCTAssertFalse(recording.stopButton.isEnabled)
        recording.startButton.performClick(nil)
        XCTAssertEqual(fixture.service.snapshot.state, .idle)
        XCTAssertFalse(recording.noteField.isEnabled)
        let blocked = AudioCapturePreflightReport(items: [.init(id: "microphone", title: "Microphone", status: .blocked,
            detail: "Controlled permission refusal", settingsAction: .openMicrophonePrivacy)])
        recording.render(.init(state: .failed, stateTitle: "Failed", stateDetail: "Controlled refusal", elapsedSeconds: 0,
            meetingPath: nil, preflight: blocked, artifactRows: [], failureMessage: "Controlled permission refusal",
            isConfigured: true, canRegenerateTranscript: false))
        let remediation: NSButton = try control("recording-preflight-microphone", in: recording)
        remediation.performClick(nil)
        XCTAssertEqual(fixture.settingsOpens, 1)
        XCTAssertTrue(recording.errorLabel.stringValue.contains("Controlled permission refusal"))
        let settings = fixture.settings()
        let rebuild: NSButton = try control("settings-rebuild-index", in: settings)
        XCTAssertFalse(rebuild.isEnabled)
    }

    @MainActor
    func testPendingSettingValidationRetainsEffectiveDataAndFocusedRetryControl() throws {
        let fixture = try ControlsHostedFixture()
        defer { fixture.cleanup() }
        let before = fixture.store.settings
        fixture.store.requestWorkspace(.init(root: fixture.root.appendingPathComponent("rejected"), media: nil))
        fixture.store.reportPendingWorkspaceBlocked("Rejected destination")
        var attempts = 0
        let settings = fixture.settings(onRetry: {
            attempts += 1
            fixture.store.applyPendingWorkspace { _ in throw CocoaError(.fileWriteNoPermission) }
        })
        let retry: NSButton = try control("settings-retry-workspace", in: settings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = settings
        XCTAssertTrue(window.makeFirstResponder(retry))
        retry.performClick(nil)
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(fixture.store.pendingWorkspaceError?.contains("Could not switch workspace") == true)
        XCTAssertEqual(fixture.store.settings, before)
        XCTAssertEqual(SettingsStore(userDefaults: fixture.defaults).settings, before)
        XCTAssertTrue(window.firstResponder === retry)
        let cancel: NSButton = try control("settings-cancel-workspace", in: settings)
        cancel.performClick(nil)
        XCTAssertNil(fixture.store.pendingWorkspace)
        XCTAssertEqual(fixture.store.settings, before)
    }

    @MainActor
    private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == identifier, let control = view as? T { return control }
        for child in view.subviews {
            if let result: T = try? control(identifier, in: child) { return result }
        }
        throw NSError(domain: "SharedControlsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing control \(identifier)"])
    }
}

@MainActor
private final class ControlsHostedFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: SettingsStore
    let installer: TranscriptionComponentInstaller
    let service: MeetingCaptureService
    var settingsOpens = 0

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-shared-controls-\(UUID().uuidString)")
        suite = "works.stillmatter.shared-controls.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = SettingsStore(userDefaults: defaults)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        var initial = store.settings
        initial.stillmatterRootURL = workspace
        store.settings = initial
        installer = TranscriptionComponentInstaller(paths: .init(applicationSupportURL: root.appendingPathComponent("support")), acquirer: ControlsNoModelAcquirer())
        service = MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support")), preflight: { .readyForTesting })
    }

    func recording(controls: GraphiteFocusControls = GraphiteFocusControls()) -> CaptureRecordingView {
        CaptureRecordingView(controls: controls, serviceProvider: { self.service }, rootURLProvider: { self.store.settings.stillmatterRootURL },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: { self.settingsOpens += 1 })
    }

    func settings(controls: GraphiteFocusControls = GraphiteFocusControls(), onRetry: (() -> Void)? = nil) -> SettingsFormView {
        SettingsFormView(controls: controls, settingsStore: store, transcriptionComponentInstaller: installer, onRetryPendingWorkspace: onRetry)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct ControlsNoModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
