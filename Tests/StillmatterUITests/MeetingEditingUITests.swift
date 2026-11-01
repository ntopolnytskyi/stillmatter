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
        XCTAssertTrue(try notesText().contains("Notes saved through the UI"))
        XCTAssertFalse(try meetingText().contains("Notes saved through the UI"))
        relaunch()
        openFixtureMeeting()
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Notes saved through the UI")
    }

    func testEscapeCancelsNotesWithoutChangingFileOrSelection() throws {
        try seedMeeting()
        openFixtureMeeting()
        let before = try meetingText()
        let notesBefore = try notesText()
        openEditor("notes")
        replaceEditorText("This draft must be discarded")
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try meetingText(), before)
        XCTAssertEqual(try notesText(), notesBefore)
        XCTAssertEqual(app.staticTexts["meeting-detail"].value as? String, "UI fixture meeting")
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Original notes.")
    }

    func testCommandReturnSavesSummaryIndependentlyOfNotes() throws {
        try seedMeeting()
        openFixtureMeeting()
        let before = try meetingText()
        let notesBefore = try notesText()
        openEditor("summary")
        replaceEditorText("Summary saved with Command-Return")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        XCTAssertEqual(try meetingText(), before)
        XCTAssertEqual(try notesText(), notesBefore)
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
        let external = try notesText().replacingOccurrences(of: "Original notes.", with: "Externally updated notes.")
        try external.write(to: notesURL, atomically: true, encoding: .utf8)
        app.buttons["meeting-text-save"].click()
        let reload = app.buttons["meeting-text-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Unsaved local draft")
        XCTAssertEqual(try notesText(), external)
        reload.click()
        let updated = NSPredicate(format: "value == %@", "Externally updated notes.")
        expectation(for: updated, evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        app.buttons["meeting-text-cancel"].click()
        waitForEditorToClose()
        XCTAssertEqual(try notesText(), external)
    }

    func testCancelConflictingDraftReopensLatestNotesAndSavesWithoutAFalseConflict() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Discard this local draft")
        let external = try notesText().replacingOccurrences(of: "Original notes.", with: "Latest external notes.")
        try external.write(to: notesURL, atomically: true, encoding: .utf8)
        app.buttons["meeting-text-save"].click()
        XCTAssertTrue(app.buttons["meeting-text-reload"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Discard this local draft")
        XCTAssertTrue(app.staticTexts["Latest external notes."].waitForExistence(timeout: 10), "The refreshed canonical detail must be available before discarding the old draft")
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try notesText(), external)
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Latest external notes.")
        replaceEditorText("Fresh edit after cancel")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        XCTAssertTrue(try notesText().contains("Fresh edit after cancel"))
    }

    func testCleanOpenNotesEditorFollowsExternalChangesWithoutAConflict() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        let external = try notesText().replacingOccurrences(of: "Original notes.", with: "External clean editor update.")
        try external.write(to: notesURL, atomically: true, encoding: .utf8)
        expectation(for: NSPredicate(format: "value == %@", "External clean editor update."), evaluatedWith: editor)
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["meeting-text-reload"].exists)
        // Text input goes directly to the editor: refreshed content must keep focus.
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Typed after refresh")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        XCTAssertTrue(try notesText().contains("Typed after refresh"))
    }

    func testEmptyNotesEditorStartsFocusedAndEscapePreservesEmptySource() throws {
        try seedMeeting(notes: "")
        openFixtureMeeting()
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "")
        let before = try Data(contentsOf: notesURL)
        editor.typeText("Focus stays in this empty editor")
        XCTAssertEqual(editor.value as? String, "Focus stays in this empty editor")
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try Data(contentsOf: notesURL), before)
    }

    func testArchivedMeetingDisplaysContentWithBothEditorsDisabled() throws {
        try seedMeeting()
        app.terminate()
        try Data("{\"archived\":true}".utf8).write(to: meetingURL.deletingLastPathComponent().appendingPathComponent("archive.json"))
        relaunch()
        app.buttons["sidebar-meetings"].click()
        app.buttons["Recorded"].click()
        app.buttons["Show Meeting filters"].click()
        app.popUpButtons["Meeting archive filter"].click()
        app.menuItems["Archived Meetings"].click()
        let row = app.tables["Meetings"].staticTexts["UI fixture meeting"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let notes = app.buttons["meeting-overview-edit-notes"]
        let summary = app.buttons["meeting-overview-edit-summary"]
        XCTAssertTrue(notes.waitForExistence(timeout: 10))
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertFalse(notes.isEnabled)
        XCTAssertFalse(summary.isEnabled)
        XCTAssertFalse(app.buttons["meeting-edit-notes"].isEnabled)
        XCTAssertFalse(app.buttons["meeting-edit-summary"].isEnabled)
        XCTAssertFalse(editor.exists)
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

    func testExternalNotesRenameKeepsDraftAndSavesResolutionToTheRenamedCanonicalFile() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Unsaved local draft before rename")
        let renamed = notesURL.deletingLastPathComponent().appendingPathComponent("renamed-notes.md")
        let external = try notesText().replacingOccurrences(of: "Original notes.", with: "External renamed notes.")
        try FileManager.default.moveItem(at: notesURL, to: renamed)
        try external.write(to: renamed, atomically: true, encoding: .utf8)
        app.buttons["meeting-text-save"].click()
        let reload = app.buttons["meeting-text-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "Unsaved local draft before rename")
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), external)
        reload.click()
        expectation(for: NSPredicate(format: "value == %@", "External renamed notes."), evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        replaceEditorText("Resolved after rename")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesURL.path))
        XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).contains("Resolved after rename"))
        relaunch()
        openFixtureMeeting()
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Resolved after rename")
    }

    func testMalformedNotesShowAffectedFileAndKeepDraftUntilExplicitReloadAfterRepair() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Draft survives malformed source")
        let original = try Data(contentsOf: notesURL)
        try Data([0xff, 0xfe]).write(to: notesURL, options: .atomic)
        app.buttons["meeting-text-save"].click()
        let error = app.staticTexts["meeting-text-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue((error.value as? String ?? error.label).contains("my-notes.md"))
        XCTAssertEqual(editor.value as? String, "Draft survives malformed source")
        XCTAssertEqual(try Data(contentsOf: notesURL), Data([0xff, 0xfe]))
        let reload = app.buttons["meeting-text-reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 10))
        reload.click()
        expectation(for: NSPredicate { _, _ in
            (error.value as? String ?? error.label).contains("Could not reload") && reload.isEnabled
        }, evaluatedWith: error)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(editor.value as? String, "Draft survives malformed source")
        try original.write(to: notesURL, options: .atomic)
        reload.click()
        expectation(for: NSPredicate(format: "value == %@", "Original notes."), evaluatedWith: editor)
        waitForExpectations(timeout: 10)
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try Data(contentsOf: notesURL), original)
    }

    var notesURL: URL { meetingURL.deletingLastPathComponent().appendingPathComponent("my-notes.md") }
    func notesText() throws -> String { try String(contentsOf: notesURL, encoding: .utf8) }

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

    func seedMeeting(transcript: Bool = false, notes: String = "Original notes.") throws {
        // Prepare before launch so discovery does not depend on filesystem watcher timing.
        app.terminate()
        let directory = meetingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\ntitle: UI fixture meeting\ncapture_session_id: ui-fixture\n---\n# UI fixture meeting\n\n## Notes\n\n\(notes)\n"
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
