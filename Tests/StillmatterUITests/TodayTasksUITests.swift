import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testTodoEditorWritesNoteAuthoredTaskBackToMyNotes() throws {
        app.terminate()
        let queue = try seedPersonalQueue()
        relaunch()
        app.buttons["sidebar-tasks"].click()
        let edit = app.buttons["task-edit-ee935d20-e388-4ccf-b6bd-1f5dc785fd01"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.click()
        let alert = app.dialogs.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let editor = alert.textFields["task-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("Updated from Todo")
        alert.buttons["Save"].click()
        XCTAssertTrue(app.buttons["Edit Updated from Todo"].waitForExistence(timeout: 10))
        relaunch()
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.buttons["Edit Updated from Todo"].waitForExistence(timeout: 10))
        let notes = fixtureRoot.appendingPathComponent("workspace/Meetings/task/my-notes.md")
        XCTAssertTrue(try String(contentsOf: notes).contains("- [ ] Updated from Todo <!-- sm-item:"))
        XCTAssertEqual(try String(contentsOf: queue).components(separatedBy: "[[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01").count - 1, 1)
    }

    func testTodayTasksSharedControlsCompleteCanonicalItemsAndPreserveNavigation() throws {
        app.terminate()
        let queue = try seedPersonalQueue()
        relaunch()
        app.buttons["sidebar-today"].click()
        let todayRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-")).firstMatch
        XCTAssertTrue(todayRow.waitForExistence(timeout: 15))
        let before = try Data(contentsOf: queue)
        todayRow.click()
        let listing = app.tables["tasks-listing"]
        XCTAssertTrue(listing.waitForExistence(timeout: 15))
        let filter = app.searchFields["tasks-source-filter"]
        filter.click()
        filter.typeText("notes")
        expectation(for: NSPredicate { _, _ in listing.tableRows.count == 1 }, evaluatedWith: listing)
        waitForExpectations(timeout: 10)
        // Typing a space in the field must not complete the selected task.
        filter.typeText(" ")
        XCTAssertEqual(try Data(contentsOf: queue), before)
        app.buttons["sidebar-today"].click()
        XCTAssertTrue(todayRow.waitForExistence(timeout: 10))
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertEqual(filter.value as? String, "notes ")
        XCTAssertEqual(try Data(contentsOf: queue), before)
        let completion = app.checkBoxes["Complete Personal task"]
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        completion.click()
        XCTAssertTrue(app.staticTexts["No matching Todo Items"].waitForExistence(timeout: 10))
        let notes = fixtureRoot.appendingPathComponent("workspace/Meetings/task/my-notes.md")
        XCTAssertTrue(try String(contentsOf: notes).contains("- [x] Personal task"))
        let doneMode = app.radioGroups["tasks-mode"].radioButtons["Done"]
        XCTAssertTrue(doneMode.waitForExistence(timeout: 10))
        doneMode.click()
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier CONTAINS[c] 'reopen' OR label CONTAINS[c] 'reopen'")).firstMatch.exists)
        app.radioGroups["tasks-mode"].radioButtons["Queue"].click()
        filter.click()
        filter.typeKey("a", modifierFlags: .command)
        filter.typeKey(.delete, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in listing.tableRows.count == 2 }, evaluatedWith: listing)
        waitForExpectations(timeout: 10)
        listing.tableRows.element(boundBy: 0).click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(listing.tableRows.element(boundBy: 1).isSelected)
        app.typeKey(.space, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in listing.tableRows.count == 1 }, evaluatedWith: listing)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(listing.tableRows.element(boundBy: 0).isSelected)
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["No Queue Todo Items"].waitForExistence(timeout: 10))
        let saved = try String(contentsOf: queue)
        XCTAssertEqual(saved.components(separatedBy: "[[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01").count - 1, 1)
        XCTAssertEqual(saved.components(separatedBy: "- [x] Second").count - 1, 1)
        XCTAssertEqual(saved.components(separatedBy: "- [x] Third").count - 1, 1)
        app.terminate()
        relaunch()
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.staticTexts["No Queue Todo Items"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: queue), saved)
        app.buttons["sidebar-today"].click()
        XCTAssertTrue(app.staticTexts["○  No open Todo Items in the Queue."].waitForExistence(timeout: 15))
    }

    func testKeyboardCompletesTheCanonicalNoteItemWithoutDuplicatingIt() throws {
        app.terminate()
        let queue = try seedPersonalQueue()
        relaunch()
        app.buttons["sidebar-tasks"].click()
        let listing = app.tables["tasks-listing"]
        XCTAssertTrue(listing.waitForExistence(timeout: 15))
        let checkbox = app.checkBoxes["Complete Personal task"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 15))
        listing.tableRows.element(boundBy: 0).click()
        app.typeKey(.space, modifierFlags: [])
        expectation(for: NSPredicate { _, _ in listing.tableRows.count == 2 }, evaluatedWith: listing)
        waitForExpectations(timeout: 10)
        let notes = fixtureRoot.appendingPathComponent("workspace/Meetings/task/my-notes.md")
        XCTAssertTrue(try String(contentsOf: notes).contains("- [x] Personal task"))
        let saved = try String(contentsOf: queue)
        XCTAssertEqual(saved.components(separatedBy: "[[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01").count - 1, 1)
        XCTAssertTrue(saved.contains("## Queue\n- [ ] Second\n- [ ] Third"))
        XCTAssertTrue(listing.tableRows.element(boundBy: 0).isSelected)
    }

    func testTodayAndTasksFailedLoadRetryUsesSharedControlsWithoutRepairingFiles() throws {
        app.terminate()
        let queue = try seedPersonalQueue()
        let valid = try Data(contentsOf: queue)
        let malformed = Data("## Queue\n- [[item:not-a-valid-uuid|Broken]]\n".utf8)
        try malformed.write(to: queue)
        relaunch()
        app.buttons["sidebar-today"].click()
        let todayRetry = app.buttons["today-state-action"]
        XCTAssertTrue(todayRetry.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["!  Today could not be loaded"].exists)
        todayRetry.click()
        XCTAssertEqual(try Data(contentsOf: queue), malformed)
        app.buttons["sidebar-tasks"].click()
        let retry = app.buttons["tasks-state-action"]
        XCTAssertTrue(retry.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Tasks could not be loaded"].exists)
        try valid.write(to: queue)
        retry.click()
        XCTAssertTrue(app.checkBoxes["Complete Personal task"].waitForExistence(timeout: 15))
        app.buttons["sidebar-today"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: queue), valid)
    }

    func testTodayGroupsMeetingReviewsAndOpensActionItemsWithLiveCounts() throws {
        try seedMeeting(transcript: true, myActionItem: "Mine pending", otherActionItem: "Unknown pending")
        app.terminate()
        let second = fixtureRoot.appendingPathComponent("workspace/Meetings/second")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try "---\ntitle: Second review\ncapture_session_id: second\n---\n".write(to: second.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        let metadata = #"{"v":1,"id":"ee935d20-e388-4ccf-b6bd-1f5dc785fd02","owner":"Alice","review":"pending","origin":"generated","citations":[]}"#
        try ("<!-- stillmatter-artifact:actions:v1 -->\n- [ ] Other person's proposal <!-- sm-item:" + metadata + " -->\n")
            .write(to: second.appendingPathComponent("action-items.md"), atomically: true, encoding: .utf8)
        relaunch()
        app.buttons["sidebar-today"].click()
        let first = app.buttons["today-inbox-meeting-review:ui-fixture"]
        let secondRow = app.buttons["today-inbox-meeting-review:second"]
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        XCTAssertTrue(secondRow.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-inbox-meeting-review:")).count, 2)
        XCTAssertTrue(first.label.contains("2 awaiting approval"))
        XCTAssertTrue(secondRow.label.contains("1 awaiting approval"))
        XCTAssertFalse(app.buttons["proposal-accept-meeting-action:ui-fixture:action-fixture"].exists)
        let before = try Data(contentsOf: meetingURL)
        first.click()
        XCTAssertTrue(app.buttons["meeting-actions-accept-mine"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.radioButtons["Action Items"].value as? Int, 1)
        XCTAssertEqual(try Data(contentsOf: meetingURL), before)
        app.buttons["meeting-actions-accept-mine"].click()
        app.buttons["sidebar-today"].click()
        expectation(for: NSPredicate { _, _ in first.exists && first.label.contains("1 awaiting approval") }, evaluatedWith: first)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-")).count, 1)
        first.click()
        let rejects = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting-item-reject-"))
        XCTAssertTrue(rejects.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(rejects.count, 1)
        rejects.firstMatch.click()
        app.buttons["sidebar-today"].click()
        expectation(for: NSPredicate { _, _ in !first.exists }, evaluatedWith: first)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(secondRow.exists)
        // External deletion refreshes an already visible Today without a file repair.
        try FileManager.default.removeItem(at: second)
        expectation(for: NSPredicate { _, _ in !secondRow.exists }, evaluatedWith: secondRow)
        waitForExpectations(timeout: 15)
        relaunch(); app.buttons["sidebar-today"].click()
        XCTAssertTrue(app.buttons["today-empty-review"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "today-todo-")).count, 1)
    }

    private func seedPersonalQueue() throws -> URL {
        let workspace = fixtureRoot.appendingPathComponent("workspace")
        let source = workspace.appendingPathComponent("Meetings/task/my-notes.md")
        let queue = workspace.appendingPathComponent("Todos/todo.md")
        for directory in [source.deletingLastPathComponent(), queue.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let metadata = #"{"v":1,"id":"ee935d20-e388-4ccf-b6bd-1f5dc785fd01","owner":"me","review":"approved","origin":"notes","citations":[]}"#
        try "# Notes\n- [ ] Personal task <!-- sm-item:\(metadata) -->\n".write(to: source, atomically: true, encoding: .utf8)
        try "## Queue\n- [[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01|Personal task]]\n- [ ] Second\n- [ ] Third\n\n## Done\n".write(to: queue, atomically: true, encoding: .utf8)
        return queue
    }
}
