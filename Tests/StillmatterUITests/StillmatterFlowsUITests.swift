import Foundation
import XCTest
import AVFoundation
import StillmatterCore

/// Named end-to-end outcomes against the real Stillmatter.app, never the control host.
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
    }

    override func tearDownWithError() throws {
        if let app, (testRun?.failureCount ?? 0) > 0 {
            if app.state == .runningForeground || app.state == .runningBackground {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Failure screenshot"
                screenshot.lifetime = .keepAlways
                add(screenshot)
                attach(app.debugDescription, named: "Accessibility tree")
            }
            attachFixtureState()
        }
        app?.terminate()
        if let fixtureRoot {
            UserDefaults.standard.removePersistentDomain(forName: "works.stillmatter.validation.\(fixtureRoot.lastPathComponent)")
            try FileManager.default.removeItem(at: fixtureRoot)
        }
    }

    func testE2E01RecordingToMeetingRequiresSafeRealAppCapture() throws {
        throw XCTSkip("Real-app synthetic capture is unavailable. No permission prompts or hardware access allowed. Synthetic capture and durable live notes are covered by ControlBehaviorRegressionTests; see testing-strategy.md for manual acceptance.")
    }

    func testE2E02MeetingNotesSurviveRestart() throws {
        try seedMeeting()
        openFixtureMeeting()
        openEditor("notes")
        replaceEditorText("Notes saved through the real app")
        editor.typeKey(.return, modifierFlags: .command)
        waitForEditorToClose()
        let canonical = try notesText()
        XCTAssertTrue(canonical.contains("Notes saved through the real app"))
        XCTAssertFalse(try meetingText().contains("Notes saved through the real app"))
        relaunch()
        openFixtureMeeting()
        openEditor("notes")
        XCTAssertEqual(editor.value as? String, "Notes saved through the real app")
        XCTAssertEqual(try notesText(), canonical)
        // The same editing journey can leave its reopened reader without saving another draft.
        replaceEditorText("Discard this reopened draft")
        editor.typeKey(.escape, modifierFlags: [])
        waitForEditorToClose()
        XCTAssertEqual(try notesText(), canonical)
    }

    func testE2E03TranscriptTimestampSeeksSyntheticMedia() throws {
        let source = try seedPlayableTranscript()
        let transcript = try Data(contentsOf: source.transcript)
        let audio = try Data(contentsOf: source.audio)
        relaunch()
        app.buttons["sidebar-meetings"].click()
        let row = app.tables["Meetings"].staticTexts["Playable meeting"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        app.radioButtons["Transcript"].click()
        let picker = app.popUpButtons["meeting-transcript-view"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.click()
        app.menuItems["Grouped by speaker"].click()
        let timestamp = app.buttons["transcript-time-early"]
        expectation(for: NSPredicate(format: "exists == true AND enabled == true"), evaluatedWith: timestamp)
        waitForExpectations(timeout: 10)
        timestamp.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "0:02 / 0:08")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play Meeting audio"].exists, "Seeking remains paused")
        XCTAssertEqual(try Data(contentsOf: source.transcript), transcript)
        XCTAssertEqual(try Data(contentsOf: source.audio), audio)
    }

    func testE2E04ApproveActionCreatesOneCanonicalTodoAfterRestart() throws {
        try seedMeeting(transcript: true, myActionItem: "My generated task")
        openFixtureMeeting()
        app.radioButtons["Action Items"].click()
        let approve = app.buttons["meeting-actions-accept-mine"]
        XCTAssertTrue(approve.waitForExistence(timeout: 10))
        let source = meetingURL.deletingLastPathComponent().appendingPathComponent("action-items.md")
        let before = try String(contentsOf: source)
        let item = try XCTUnwrap(TodoItemParser().parse(markdown: before, relativePath: "Meetings/ui-fixture/action-items.md").first)
        approve.click()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: approve)
        waitForExpectations(timeout: 10)
        let queue = fixtureRoot.appendingPathComponent("workspace/Todos/todo.md")
        let reference = "[[item:\(item.id)"
        XCTAssertEqual(try String(contentsOf: queue).components(separatedBy: reference).count - 1, 1)
        let canonical = try String(contentsOf: source)
        XCTAssertTrue(canonical.contains(item.id))
        XCTAssertTrue(canonical.contains("approved"))
        relaunch()
        openFixtureMeeting()
        app.radioButtons["Action Items"].click()
        XCTAssertTrue(app.popUpButtons["meeting-item-status-" + item.id].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["meeting-actions-accept-mine"].isEnabled)
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.checkBoxes["task-complete-" + item.id].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: queue).components(separatedBy: reference).count - 1, 1)
        XCTAssertEqual(try String(contentsOf: source), canonical, "Relaunch does not replace the source identity")
    }

    func testE2E05CompleteCanonicalTodo() throws {
        let queue = try seedPersonalQueue()
        relaunch()
        app.buttons["sidebar-today"].click()
        let today = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-")).firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 15))
        today.click()
        let complete = app.checkBoxes["Complete Personal task"]
        XCTAssertTrue(complete.waitForExistence(timeout: 10))
        complete.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: complete)
        waitForExpectations(timeout: 10)
        let notes = fixtureRoot.appendingPathComponent("workspace/Meetings/task/my-notes.md")
        XCTAssertTrue(try String(contentsOf: notes).contains("- [x] Personal task"))
        XCTAssertEqual(try String(contentsOf: queue).components(separatedBy: "[[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01").count - 1, 1)
        app.buttons["sidebar-today"].click()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-"))
        expectation(for: NSPredicate { _, _ in rows.count == 2 }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["today-todo-ee935d20-e388-4ccf-b6bd-1f5dc785fd01"].exists)
    }

    func testE2E06GlobalSearchOpensMeetingAndEscapeKeepsQuery() throws {
        try seedMeeting()
        app.buttons["sidebar-meetings"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Original summary") // No click: Command-F must transfer focus.
        let results = app.tables["Search results"]
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 15))
        search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let detail = app.staticTexts["meeting-detail"]
        expectation(for: NSPredicate(format: "value == %@", "UI fixture meeting"), evaluatedWith: detail)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.radioButtons["Summary"].value as? Int, 1)
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        app.typeKey(.escape, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: results)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(search.value as? String, "Original summary")
        XCTAssertEqual(detail.value as? String, "UI fixture meeting")
    }

    func testE2E07ExternalMarkdownRefreshesOpenMeeting() throws {
        try seedMeeting()
        openFixtureMeeting()
        let external = try meetingText().replacingOccurrences(of: "UI fixture meeting", with: "Externally renamed fixture")
        try external.write(to: meetingURL, atomically: true, encoding: .utf8)
        let row = app.tables["Meetings"].staticTexts["Externally renamed fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value == %@", "Externally renamed fixture"), evaluatedWith: app.staticTexts["meeting-detail"])
        waitForExpectations(timeout: 15)
        XCTAssertEqual(try meetingText(), external)
    }

    func testE2E08ArchiveReopensReadOnlyAfterRestart() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting()
        let notes = try notesText()
        let archive = app.buttons["meeting-archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 10))
        XCTAssertTrue(archive.isEnabled)
        archive.click()
        let marker = meetingURL.deletingLastPathComponent().appendingPathComponent("archive.json")
        expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) }, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        XCTAssertEqual(object["archived"] as? Bool, true)
        relaunch()
        app.buttons["sidebar-meetings"].click()
        app.buttons["Recorded"].click()
        app.buttons["Show Meeting filters"].click()
        app.popUpButtons["Meeting archive filter"].click()
        app.menuItems["Archived Meetings"].click()
        let row = app.tables["Meetings"].staticTexts["UI fixture meeting"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.buttons["meeting-edit-summary"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["meeting-edit-summary"].isEnabled)
        app.radioButtons["My Notes"].click()
        XCTAssertFalse(app.buttons["meeting-edit-notes"].isEnabled)
        XCTAssertFalse(app.buttons["meeting-overview-edit-notes"].isEnabled)
        XCTAssertEqual(try notesText(), notes)
    }

    func testE2E09ImportCreatesDurableMeeting() throws {
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
        relaunch()
        app.buttons["sidebar-recording"].click()
        let button = app.buttons["recording-import"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        let location = app.sheets.textFields.firstMatch
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.typeText(original.path)
        app.typeKey(.return, modifierFlags: [])
        let confirm = app.windows["open-panel"].buttons["Import"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        app.buttons["sidebar-meetings"].click()
        let row = app.tables["Meetings"].staticTexts["Imported sample"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        XCTAssertTrue(app.radioButtons["My Notes"].waitForExistence(timeout: 10))
        let meetings = fixtureRoot.appendingPathComponent("workspace/Meetings")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: meetings, includingPropertiesForKeys: nil))
        let doorways = files.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "meeting.md" }
        XCTAssertEqual(doorways.count, 1)
        let canonical = try XCTUnwrap(doorways.first)
        XCTAssertTrue(try String(contentsOf: canonical).contains("Imported sample"))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        relaunch()
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.click()
        XCTAssertTrue(app.staticTexts["meeting-detail"].waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    private func attach(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachFixtureState() {
        guard let fixtureRoot, let enumerator = FileManager.default.enumerator(at: fixtureRoot,
            includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let files = enumerator.compactMap { $0 as? URL }.prefix(256)
        var snapshot = ""
        for file in files {
            snapshot += "\n\(file.path.replacingOccurrences(of: fixtureRoot.path, with: "<fixture>"))\n"
            if ["md", "json", "log"].contains(file.pathExtension), let data = try? Data(contentsOf: file) {
                snapshot += String(decoding: data.prefix(16_384), as: UTF8.self) + "\n"
            }
        }
        attach(snapshot, named: "Disposable fixture state and logs")
    }
}
