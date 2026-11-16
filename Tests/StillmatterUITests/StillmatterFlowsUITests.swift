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

    func testImportPickerCancelInvalidAudioAndPersistedOrdinaryMeeting() throws {
        let original = fixtureRoot.appendingPathComponent("Imported sample.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: original, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            buffer.floatChannelData![0].update(repeating: 0.1, count: 16_000)
            try writer.write(from: buffer)
        }
        let bytes = try Data(contentsOf: original)
        let button = app.buttons["meetings-import"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        XCTAssertTrue(app.windows["open-panel"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        let corrupt = fixtureRoot.appendingPathComponent("Broken.wav")
        try Data("broken".utf8).write(to: corrupt)
        func choose(_ url: URL) {
            button.click()
            app.typeKey("g", modifierFlags: [.command, .shift])
            let location = app.sheets.textFields.firstMatch
            XCTAssertTrue(location.waitForExistence(timeout: 5), app.debugDescription)
            location.typeText(url.path)
            app.typeKey(.return, modifierFlags: [])
            let confirm = app.windows["open-panel"].buttons["Import"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            confirm.click()
        }
        choose(corrupt)
        let status = app.staticTexts["meetings-import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let failed = NSPredicate { _, _ in status.label.contains("no supported audio") }
        expectation(for: failed, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
        choose(original)
        expectation(for: NSPredicate { _, _ in status.label.contains("Imported Imported sample.wav") }, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        let importedRow = app.tables["Meetings"].staticTexts["Imported sample"].firstMatch
        XCTAssertTrue(importedRow.waitForExistence(timeout: 10), app.debugDescription)
        importedRow.click()
        let tabs = app.radioGroups["meeting-page-selector"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(tabs.radioButtons.count, 5)
        for title in ["Summary", "Action Items", "Open Items", "My Notes", "Transcript"] {
            XCTAssertTrue(tabs.radioButtons[title].exists)
        }
        tabs.radioButtons["Transcript"].click()
        XCTAssertEqual(tabs.radioButtons["Transcript"].value as? Int, 1)
        XCTAssertTrue(app.staticTexts["No Transcript available."].waitForExistence(timeout: 5))
        app.typeKey(.leftArrow, modifierFlags: [.command, .option])
        XCTAssertEqual(tabs.radioButtons["My Notes"].value as? Int, 1)
        app.terminate()
        let workspace = fixtureRoot.appendingPathComponent("workspace").resolvingSymlinksInPath()
        let namespace = SHA256.hash(data: Data(workspace.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let interrupted = fixtureRoot.appendingPathComponent("media/Imports/\(namespace)/import-corrupt-recovery")
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try Data("damaged preparation journal".utf8).write(to: interrupted.appendingPathComponent("import-intent.json"))
        app.launch()
        XCTAssertTrue(app.staticTexts["An interrupted import needs attention"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.tables["Meetings"].staticTexts["Imported sample"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.tables["Meetings"].cells.count, 1)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
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
            for frame in 0..<48_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
            for _ in 0..<8 { try writer.write(from: buffer) }
        }
        try Data("{}".utf8).write(to: metadata)
        let hash = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
        let track: [String: Any] = ["role": "microphone", "status": "partial", "preferredAudioFilePath": audio.path,
            "recoveryFilePath": audio.path, "finalFilePath": oldMedia.appendingPathComponent("missing.m4a").path,
            "metadataFilePath": metadata.path, "recoveryFileExists": true, "finalFileExists": false,
            "metadataFileExists": true, "recoveryFileSHA256": hash, "durationSeconds": 8.0,
            "codec": "caf", "sampleRate": 48_000.0, "channelCount": 1, "diagnostics": []]
        let systemAudio = oldMedia.appendingPathComponent("system.caf")
        let systemMetadata = oldMedia.appendingPathComponent("system.json")
        do {
            let writer = try AVAudioFile(forWriting: systemAudio, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.3)) * 0.4 }
            for _ in 0..<8 { try writer.write(from: buffer) }
        }
        try Data("{}".utf8).write(to: systemMetadata)
        var systemTrack = track
        systemTrack["role"] = "system-audio"
        systemTrack["preferredAudioFilePath"] = systemAudio.path
        systemTrack["recoveryFilePath"] = systemAudio.path
        systemTrack["finalFilePath"] = oldMedia.appendingPathComponent("missing-system.m4a").path
        systemTrack["metadataFilePath"] = systemMetadata.path
        systemTrack["recoveryFileSHA256"] = SHA256.hash(data: try Data(contentsOf: systemAudio)).map { String(format: "%02x", $0) }.joined()
        let sidecar: [String: Any] = ["schemaVersion": 1, "captureSessionID": "audio",
            "meetingRelativePath": "Meetings/audio/meeting.md", "bundleFilePath": bundle.path,
            "finalizedAt": "2026-10-07T17:35:00Z", "reason": "recovery", "state": "partial",
            "mic": track, "system": systemTrack, "diagnostics": []]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: bundle)
        try Data("---\ntitle: Playable meeting\ncapture_session_id: audio\nrecording_bundle: \(bundle.path)\n---\n# Playable meeting\n".utf8)
            .write(to: directory.appendingPathComponent("meeting.md"))
        let transcript: [String: Any] = ["schema_version": 1, "capture_session_id": "audio",
            "meeting_relative_path": "Meetings/audio/meeting.md", "language": "en", "detected_languages": ["en"],
            "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
            "audio_sources": [], "diagnostics": [], "segments": [
                ["id": "early", "start": 2.0, "end": 3.0, "text": "Early synthetic speech", "language": "en", "track": "microphone", "speaker": "Me"],
                ["id": "late", "start": 6.0, "end": 7.0, "text": "Later synthetic speech", "language": "en", "track": "system-audio", "speaker": "Guest"]]]
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject: transcript).write(to: transcriptURL)
        // Use the public serialized extraction format, with all four marker categories.
        let evidence: [String: Any] = ["segment_id": "early", "start_seconds": 2.0, "end_seconds": 3.0]
        let outcome: [String: Any] = ["id": "marker", "text": "Fixture annotation", "citations": [evidence]]
        let extraction: [String: Any] = ["schema_version": 1, "meeting": "Meetings/audio/meeting.md", "transcript": "Meetings/audio/transcript.json",
            "decisions": [outcome], "my_action_items": [outcome], "other_action_items": [], "open_questions": [outcome]]
        try JSONSerialization.data(withJSONObject: extraction).write(to: directory.appendingPathComponent("summary-extraction.json"))
        let transcriptBefore = try Data(contentsOf: transcriptURL)
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
        let markers = app.menuButtons["meeting-playback-markers"]
        XCTAssertTrue(markers.isEnabled)
        markers.click()
        app.typeKey("q", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play Meeting audio"].exists)
        let actions = app.menuButtons["transcript-actions-early"]
        actions.click()
        app.typeKey("j", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Play Meeting audio"].exists)

        app.buttons["Play Meeting audio"].click()
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5),
                      "Seeking while playing must move the playhead rather than resetting it")
        XCTAssertTrue(app.buttons["Pause Meeting audio"].waitForExistence(timeout: 5))
        slider.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(app.buttons["Pause Meeting audio"].exists, "Keyboard seeking must preserve playing intent")
        app.buttons["Pause Meeting audio"].click()
        let retainedMic = newMedia.appendingPathComponent("audio/mic.caf")
        let retainedSystem = newMedia.appendingPathComponent("audio/system.caf")
        let micBefore = try Data(contentsOf: retainedMic)
        let systemBefore = try Data(contentsOf: retainedSystem)
        let doorway = directory.appendingPathComponent("meeting.md")
        let doorwayBefore = try Data(contentsOf: doorway)
        let tracks = app.popUpButtons["meeting-playback-track"]
        let speed = app.popUpButtons["meeting-playback-speed"]
        XCTAssertFalse(tracks.exists, "Track-isolation selection has been removed")
        XCTAssertFalse(app.buttons["meeting-playback-forward"].exists)
        XCTAssertFalse(app.buttons["meeting-playback-backward"].exists)
        speed.click()
        app.menuItems["2×"].click()
        XCTAssertEqual(speed.value as? String, "2×")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:00 / 0:08")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meeting-playback-next-marker"].exists)
        XCTAssertFalse(app.buttons["meeting-playback-previous-marker"].exists)
        XCTAssertFalse(app.staticTexts["S Speech · D Decisions · A Actions · Q Questions"].exists)
        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcriptBefore)
        // Native button clicks need not move keyboard focus from the Listing.
        // These shortcuts are scoped to the Transcript controls, so focus the slider.
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        slider.typeKey("p", modifierFlags: .option)
        XCTAssertTrue(app.buttons["Pause Meeting audio"].waitForExistence(timeout: 5))
        app.buttons["Pause Meeting audio"].click()
        app.buttons["transcript-time-early"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5))
        for tab in ["Summary", "Action Items", "Open Items", "My Notes"] {
            app.radioButtons[tab].click()
            XCTAssertFalse(speed.exists, "Player must only appear in Transcript")
        }
        app.radioButtons["Transcript"].click()
        XCTAssertFalse(tracks.exists)
        XCTAssertEqual(speed.value as? String, "2×")
        let find = app.searchFields["meeting-transcript-search"]
        find.click()
        find.typeKey("p", modifierFlags: .option)
        XCTAssertTrue(app.buttons["Play Meeting audio"].exists, "Text input must not start playback")
        XCTAssertFalse(tracks.exists)
        XCTAssertEqual(try Data(contentsOf: retainedMic), micBefore)
        XCTAssertEqual(try Data(contentsOf: retainedSystem), systemBefore)
        XCTAssertEqual(try Data(contentsOf: doorway), doorwayBefore)
        let refreshedDoorway = Data(String(decoding: doorwayBefore, as: UTF8.self).replacingOccurrences(of: "Playable meeting", with: "Refreshed meeting").utf8)
        try refreshedDoorway.write(to: doorway)
        XCTAssertTrue(app.tables["Meetings"].staticTexts["Refreshed meeting"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(tracks.exists)
        XCTAssertEqual(speed.value as? String, "2×")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:02 / 0:08")).firstMatch.exists,
                      "Unrelated document refresh preserves the paused source position")

        // Another Meeting must clear the previous transport, including queued callbacks.
        app.terminate()
        let micClock = """
        {"audioClockSpans":[
          {"hostStart":10,"hostEnd":11,"startFrame":0,"endFrame":48000,"sampleRate":48000,"generation":1},
          {"hostStart":13,"hostEnd":20,"startFrame":48000,"endFrame":384000,"sampleRate":48000,"generation":2}
        ]}
        """
        let systemClock = """
        {"audioClockSpans":[
          {"hostStart":10,"hostEnd":18,"startFrame":0,"endFrame":384000,"sampleRate":48000,"generation":1}
        ]}
        """
        try Data(micClock.utf8).write(to: newMedia.appendingPathComponent("audio/mic.json"))
        try Data(systemClock.utf8).write(to: newMedia.appendingPathComponent("audio/system.json"))
        let missing = fixtureRoot.appendingPathComponent("workspace/Meetings/missing")
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        try Data("---\ntitle: Missing evidence\n---\n# Missing evidence\n".utf8).write(to: missing.appendingPathComponent("meeting.md"))
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15))
        app.buttons["sidebar-meetings"].click()
        let first = app.tables["Meetings"].staticTexts["Refreshed meeting"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        app.radioButtons["Transcript"].click()
        let afterGap = app.buttons["transcript-time-early"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: afterGap)
        waitForExpectations(timeout: 10)
        afterGap.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:04 / 0:10")).firstMatch.waitForExistence(timeout: 5),
                      "The file timestamp at two seconds maps to Meeting time four seconds after the capture gap")
        XCTAssertEqual(try Data(contentsOf: transcriptURL), transcriptBefore)
        XCTAssertEqual(try Data(contentsOf: retainedMic), micBefore)
        speed.click()
        let slowPlayback = app.menuItems.matching(NSPredicate(format: "title MATCHES %@", "0[.,]5×")).firstMatch
        XCTAssertTrue(slowPlayback.waitForExistence(timeout: 5))
        slowPlayback.click()
        app.buttons["transcript-correct-early"].click()
        let speakerName = app.textFields["meeting-speaker-name"]
        XCTAssertTrue(speakerName.waitForExistence(timeout: 5))
        let audition = app.buttons["meeting-speaker-audition"]
        XCTAssertTrue(audition.isEnabled)
        audition.click()
        XCTAssertTrue(app.buttons["Pause Meeting audio"].waitForExistence(timeout: 5), "Audition seeks and plays the existing source")
        speakerName.click(); speakerName.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(speakerName.exists)
        XCTAssertTrue(app.buttons["Pause Meeting audio"].waitForExistence(timeout: 5))
        app.buttons["Pause Meeting audio"].click()
        XCTAssertTrue(app.buttons["Play Meeting audio"].waitForExistence(timeout: 5))
        app.buttons["Play Meeting audio"].click()
        let second = app.tables["Meetings"].staticTexts["Missing evidence"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        second.click()
        app.radioButtons["Transcript"].click()
        XCTAssertFalse(app.sliders["Meeting audio position"].exists)
        XCTAssertFalse(app.buttons["Play Meeting audio"].exists)
        XCTAssertFalse(tracks.exists)
        XCTAssertFalse(speed.exists)
        XCTAssertFalse(app.buttons["meeting-playback-forward"].exists)
        XCTAssertFalse(app.buttons["meeting-playback-backward"].exists)
        XCTAssertFalse(app.buttons["meeting-playback-next-marker"].exists)
        XCTAssertFalse(app.buttons["meeting-playback-previous-marker"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Recording Bundle unavailable")).firstMatch.exists)

        // Purging a retained required track must disable playback after reload.
        app.terminate()
        try FileManager.default.removeItem(at: retainedMic)
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15))
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.click()
        app.radioButtons["Transcript"].click()
        XCTAssertFalse(app.sliders["Meeting audio position"].exists)
        XCTAssertFalse(app.buttons["Play Meeting audio"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "missing")).firstMatch.exists)
        XCTAssertEqual(try Data(contentsOf: retainedSystem), systemBefore)
        XCTAssertEqual(try Data(contentsOf: doorway), refreshedDoorway)
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
