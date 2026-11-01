import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

/// Runs unchanged against the pre-migration forms and their shared-control replacements.
final class ControlBehaviorRegressionTests: XCTestCase {
    @MainActor
    func testRecordingControlsStartStopAndPersistLiveNoteWithoutDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-controls-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let service = MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support),
            preflight: { .readyForTesting })
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        view.refresh(isVisible: true)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertEqual(view.startButton.keyEquivalent, "\r")
        view.startButton.performClick(nil)
        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertFalse(view.startButton.isEnabled)
        XCTAssertTrue(view.stopButton.isEnabled)
        let path = try XCTUnwrap(service.snapshot.meetingRelativePath)
        view.noteField.stringValue = "Synthetic live note through the real field"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(view.noteField.action), to: view.noteField.target, from: view.noteField))
        XCTAssertTrue(try String(contentsOf: workspace.appendingPathComponent(path)).contains("Synthetic live note through the real field"))
        XCTAssertEqual(view.noteField.stringValue, "")
        view.stopButton.performClick(nil)
        let stopped = expectation(for: NSPredicate { _, _ in service.snapshot.state == .idle }, evaluatedWith: service)
        await fulfillment(of: [stopped], timeout: 10)
        view.refresh(isVisible: true)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertFalse(view.stopButton.isEnabled)
        XCTAssertFalse(view.noteField.isEnabled)
    }

    @MainActor
    func testSettingsFieldAndTogglePersistThroughAReopenedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-settings-baseline-\(UUID().uuidString)")
        let suite = "works.stillmatter.controls.baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = SettingsStore(userDefaults: defaults)
        let installer = TranscriptionComponentInstaller(paths: TranscriptionComponentPaths(applicationSupportURL: root), acquirer: NoModelAcquirer())
        let view = SettingsFormView(settingsStore: store, transcriptionComponentInstaller: installer)
        let controls = descendants(of: view)
        let field = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Private/**, Archive/Old/**" })
        field.stringValue = "Private/**, Synthetic/**"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
        let toggle = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Launch Stillmatter at login" })
        let prior = store.settings.launchAtLoginEnabled
        toggle.performClick(nil)
        XCTAssertEqual(store.settings.launchAtLoginEnabled, !prior)
        let reopened = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reopened.settings.searchExcludedPatterns, ["Private/**", "Synthetic/**"])
        XCTAssertEqual(reopened.settings.launchAtLoginEnabled, !prior)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private struct NoModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
