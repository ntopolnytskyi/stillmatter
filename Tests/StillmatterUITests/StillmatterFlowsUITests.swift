import Foundation
import XCTest
import AVFoundation
import CryptoKit

/// UI seams verified against the isolated native app: icon-rail navigation and workspace views.
final class StillmatterFlowsUITests: XCTestCase {
    var app: XCUIApplication!
    var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-ui-\(UUID().uuidString)", isDirectory: true)
        let workspace = fixtureRoot.appendingPathComponent("workspace", isDirectory: true)
        let support = fixtureRoot.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let media = fixtureRoot.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] = media.path
        app.launchEnvironment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] = workspace.path
        app.launchEnvironment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] = support.path
        app.launchEnvironment["STILLMATTER_VALIDATION_PRESERVE_SETTINGS"] = "1"
        app.launchEnvironment["STILLMATTER_VALIDATION_SETTINGS_SNAPSHOT_PATH"] = fixtureRoot.appendingPathComponent("settings.json").path
        app.launch()
        // macOS may restore a stale UI-test bundle after an interrupted run.
        let restore = app.dialogs.buttons["Don’t Reopen"].firstMatch
        if restore.waitForExistence(timeout: 3) { restore.click() }
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15), app.debugDescription)
    }

    override func tearDownWithError() throws {
        if let app, (testRun?.failureCount ?? 0) > 0 {
            attachMeetingScreenshot("Failure")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Accessibility tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
        if let fixtureRoot {
            let suite = "works.stillmatter.validation.\(fixtureRoot.lastPathComponent)"
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        if let fixtureRoot { try FileManager.default.removeItem(at: fixtureRoot) }
    }

    func testPlayableRecordingHasFullWidthSeekControl() throws {
        app.terminate()
        let directory = fixtureRoot.appendingPathComponent("workspace/Meetings/audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldMedia = fixtureRoot.appendingPathComponent("workspace/OldMedia/audio")
        try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
        let audio = oldMedia.appendingPathComponent("mic.caf")
        let metadata = oldMedia.appendingPathComponent("mic.json")
        let bundle = oldMedia.appendingPathComponent("recording-bundle.json")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 48_000)
            for _ in 0..<8 { try writer.write(from: buffer) }
        }
        try Data("{}".utf8).write(to: metadata)
        let hash = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
        let track: [String: Any] = ["role": "microphone", "status": "partial", "preferredAudioFilePath": audio.path,
            "recoveryFilePath": audio.path, "finalFilePath": oldMedia.appendingPathComponent("missing.m4a").path,
            "metadataFilePath": metadata.path, "recoveryFileExists": true, "finalFileExists": false,
            "metadataFileExists": true, "recoveryFileSHA256": hash, "durationSeconds": 8.0,
            "codec": "caf", "sampleRate": 48_000.0, "channelCount": 1, "diagnostics": []]
        let sidecar: [String: Any] = ["schemaVersion": 1, "captureSessionID": "audio",
            "meetingRelativePath": "Meetings/audio/meeting.md", "bundleFilePath": bundle.path,
            "finalizedAt": "2026-10-07T17:35:00Z", "reason": "recovery", "state": "partial",
            "mic": track, "diagnostics": []]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: bundle)
        try Data("---\ntitle: Playable meeting\ncapture_session_id: audio\nrecording_bundle: \(bundle.path)\n---\n# Playable meeting\n".utf8)
            .write(to: directory.appendingPathComponent("meeting.md"))
        let newMedia = fixtureRoot.appendingPathComponent("workspace/RecordingMedia/2026")
        try FileManager.default.createDirectory(at: newMedia, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldMedia, to: newMedia.appendingPathComponent("audio"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        app.launchEnvironment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] = newMedia.deletingLastPathComponent().path
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15))
        app.buttons["sidebar-meetings"].click()
        let recording = app.tables["Meetings"].staticTexts["Playable meeting"].firstMatch
        XCTAssertTrue(recording.waitForExistence(timeout: 10))
        recording.click()
        app.radioButtons["Transcript"].click()
        let slider = app.sliders["Meeting audio position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertTrue(slider.isEnabled)
        XCTAssertGreaterThan(slider.frame.width, 250, "The seek track must not collapse inside the audio stack")
        attachMeetingScreenshot("Native playable recording before seek")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0:06 / 0:08")).firstMatch.waitForExistence(timeout: 5),
                      "Clicking three quarters of the track must seek the selected recording")
        attachMeetingScreenshot("Native playable recording after seek")
        let beforeArrow = String(describing: try XCTUnwrap(slider.value))
        slider.typeKey(.rightArrow, modifierFlags: [])
        let movedForward = NSPredicate { _, _ in slider.value.map { String(describing: $0) } != beforeArrow }
        expectation(for: movedForward, evaluatedWith: slider)
        waitForExpectations(timeout: 5)
        let afterRight = String(describing: try XCTUnwrap(slider.value))
        slider.typeKey(.leftArrow, modifierFlags: [])
        let movedBack = NSPredicate { _, _ in slider.value.map { String(describing: $0) } != afterRight }
        expectation(for: movedBack, evaluatedWith: slider)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(String(describing: try XCTUnwrap(slider.value)), beforeArrow)
        XCTAssertTrue(app.buttons["Play Meeting audio"].exists, "Seeking must preserve paused playback")
        app.buttons["Play Meeting audio"].click()
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5),
                      "Seeking while playing must move the playhead rather than resetting it")
        XCTAssertTrue(app.buttons["Pause Meeting audio"].waitForExistence(timeout: 5))
        app.buttons["Pause Meeting audio"].click()
    }

    func testTranscriptionLanguageSelectionPersistsAcrossNativeAppRestart() throws {
        app.buttons["sidebar-recording"].click()
        let language = app.popUpButtons["recording-language"]
        XCTAssertTrue(language.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: language)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(language.value as? String, "Auto (mixed-language quality unverified)")

        language.click()
        let english = app.menuItems["English"]
        XCTAssertTrue(english.waitForExistence(timeout: 5), app.debugDescription)
        english.click()
        XCTAssertEqual(language.value as? String, "English")
        XCTAssertEqual(try settingsSnapshotLanguage(), "en", "The application SettingsStore should observe the selected language")

        app.terminate()
        app.launchEnvironment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] = fixtureRoot.appendingPathComponent("media").path
        app.launchEnvironment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] = fixtureRoot.appendingPathComponent("workspace").path
        app.launchEnvironment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] = fixtureRoot.appendingPathComponent("support").path
        app.launchEnvironment["STILLMATTER_VALIDATION_PRESERVE_SETTINGS"] = "1"
        app.launchEnvironment["STILLMATTER_VALIDATION_SETTINGS_SNAPSHOT_PATH"] = fixtureRoot.appendingPathComponent("settings.json").path
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["sidebar-recording"].click()
        let reopenedLanguage = app.popUpButtons["recording-language"]
        XCTAssertTrue(reopenedLanguage.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: reopenedLanguage)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(try settingsSnapshotLanguage(), "en", "The application should reload the persisted transcription language")
        XCTAssertEqual(reopenedLanguage.value as? String, "English")
    }

    private func settingsSnapshotLanguage() throws -> String? {
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("settings.json"))
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return settings["transcriptionLanguage"] as? String
    }

    func attachMeetingScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
