import Foundation
import XCTest
import AVFoundation
import CryptoKit

/// UI seams verified against the isolated native app: icon-rail navigation and Ask AI scope.
final class StillmatterFlowsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-ui-\(UUID().uuidString)", isDirectory: true)
        let workspace = fixtureRoot.appendingPathComponent("workspace", isDirectory: true)
        let support = fixtureRoot.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        // Address the disposable bundle by URL, never Launch Services' installed app lookup.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let testApp = repository.appendingPathComponent(".build/ui-tests/StillmatterUITests.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testApp.path), "Build the isolated app with scripts/test-ui-flows.sh")
        app = XCUIApplication(url: testApp)
        app.launchEnvironment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] = workspace.path
        app.launchEnvironment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] = support.path
        app.launch()
        // macOS may restore a stale UI-test bundle after an interrupted run.
        let restore = app.buttons["Don’t Reopen"]
        if restore.waitForExistence(timeout: 3) { restore.click() }
        let report = app.buttons["Remind next time"]
        if report.waitForExistence(timeout: 3) { report.click() }
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15), app.debugDescription)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixtureRoot { try FileManager.default.removeItem(at: fixtureRoot) }
    }

    func testAcceptMeetingTitleClosesPromptAndDoesNotReopenIt() throws {
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let doorway = fixtureRoot.appendingPathComponent("workspace/\(path)")
        try FileManager.default.createDirectory(at: doorway.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = "Untitled Meeting at 2026-01-02 09:10"
        try Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8).write(to: doorway)
        // The app created the isolated operational database on launch. Seed a required
        // review exactly as capture does, then navigate to its native Today row.
        let database = fixtureRoot.appendingPathComponent("support/operational.sqlite")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, """
            INSERT INTO inbox_items (id, category, kind, title, source_ref, created_at, updated_at)
            VALUES ('meeting-title:ui', 'required', 'titleReview', 'Untitled meeting 09:10-09:40',
                    '\(path)', '2026-01-02T09:40:00Z', '2026-01-02T09:40:00Z');
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        app.buttons["sidebar-today"].click()
        XCTAssertTrue(app.buttons["Accept title"].waitForExistence(timeout: 12), app.debugDescription)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.exists)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("UI Title Verified")
        app.buttons["Accept title"].click()
        XCTAssertFalse(app.buttons["Accept title"].waitForExistence(timeout: 3), app.debugDescription)
        // A new notification tick must not offer the same pending review again.
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.staticTexts["UI Title Verified"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["Accept title"].exists)
    }

    func testMissingMeetingTitleReviewDoesNotLoopAcceptPrompt() throws {
        let database = fixtureRoot.appendingPathComponent("support/operational.sqlite")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, """
            INSERT INTO inbox_items (id, category, kind, title, source_ref, created_at, updated_at)
            VALUES ('meeting-title:missing', 'required', 'titleReview', 'Missing meeting title',
                    'Meetings/2026/01/02/missing/meeting.md', '2026-01-02T09:40:00Z', '2026-01-02T09:40:00Z');
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        app.buttons["sidebar-today"].click()
        XCTAssertFalse(app.buttons["Accept title"].waitForExistence(timeout: 4),
                       "A missing meeting must not repeatedly offer an impossible Accept")
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Missing meeting title")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        app.activate()
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "not in the current workspace"))
            .firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["Accept title"].exists)
        app.buttons["OK"].click()
    }

    func testPopulatedMeetingKeepsGeneratedActionsSeparateFromTodos() throws {
        let directory = fixtureRoot.appendingPathComponent("workspace/Meetings/review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\ntitle: Planning review\ncapture_session_id: review\n---\n# Planning review\n\n## Notes\n\nCheck the draft before sharing.\n".utf8)
            .write(to: directory.appendingPathComponent("meeting.md"))
        try Data("## Summary\n\nWe agreed to review the draft and share feedback.\n".utf8)
            .write(to: directory.appendingPathComponent("summary.md"))
        let extraction = """
        {"schema_version":1,"meeting":"Meetings/review/meeting.md","transcript":"Meetings/review/transcript.json",
         "decisions":[],"my_action_items":[{"id":"draft","text":"Review the draft before sharing","citations":[]}],
         "other_action_items":[],"open_questions":[]}
        """
        try Data(extraction.utf8).write(to: directory.appendingPathComponent("summary-extraction.json"))
        // Seed only the isolated operational DB, not the canonical Todos file. This gives the
        // existing review service a pending proposal without introducing prototype data in production.
        let database = fixtureRoot.appendingPathComponent("support/operational.sqlite")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [database.path, """
            INSERT INTO proposal_reviews (proposal_id, state, suppression_key, source_ref, title, updated_at)
            VALUES ('meeting-action:review:draft', 'pending', 'meeting-action:review:draft',
                    '[[Meetings/review/summary#My action items|ref]]', 'Review the draft before sharing', '2026-10-07T17:35:00Z');
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.staticTexts["Planning review"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "My actions")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "Review the draft before sharing")).firstMatch.exists)
        let actions = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@", "My actions")).firstMatch
        let notes = app.staticTexts["My notes"]
        XCTAssertTrue(actions.frame.minY < notes.frame.minY, "My actions precede optional notes")
        let detailScroll = app.scrollViews["meeting-detail-scroll"]
        let summaryHeading = app.staticTexts["AI summary"]
        XCTAssertGreaterThanOrEqual(summaryHeading.frame.minX - detailScroll.frame.minX, 28,
                                    "Overview cards need room between their content and the pane edge")
        let sourcesHeading = app.staticTexts["Source files"]
        XCTAssertGreaterThanOrEqual(sourcesHeading.frame.minX - detailScroll.frame.minX, 14,
                                    "Source files must share the overview's horizontal inset")
        attachMeetingScreenshot("Native populated meeting with generated action")
        app.buttons["meeting-action-edit-meeting-action:review:draft"].click()
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(identifier: "Accept").allElementsBoundByIndex.contains(where: { $0.isHittable }),
                       "Save must not be an implicit Accept")
        app.dialogs.buttons["Cancel"].click()
        app.buttons["meeting-action-review-meeting-action:review:draft"].click()
        XCTAssertTrue(app.buttons.matching(identifier: "Accept").allElementsBoundByIndex.contains(where: { $0.isHittable }))
        XCTAssertTrue(app.buttons["Decline"].exists)
        XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Review the draft before sharing")).firstMatch.exists,
                      "Review must display the generated action text")
        attachMeetingScreenshot("Native action review dialog")
        app.dialogs.buttons["Cancel"].click()
    }

    func testFourHourTranscriptSearchIsNotLimitedToFirstWindow() throws {
        let directory = fixtureRoot.appendingPathComponent("workspace/Meetings/long")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\ntitle: Long recording fixture\ncapture_session_id: long\n---\n# Long recording fixture\n".utf8)
            .write(to: directory.appendingPathComponent("meeting.md"))
        let segments: [[String: Any]] = (0..<240).map { minute in
            ["id": "s\(minute)", "start": Double(minute * 60), "end": Double(minute * 60 + 10),
             "text": minute == 235 ? "Unique final-hour phrase" : "Minute \(minute) discussion",
             "language": "en", "track": "microphone", "speaker": "Speaker"]
        }
        let transcript: [String: Any] = ["schema_version": 1, "capture_session_id": "long",
            "meeting_relative_path": "Meetings/long/meeting.md", "language": "en", "detected_languages": ["en"],
            "engine": "fixture", "model": "fixture", "generated_at": "2026-10-07T17:35:00Z",
            "audio_sources": [], "segments": segments, "diagnostics": []]
        try JSONSerialization.data(withJSONObject: transcript).write(to: directory.appendingPathComponent("transcript.json"))
        let extraction: [String: Any] = ["schema_version": 1, "meeting": "Meetings/long/meeting.md",
            "transcript": "Meetings/long/transcript.json", "decisions": [], "other_action_items": [], "open_questions": [],
            "my_action_items": [["id": "late", "text": "Review final-hour note",
                "citations": [["segment_id": "s235", "start_seconds": 14100.0, "end_seconds": 14110.0],
                              ["segment_id": "s235", "start_seconds": 14100.0, "end_seconds": 14120.0]]]]]
        try JSONSerialization.data(withJSONObject: extraction).write(to: directory.appendingPathComponent("summary-extraction.json"))
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.staticTexts["Long recording fixture"].waitForExistence(timeout: 10))
        let source = app.buttons["meeting-outcome-source-meeting-action:long:late-0"]
        XCTAssertTrue(source.waitForExistence(timeout: 10), "A cited action must show its source without requiring playable audio")
        XCTAssertFalse(app.buttons["meeting-outcome-source-meeting-action:long:late-1"].isEnabled,
                       "A citation with mismatched timing must not navigate to unrelated evidence")
        source.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "03:45:00–03:59:10")).firstMatch.exists,
                      "A source link must open the cited transcript window")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Source · 03:55:00")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Unique final-hour phrase"].exists)
        attachMeetingScreenshot("Native cited source navigation")
        app.scrollViews["meeting-detail-scroll"].swipeUp()
        XCTAssertTrue(app.staticTexts["Meeting audio"].isHittable, "The player stays visible while scrolling transcript events")
        app.buttons["meeting-back-to-overview"].click()
        app.buttons["meeting-open-transcription"].click()
        for _ in 0..<4 { app.buttons["Previous"].click() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "02:45:00–03:00:00")).firstMatch.exists)
        app.buttons["Next"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "03:00:00–03:15:00")).firstMatch.exists,
                      "Next across an hour must advance to 03:00")
        app.buttons["Previous"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "02:45:00–03:00:00")).firstMatch.exists,
                      "Previous across an hour must return to 02:45, not the start of Hour 3")
        let hourPicker = app.popUpButtons.matching(NSPredicate(format: "value BEGINSWITH %@", "Hour 3")).firstMatch
        XCTAssertTrue(hourPicker.exists)
        hourPicker.click()
        app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Hour 4")).firstMatch.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "03:00:00–03:15:00")).firstMatch.exists,
                      "Hour jump must select the first window of Hour 4")
        let search = app.textFields["Search entire recording"]
        search.click()
        search.typeText("Unique final-hour phrase")
        XCTAssertTrue(app.staticTexts["Unique final-hour phrase"].waitForExistence(timeout: 10))
        attachMeetingScreenshot("Native four hour recording search")
    }

    func testPlayableRecordingHasFullWidthSeekControl() throws {
        let directory = fixtureRoot.appendingPathComponent("workspace/Meetings/audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldMedia = fixtureRoot.appendingPathComponent("workspace/OldMedia/audio")
        try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
        let audio = oldMedia.appendingPathComponent("mic.caf")
        let metadata = oldMedia.appendingPathComponent("mic.json")
        let bundle = oldMedia.appendingPathComponent("recording-bundle.json")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for _ in 0..<8 { try writer.write(from: buffer) }
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
        app.terminate()
        app.launchEnvironment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] = newMedia.deletingLastPathComponent().path
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15))
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.staticTexts["Playable meeting"].waitForExistence(timeout: 10))
        app.buttons["meeting-open-transcription"].click()
        let slider = app.sliders["Meeting audio position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertTrue(slider.isEnabled)
        XCTAssertGreaterThan(slider.frame.width, 250, "The seek track must not collapse inside the audio stack")
        attachMeetingScreenshot("Native playable recording before seek")
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0:06 / 0:08")).firstMatch.waitForExistence(timeout: 5),
                      "Clicking three quarters of the track must seek the selected recording")
        attachMeetingScreenshot("Native playable recording after seek")
        app.buttons["Play Meeting audio"].click()
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5),
                      "Seeking while playing must move the playhead rather than resetting it")
        XCTAssertTrue(app.buttons["Pause Meeting audio"].exists)
        app.buttons["Pause Meeting audio"].click()
    }

    func testMeetingDetailAndTranscriptStayInSameWindow() throws {
        let meeting = fixtureRoot.appendingPathComponent("workspace/Meetings/ui-fixture/meeting.md")
        try FileManager.default.createDirectory(at: meeting.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("---\ntitle: Native UI fixture\ncapture_session_id: ui-fixture\n---\n# Native UI fixture\n".utf8).write(to: meeting)
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.staticTexts["Native UI fixture"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["meeting-open-transcription"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["My notes"].exists, "Meetings without notes do not render an empty notes card")
        attachMeetingScreenshot("Native meeting without notes")
        app.buttons["meeting-open-transcription"].click()
        XCTAssertTrue(app.buttons["meeting-back-to-overview"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Transcript timeline"].exists)
        XCTAssertEqual(app.windows.count, 1)
        attachMeetingScreenshot("Native meeting transcript without notes")
        let search = app.textFields["Search entire recording"]
        XCTAssertTrue(search.exists)
        search.click()
        search.typeText("nonexistent phrase")
        XCTAssertTrue(app.staticTexts["No matches in this recording."].exists)
        attachMeetingScreenshot("Native meeting empty transcript search")
        app.buttons["meeting-back-to-overview"].click()
        XCTAssertTrue(app.buttons["meeting-open-transcription"].exists)
    }

    private func attachMeetingScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEmptyQueueIsVisibleFromTasks() {
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.staticTexts["No Queue Todo Items"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Tasks")
    }

    func testAskScopeIsOptInAndCanBeReverted() {
        app.buttons["sidebar-ask-ai"].click()
        let checkbox = app.checkBoxes["contextual-ask-broader-vault"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        XCTAssertEqual(checkbox.value as? String, "Selected context only")
        checkbox.click()
        XCTAssertEqual(checkbox.value as? String, "Broader vault included")
        checkbox.click()
        XCTAssertEqual(checkbox.value as? String, "Selected context only")
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Ask AI")
    }

    func testAboutIconRequiresDoubleClickAndShowsVersionAndCreator() {
        let about = app.buttons["sidebar-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.click()
        XCTAssertFalse(app.dialogs.staticTexts["Version 0.1.0 (1)"].exists)
        about.doubleClick()
        let panel = app.dialogs.containing(.staticText, identifier: "Version 0.1.0 (1)").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(panel.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "Nazar Topolnytskyi")).firstMatch.exists)
    }

    func testSettingsIsReachableWithoutChangingSettings() {
        app.buttons["sidebar-settings"].click()
        XCTAssertTrue(app.buttons["Test Mic"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Settings")
    }
}
