import Foundation
import AppKit
import XCTest
import StillmatterCore

extension StillmatterFlowsUITests {
    func testRenameFailureRetainsTitleKeyboardCancelSuccessAndRelaunch() throws {
        try seedMeeting()
        openFixtureMeeting()
        func openRename() {
            app.buttons["meeting-more"].click()
            app.menuItems["Rename…"].click()
        }
        openRename()
        let title = app.textFields["meeting-rename-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Links copied outside Stillmatter cannot be updated")).firstMatch.exists)
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("///")
        title.typeKey(.return, modifierFlags: [])
        let status = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Could not rename Meeting")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        openRename()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "///")
        title.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(try meetingText().contains("title: UI fixture meeting"))
        openRename()
        XCTAssertEqual(title.value as? String, "UI fixture meeting")
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Renamed fixture")
        title.typeKey(.return, modifierFlags: [])
        let row = app.tables["Meetings"].staticTexts["Renamed fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let canonical = fixtureRoot.appendingPathComponent("workspace/Meetings/renamed-fixture/meeting.md")
        XCTAssertTrue(try String(contentsOf: canonical).contains("title: Renamed fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meetingURL.path))
        relaunch()
        app.buttons["sidebar-meetings"].click()
        app.buttons["Recorded"].click()
        XCTAssertTrue(app.tables["Meetings"].staticTexts["Renamed fixture"].firstMatch.waitForExistence(timeout: 10))
    }

    func testCalendarFallbackKeyboardCancelUnlinkAndRelaunchPersistence() throws {
        try seedMeeting()
        app.terminate()
        let event = CalendarMeeting(title: "План / 計画", eventIdentifier: "isolated-event", calendarIdentifier: "isolated-calendar", eventStart: Date(timeIntervalSince1970: 1000), eventEnd: Date(timeIntervalSince1970: 2000))
        let context = MeetingCalendarContext(event: event, fallbackTitle: "UI fixture meeting", appliedTitle: "UI fixture meeting", manualTitle: true, status: "Linked calendar event")
        try context.writing(to: meetingText()).write(to: meetingURL, atomically: true, encoding: .utf8)
        relaunch(); openFixtureMeeting()
        let status = app.staticTexts["meeting-calendar-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue((status.value as? String)?.contains("Scheduled:") == true)
        func openCalendar() {
            app.buttons["meeting-more"].click()
            let calendar = app.menuItems["meeting-calendar"]
            XCTAssertTrue(calendar.isEnabled)
            calendar.click()
        }
        openCalendar()
        let picker = app.popUpButtons["meeting-calendar-events"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Link selected event"].isEnabled)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Calendar sources disabled")).firstMatch.exists)
        picker.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(picker.exists)
        XCTAssertEqual(try MeetingCalendarContext.read(from: meetingText())?.event, event)
        openCalendar()
        app.buttons["Unlink"].click()
        expectation(for: NSPredicate(format: "value == %@", "Unlinked"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertNil(try MeetingCalendarContext.read(from: meetingText())?.event)
        XCTAssertTrue(try meetingText().contains("title: UI fixture meeting"))
        relaunch(); openFixtureMeeting()
        XCTAssertEqual(app.staticTexts["meeting-calendar-status"].value as? String, "Unlinked")
        openCalendar()
        XCTAssertFalse(app.buttons["Unlink"].isEnabled)
        app.buttons["Cancel"].typeKey(.escape, modifierFlags: [])
    }

    func testReprocessWarningLanguageKeyboardCancellationAndFailurePreserveMeeting() throws {
        try seedMeeting(transcript: true, myActionItem: "Keep task")
        openFixtureMeeting(); app.radioButtons["Transcript"].click()
        // Speaker correction exposes the ordinary Reprocess entry point.
        app.buttons["transcript-correct-s0"].click()
        let name = app.textFields["meeting-speaker-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command); name.typeText("Alice"); name.typeKey(.return, modifierFlags: [])
        let reprocess = app.buttons["meeting-speaker-reprocess"]
        XCTAssertTrue(reprocess.waitForExistence(timeout: 10)); reprocess.click()
        let language = app.popUpButtons["meeting-reprocess-language"]
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertEqual(language.value as? String, "Auto")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "no inspectable revision history")).firstMatch.exists)
        language.click(); app.menuItems["Ukrainian"].click()
        language.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(language.exists)
        let directory = meetingURL.deletingLastPathComponent()
        let notes = try Data(contentsOf: directory.appendingPathComponent("my-notes.md"))
        let summary = try Data(contentsOf: directory.appendingPathComponent("summary.md"))
        reprocess.click()
        XCTAssertTrue(language.waitForExistence(timeout: 5))
        XCTAssertEqual(language.value as? String, "Auto")
        language.click(); app.menuItems["English"].click()
        app.buttons["meeting-reprocess-confirm"].typeKey(.return, modifierFlags: [])
        let feedback = app.staticTexts["meeting-reprocess-feedback"]
        XCTAssertTrue(feedback.waitForExistence(timeout: 10))
        XCTAssertTrue((feedback.value as? String)?.contains("Could not reprocess") == true)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("my-notes.md")), notes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("summary.md")), summary)
        relaunch(); openFixtureMeeting(); app.radioButtons["Transcript"].click()
        XCTAssertTrue(app.staticTexts["meeting-analysis-outdated"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "title CONTAINS %@", "Alice"), evaluatedWith: app.buttons["transcript-correct-s0"])
        waitForExpectations(timeout: 5)
    }

    func testSpeakerCorrectionRepeatedKeyboardCancelValidationAndReopen() throws {
        try seedMeeting(transcript: true, myActionItem: "Keep task")
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        app.buttons["meeting-transcript-speakers"].click(); app.menuItems["Me"].click()
        let correct = app.buttons["transcript-correct-s0"]
        XCTAssertTrue(correct.waitForExistence(timeout: 10))
        correct.click()
        let name = app.textFields["meeting-speaker-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["meeting-speaker-audition"].isEnabled)
        name.typeKey("a", modifierFlags: .command)
        name.typeKey(.delete, modifierFlags: [])
        name.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Enter a speaker name."].waitForExistence(timeout: 5))
        name.typeText("Alice")
        name.typeKey(.return, modifierFlags: [])
        let notice = app.staticTexts["meeting-analysis-outdated"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let context = app.buttons["transcript-correct-s0"]
        expectation(for: NSPredicate(format: "title CONTAINS %@", "Alice"), evaluatedWith: context)
        waitForExpectations(timeout: 10)
        expectation(for: NSPredicate(format: "title CONTAINS %@", "2 selected"), evaluatedWith: app.buttons["meeting-transcript-speakers"])
        waitForExpectations(timeout: 5)
        correct.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command); name.typeText("Discarded")
        name.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(name.exists)
        XCTAssertTrue(context.label.contains("Alice") == true)
        correct.click()
        name.typeKey("a", modifierFlags: .command); name.typeText("Olena")
        // A service validation failure keeps the draft and offers another apply.
        name.typeKey("a", modifierFlags: .command); name.typeText(String(repeating: "x", count: 201))
        app.buttons["meeting-speaker-apply"].click()
        let error = app.staticTexts["meeting-speaker-feedback"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "1–200"), evaluatedWith: error)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(name.value as? String, String(repeating: "x", count: 201))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Olena")
        app.buttons["meeting-speaker-apply"].click()
        expectation(for: NSPredicate(format: "title CONTAINS %@", "Olena"), evaluatedWith: context)
        waitForExpectations(timeout: 10)
        let window = app.windows["Stillmatter"]
        let frame = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -4, dy: -4))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 720 - frame.width, dy: 520 - frame.height)))
        expectation(for: NSPredicate { _, _ in abs(window.frame.width - 720) < 3 }, evaluatedWith: window)
        waitForExpectations(timeout: 10)
        correct.click()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(name.isHittable)
        XCTAssertTrue(app.buttons["meeting-speaker-apply"].isHittable)
        XCTAssertTrue(app.buttons["meeting-speaker-cancel"].isHittable)
        name.typeKey(.escape, modifierFlags: [])
        app.popUpButtons["meeting-transcript-view"].click(); app.menuItems["Grouped by speaker"].click()
        XCTAssertTrue(app.staticTexts["Olena"].waitForExistence(timeout: 5))
        app.buttons["meeting-speaker-reprocess"].click()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5)); app.buttons["Cancel"].click()
        relaunch(); openFixtureMeeting(); app.radioButtons["Transcript"].click()
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Olena"].waitForExistence(timeout: 5))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: meetingURL.deletingLastPathComponent().appendingPathComponent("transcript.json"))) as? [String: Any])
        let source = try XCTUnwrap((document["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(source["id"] as? String, "s0")
        XCTAssertEqual(source["speaker"] as? String, "Olena")
        XCTAssertEqual(source["text"] as? String, "Synthetic searchable moment 0")
        XCTAssertEqual(source["start"] as? Double, 0)
    }

    func testSpeakerEditorRejectsExternallyReplacedSourceAndRetainsDraft() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting(); app.radioButtons["Transcript"].click()
        app.buttons["transcript-correct-s0"].click()
        let name = app.textFields["meeting-speaker-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeKey("a", modifierFlags: .command); name.typeText("Alice")
        let url = meetingURL.deletingLastPathComponent().appendingPathComponent("transcript.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0]["start"] = 3; segments[0]["end"] = 4; object["segments"] = segments
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        expectation(for: NSPredicate(format: "title == %@", "00:00:03"), evaluatedWith: app.buttons["transcript-time-s0"])
        waitForExpectations(timeout: 10)
        app.buttons["meeting-speaker-apply"].click()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "source changed"), evaluatedWith: app.staticTexts["meeting-speaker-feedback"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(name.value as? String, "Alice")
        let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((unchanged["segments"] as? [[String: Any]])?.first?["speaker"] as? String, "Me")
        app.buttons["meeting-speaker-cancel"].click()
        XCTAssertFalse(name.exists)
    }

    func testFiveMeetingTabsKeepDecisionsInSummaryAndAudioInTranscript() throws {
        try seedMeeting(transcript: true, myActionItem: "Extracted action title",
                        savedActionTitle: "Edited proposal title")
        openFixtureMeeting()

        let tabs = ["Summary", "Action Items", "Open Items", "My Notes", "Transcript"]
        for tab in tabs {
            XCTAssertTrue(app.radioButtons[tab].waitForExistence(timeout: 10), "Missing Meeting tab: \(tab)")
        }
        XCTAssertTrue(app.staticTexts["Decisions"].exists, "Summary contains the full Decisions section")
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Decision stays in Summary")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Edited proposal title"].exists)
        XCTAssertFalse(app.staticTexts["Extracted action title"].exists)
        XCTAssertFalse(app.buttons["Play Meeting audio"].isHittable, "Audio controls stay out of Summary")

        let summaryTab = app.radioButtons["Summary"]
        summaryTab.click()
        summaryTab.typeKey(.rightArrow, modifierFlags: [.command, .option])
        let editAction = app.buttons["meeting-actions-accept-mine"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 5))
        summaryTab.click()
        app.buttons["meeting-open-action-items"].click()
        XCTAssertTrue(editAction.waitForExistence(timeout: 5))
        app.radioButtons["Open Items"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Question stays in Open Items")).firstMatch.waitForExistence(timeout: 5))
        app.radioButtons["My Notes"].click()
        XCTAssertTrue(app.buttons["meeting-overview-edit-notes"].waitForExistence(timeout: 5))
        app.radioButtons["Transcript"].click()
        XCTAssertTrue(app.staticTexts["Meeting audio"].waitForExistence(timeout: 5))
        app.radioButtons["Summary"].click()
        XCTAssertTrue(app.staticTexts["Decisions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Decision stays in Summary")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Play Meeting audio"].isHittable)
    }

    func testLongNotesRemainReadableAndEditableInTheirOwnTab() throws {
        let notes = (0..<80).map { "Long note line \($0): preserved meeting context." }.joined(separator: "\n\n")
        try seedMeeting(notes: notes)
        openFixtureMeeting()
        app.radioButtons["My Notes"].click()
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99)).press(
            forDuration: 0.1,
            thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.8)))
        let edit = app.buttons["meeting-overview-edit-notes"]
        XCTAssertTrue(edit.exists)
        XCTAssertTrue(edit.isEnabled)
        edit.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        XCTAssertTrue((editor.value as? String)?.contains("Long note line 79") == true)
    }

    func testReassignNoteAuthoredTaskKeepsItInMeetingAndRemovesItFromTodo() throws {
        try seedMeeting(notes: "- [ ] Assign this task\n")
        openFixtureMeeting()
        app.radioButtons["My Notes"].click()
        let reassign = app.buttons["meeting-note-task-reassign"]
        XCTAssertTrue(reassign.waitForExistence(timeout: 10))
        reassign.click()
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let owner = alert.textFields["meeting-note-task-owner"]
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        owner.click()
        owner.typeText("person-alex")
        alert.buttons["Reassign"].click()
        let reassigned = NSPredicate { _, _ in
            (try? String(contentsOf: self.notesURL, encoding: .utf8).contains("person-alex")) == true
        }
        expectation(for: reassigned, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        let notes = try notesText()
        XCTAssertTrue(notes.contains("- [ ] Assign this task <!-- sm-item:"))
        XCTAssertTrue(notes.contains("person-alex"))
        let queue = fixtureRoot.appendingPathComponent("workspace/Todos/todo.md")
        XCTAssertFalse(try String(contentsOf: queue, encoding: .utf8).contains("[[item:"))
    }

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

    func testEscapeCommandReturnNotesEditing() throws {
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
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        XCTAssertFalse(summary.isEnabled)
        app.radioButtons["My Notes"].click()
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        XCTAssertFalse(notes.isEnabled)
        XCTAssertFalse(app.buttons["meeting-edit-notes"].isEnabled)
        XCTAssertFalse(app.buttons["meeting-edit-summary"].isEnabled)
        XCTAssertFalse(editor.exists)
    }

    func testTranscriptSearchIncludesLaterWindowsAndPagesAllMatches() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        let search = app.searchFields["meeting-transcript-search"]
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

    func testTranscriptViewsSpeakerFiltersKeyboardAndPersistenceKeepSavedText() throws {
        try seedMeeting(transcript: true, multipleSpeakers: true)
        let transcriptURL = meetingURL.deletingLastPathComponent().appendingPathComponent("transcript.json")
        let original = try Data(contentsOf: transcriptURL)
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        let picker = app.popUpButtons["meeting-transcript-view"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "With timestamps")
        XCTAssertTrue(app.buttons["transcript-time-s0"].exists)
        XCTAssertFalse(app.buttons["transcript-time-s0"].isEnabled, "Missing audio is reading only")
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["meeting-transcript-search"]
        search.typeText("Synthetic searchable")
        XCTAssertTrue(app.staticTexts["Match 1 of 120"].waitForExistence(timeout: 10))
        search.typeKey("g", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Match 2 of 120"].waitForExistence(timeout: 10))
        search.typeKey("g", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["Match 1 of 120"].waitForExistence(timeout: 10))
        app.buttons["meeting-transcript-speakers"].click()
        app.menuItems["Guest"].click()
        XCTAssertTrue(app.staticTexts["Results 1–60 of 60"].waitForExistence(timeout: 10))
        app.buttons["meeting-transcript-speakers"].click()
        app.menuItems["Me"].click()
        XCTAssertTrue(app.staticTexts["Results 1–100 of 120"].waitForExistence(timeout: 10))
        picker.click()
        app.menuItems["Grouped by speaker"].click()
        XCTAssertEqual(picker.value as? String, "Grouped by speaker")
        app.typeKey("2", modifierFlags: [.command, .shift])
        XCTAssertEqual(picker.value as? String, "Text only")
        XCTAssertFalse(app.buttons["transcript-time-s0"].exists)
        XCTAssertEqual(app.textViews.matching(identifier: "transcript-text-s0").count, 0)
        search.click()
        search.typeKey("a", modifierFlags: .command)
        search.typeText("moment 119")
        XCTAssertTrue(app.staticTexts["Results 1–1 of 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["transcript-text-s119"].exists)
        app.staticTexts["transcript-text-s119"].rightClick()
        app.menuItems["Copy with timestamp"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Guest 03:58:00 Synthetic searchable moment 119")
        app.radioButtons["Summary"].click()
        app.radioButtons["Transcript"].click()
        XCTAssertTrue(app.staticTexts["transcript-text-s119"].exists)
        relaunch()
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        XCTAssertEqual(app.popUpButtons["meeting-transcript-view"].value as? String, "Text only")
        XCTAssertEqual(try Data(contentsOf: transcriptURL), original)
    }

    func testRestoredMixedTimelinePanelRetainsTypeFiltersHourJumpAndReaderControls() throws {
        try seedMeeting(transcript: true, mixedTimeline: true)
        let original = try Data(contentsOf: meetingURL.deletingLastPathComponent().appendingPathComponent("transcript.json"))
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        XCTAssertTrue(app.staticTexts["meeting-transcript-heading"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ACTION"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["DECISION"].firstMatch.exists)
        XCTAssertTrue(app.buttons["transcript-correct-s0"].exists)
        XCTAssertTrue(app.popUpButtons["meeting-transcript-view"].exists)
        XCTAssertTrue(app.buttons["meeting-transcript-speakers"].exists)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "Restored mixed Transcript timeline"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("f", modifierFlags: .command)
        let contextSearch = app.searchFields["meeting-transcript-search"]
        contextSearch.typeText("My action")
        XCTAssertTrue(app.staticTexts["Results 1–1 of 1"].waitForExistence(timeout: 10))
        contextSearch.typeKey("a", modifierFlags: .command)
        contextSearch.typeKey(.delete, modifierFlags: [])
        let transcript = app.checkBoxes["meeting-transcript-kind-transcript"]
        let decisions = app.checkBoxes["meeting-transcript-kind-decisions"]
        let actions = app.checkBoxes["meeting-transcript-kind-actions"]
        transcript.click()
        XCTAssertTrue(app.staticTexts["Results 1–2 of 2"].waitForExistence(timeout: 5))
        actions.click()
        XCTAssertTrue(app.staticTexts["Results 1–1 of 1"].waitForExistence(timeout: 5))
        decisions.click()
        XCTAssertTrue(app.staticTexts["No moments in this window or selected filters."].waitForExistence(timeout: 5))
        transcript.click()
        let hour = app.popUpButtons["meeting-transcript-hour"]
        hour.click()
        app.menuItems["Hour 4 · 03:00:00–03:58:01"].click()
        XCTAssertTrue(app.staticTexts["transcript-text-s90"].waitForExistence(timeout: 5))
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["meeting-transcript-search"]
        search.typeText("moment 119")
        XCTAssertTrue(app.staticTexts["transcript-text-s119"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: meetingURL.deletingLastPathComponent().appendingPathComponent("transcript.json")), original)
    }

    func testTranscriptScrollKeepsPlayerAndControlsAlignedAndStationary() throws {
        try seedMeeting(transcript: true, mixedTimeline: true)
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        let items = app.scrollViews["meeting-transcript-items-scroll"]
        XCTAssertTrue(items.waitForExistence(timeout: 10))
        let heading = app.staticTexts["meeting-transcript-heading"]
        let search = app.searchFields["meeting-transcript-search"]
        let filter = app.checkBoxes["meeting-transcript-kind-transcript"]
        let player = app.staticTexts["Meeting audio"]
        XCTAssertEqual(heading.frame.minX, player.frame.minX, accuracy: 1)
        XCTAssertEqual(items.frame.minX, heading.frame.minX, accuracy: 1)
        let headingFrame = heading.frame
        let searchFrame = search.frame
        let filterFrame = filter.frame
        let playerFrame = player.frame
        let readingMode = app.popUpButtons["meeting-transcript-view"]
        let speakers = app.buttons["meeting-transcript-speakers"]
        XCTAssertEqual(filter.frame.midY, readingMode.frame.midY, accuracy: 3)
        XCTAssertEqual(filter.frame.midY, speakers.frame.midY, accuracy: 3)
        XCTAssertGreaterThan(readingMode.frame.minX, filter.frame.maxX)
        // Wheel events outside the item list must not scroll the meeting workspace.
        player.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertEqual(player.frame, playerFrame)
        XCTAssertEqual(heading.frame, headingFrame)
        player.scroll(byDeltaX: 0, deltaY: 300)
        XCTAssertEqual(player.frame, playerFrame)
        XCTAssertEqual(heading.frame, headingFrame)
        let first = app.staticTexts["transcript-text-s0"]
        let firstFrame = first.frame
        items.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertEqual(heading.frame, headingFrame)
        XCTAssertEqual(search.frame, searchFrame)
        XCTAssertEqual(filter.frame, filterFrame)
        XCTAssertEqual(player.frame, playerFrame)
        XCTAssertNotEqual(first.frame, firstFrame)
        XCTAssertTrue(search.isHittable)
        let screenshot = XCTAttachment(screenshot: app.windows["Stillmatter"].screenshot())
        screenshot.name = "Transcript with fixed controls and scrolling items"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testEmptyTranscriptShowsFeedbackAndDisablesNavigation() throws {
        try seedMeeting()
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        XCTAssertTrue(app.staticTexts["No Transcript available."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["meeting-transcript-next"].isEnabled)
        XCTAssertFalse(app.buttons["meeting-transcript-next-match"].exists, "Match controls stay hidden until a search is active")
        XCTAssertFalse(app.buttons["meeting-transcript-speakers"].isEnabled)
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
        app.radioButtons[field == "notes" ? "My Notes" : "Summary"].click()
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
        XCTAssertTrue(app.buttons["meeting-overview-edit-summary"].waitForExistence(timeout: 10))
    }

    func seedMeeting(transcript: Bool = false, notes: String = "Original notes.",
                     myActionItem: String? = nil, savedActionTitle: String? = nil, otherActionItem: String? = nil, actionCitation: Bool = false, multipleSpeakers: Bool = false, mixedTimeline: Bool = false) throws {
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
                 "text": "Synthetic searchable moment \(index)", "language": "en", "track": "microphone", "speaker": multipleSpeakers && index % 2 == 1 ? "Guest" : "Me"]
            }
            let document: [String: Any] = ["schema_version": 1, "capture_session_id": "ui-fixture",
                "meeting_relative_path": "Meetings/ui-fixture/meeting.md", "language": "en", "detected_languages": ["en"],
                "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
                "audio_sources": [], "segments": segments, "diagnostics": []]
            try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent("transcript.json"))
            let extraction = #"{"schema_version":1,"meeting":"Meetings/ui-fixture/meeting.md","transcript":"Meetings/ui-fixture/transcript.json","decisions":[{"id":"decision-fixture","text":"Decision stays in Summary","citations":[]}],"my_action_items":[],"other_action_items":[],"open_questions":[{"id":"question-fixture","text":"Question stays in Open Items","citations":[]}] }"#
            let myActionItems = myActionItem.map {
                #"[{"id":"action-fixture","text":"\#($0)","citations":[]}]"#
            } ?? "[]"
            var extractionWithAction = extraction.replacingOccurrences(
                of: "\"my_action_items\":[]", with: "\"my_action_items\":\(myActionItems)")
            if let otherActionItem {
                extractionWithAction = extractionWithAction.replacingOccurrences(of: "\"other_action_items\":[]",
                    with: "\"other_action_items\":[{\"id\":\"unknown\",\"text\":\"" + otherActionItem + "\",\"citations\":[]}]")
            }
            if actionCitation {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(extractionWithAction.utf8)) as? [String: Any])
                var actions = try XCTUnwrap(object["my_action_items"] as? [[String: Any]])
                actions[0]["citations"] = [["segment_id": "s0", "start_seconds": 0, "end_seconds": 1]]
                object["my_action_items"] = actions
                extractionWithAction = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            }
            if mixedTimeline {
                var mixed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(extractionWithAction.utf8)) as? [String: Any])
                let citation: [String: Any] = ["segment_id": "s0", "start_seconds": 0, "end_seconds": 1]
                mixed["decisions"] = [["id": "decision-fixture", "text": "Restored decision", "citations": [citation]]]
                mixed["my_action_items"] = [["id": "mixed-action", "text": "Restored action", "citations": [citation]]]
                try JSONSerialization.data(withJSONObject: mixed).write(to: directory.appendingPathComponent("summary-extraction.json"))
            } else {
            try extractionWithAction.write(to: directory.appendingPathComponent("summary-extraction.json"), atomically: true, encoding: .utf8)
            }
        }
        if let myActionItem, let savedActionTitle {
            let workspace = fixtureRoot.appendingPathComponent("workspace")
            let inbox = try TasksInbox(databaseURL: fixtureRoot.appendingPathComponent("support/operational.sqlite"))
                .scoped(to: workspace)
            let proposalID = "meeting-action:ui-fixture:action-fixture"
            let sourceRef = "[[Meetings/ui-fixture/summary#My action items|ref]]"
            XCTAssertTrue(try inbox.queueProposal(id: proposalID, title: myActionItem, sourceRef: sourceRef))
            try inbox.saveProposalDraft(id: proposalID, title: savedActionTitle, comment: "")
        }
        relaunch()
    }
}
