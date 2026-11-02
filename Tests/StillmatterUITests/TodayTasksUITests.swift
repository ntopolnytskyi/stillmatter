import Foundation
import XCTest

extension StillmatterFlowsUITests {
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
