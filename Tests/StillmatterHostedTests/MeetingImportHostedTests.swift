import AppKit
import AVFoundation
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class MeetingImportHostedTests: XCTestCase {
    @MainActor
    func testPreparationFailureCancelAndSuccessUseNativeSharedControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-hosted-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let jobs = try JobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
        let service = MeetingImportService(vault: vault, mediaRootURL: root.appendingPathComponent("media"), jobStore: jobs)
        var callbacks = 0
        let controls = MeetingImportControls(controls: GraphiteFocusControls(), serviceProvider: { service }, onImported: { callbacks += 1 })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controls
        defer { window.orderOut(nil) }
        let unavailable = MeetingImportControls(controls: GraphiteFocusControls(), serviceProvider: { nil }, onImported: {})
        unavailable.chooseFile()
        XCTAssertTrue(unavailable.status.stringValue.contains("Settings"))
        let corrupt = root.appendingPathComponent("corrupt.wav")
        try Data("broken".utf8).write(to: corrupt)
        controls.start(corrupt, service: service)
        XCTAssertFalse(controls.importButton.isEnabled)
        XCTAssertFalse(controls.cancelButton.isHidden)
        controls.start(corrupt, service: service) // A second request cannot replace the active operation.
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in callbacks == 1 }, evaluatedWith: nil)], timeout: 15)
        XCTAssertTrue(controls.status.stringValue.contains("audio"))
        XCTAssertTrue(controls.importButton.isEnabled)
        XCTAssertTrue(controls.cancelButton.isHidden)
        let audio = root.appendingPathComponent("Audio.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        do {
            let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            buffer.floatChannelData![0].update(repeating: 0.1, count: 16_000)
            try writer.write(from: buffer)
        }
        controls.start(audio, service: service)
        controls.cancelImport()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in callbacks == 2 }, evaluatedWith: nil)], timeout: 15)
        XCTAssertTrue(controls.status.stringValue.lowercased().contains("cancel"))
        XCTAssertEqual(try jobs.jobs().count, 0)
        controls.start(audio, service: service)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in callbacks == 3 }, evaluatedWith: nil)], timeout: 15)
        XCTAssertTrue(controls.status.stringValue.contains("Imported Audio.wav"))
        XCTAssertEqual(try jobs.jobs().count, 1)
        XCTAssertTrue(controls.importButton.isEnabled)
        XCTAssertTrue(controls.cancelButton.isHidden)
    }
}
