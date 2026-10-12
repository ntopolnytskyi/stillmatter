import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testNotesSavePersistsAfterRelaunch() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Notes saved through the UI")
        app.buttons["meeting-text-save"].click()
        waitForEditorToClose()
        XCTAssertTrue(try meetingText().contains("Notes saved through the UI"))
        relaunch()
        openFixtureMeeting()
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Notes saved through the UI")
    }

    func testEscapeCancelsNotesWithoutChangingFileOrSelection() throws {
        try seedMeeting()
        let before = try meetingText()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("This draft must be discarded")
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try meetingText(), before)
        XCTAssertEqual(app.staticTexts["meeting-detail"].value as? String, "UI fixture meeting")
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Original notes.")
    }

    func testCommandReturnSavesSummaryIndependentlyOfNotes() throws {
        try seedMeeting()
        let before = try meetingText()
        openFixtureMeeting()
        openEditor("summary")
        replaceEditorText("Summary saved with Command-Return")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        XCTAssertEqual(try meetingText(), before)
        let summary = fixtureRoot.appendingPathComponent("workspace/Meetings/ui-fixture/summary.md")
        XCTAssertTrue(try String(contentsOf: summary, encoding: .utf8).contains("Summary saved with Command-Return"))
        relaunch()
        openFixtureMeeting()
        openEditor("summary")
        XCTAssertEqual((editor.value as? String)?.trimmingCharacters(in: .newlines), "Summary saved with Command-Return")
    }

    func testExternalEditKeepsDraftAndOffersReload() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Unsaved local draft")
        let external = try meetingText().replacingOccurrences(of: "Original notes.", with: "Externally updated notes.")
        try external.write(to: meetingURL, atomically: true, encoding: .utf8)
        app.buttons["meeting-text-save"].click()
        let reload = app.buttons["meeting-text-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Unsaved local draft")
        XCTAssertEqual(try meetingText(), external)
        reload.click()
        let updated = NSPredicate(format: "value == %@", "Externally updated notes.")
        expectation(for: updated, evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        app.buttons["meeting-text-cancel"].click()
        waitForEditorToClose()
        XCTAssertEqual(try meetingText(), external)
    }

    func testTranscriptSearchIncludesLaterWindowsAndPagesAllMatches() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        let search = app.textFields["meeting-transcript-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click()
        search.typeText("Synthetic searchable")
        XCTAssertTrue(app.staticTexts["Results 1–100 of 120"].waitForExistence(timeout: 10))
        let next = app.buttons["meeting-transcript-next"]
        XCTAssertTrue(next.isEnabled)
        next.click()
        XCTAssertTrue(app.staticTexts["Results 101–120 of 120"].waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("missing-query-8271")
        XCTAssertTrue(app.staticTexts["No matches in this recording."].waitForExistence(timeout: 10))
        search.typeKey("a", modifierFlags: .command)
        search.typeText("Synthetic searchable")
        XCTAssertTrue(app.staticTexts["Results 1–100 of 120"].waitForExistence(timeout: 10))
    }

    var editor: XCUIElement { app.textViews["meeting-text-editor"] }
    var meetingURL: URL { fixtureRoot.appendingPathComponent("workspace/Meetings/ui-fixture/meeting.md") }

    func openEditor(_ field: String) {
        let button = app.buttons["meeting-overview-edit-\(field)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 10)
        button.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
    }

    func replaceEditorText(_ text: String) {
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(text)
    }

    func waitForEditorToClose() {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        waitForExpectations(timeout: 10)
    }

    func meetingText() throws -> String { try String(contentsOf: meetingURL, encoding: .utf8) }

    func relaunch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func openFixtureMeeting() {
        app.buttons["sidebar-meetings"].click()
        app.buttons["Recorded"].click()
        let row = app.tables["Meetings"].staticTexts["UI fixture meeting"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.buttons["meeting-overview-edit-notes"].waitForExistence(timeout: 10))
    }

    func seedMeeting(transcript: Bool = false) throws {
        // Prepare before launch so discovery does not depend on filesystem watcher timing.
        app.terminate()
        let directory = meetingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\ntitle: UI fixture meeting\ncapture_session_id: ui-fixture\n---\n# UI fixture meeting\n\n## Notes\n\nOriginal notes.\n"
            .write(to: meetingURL, atomically: true, encoding: .utf8)
        try "## Summary\n\nOriginal summary.\n".write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        if transcript {
            let segments: [[String: Any]] = (0..<120).map { index in
                ["id": "s\(index)", "start": Double(index * 120), "end": Double(index * 120 + 1),
                 "text": "Synthetic searchable moment \(index)", "language": "en", "track": "microphone", "speaker": "Me"]
            }
            let document: [String: Any] = ["schema_version": 1, "capture_session_id": "ui-fixture",
                "meeting_relative_path": "Meetings/ui-fixture/meeting.md", "language": "en", "detected_languages": ["en"],
                "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
                "audio_sources": [], "segments": segments, "diagnostics": []]
            try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent("transcript.json"))
        }
        relaunch()
    }
}
