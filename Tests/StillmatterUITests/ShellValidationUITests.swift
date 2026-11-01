import Foundation
import XCTest
import StillmatterCore

extension StillmatterFlowsUITests {
    func testNavigationRailAndMenuReachTheSameAreas() {
        for area in ["Meetings"] {
            app.buttons["sidebar-\(area.lowercased())"].click()
            waitForArea(area)
            app.menuBars.menuBarItems["Navigate"].click()
            app.menuBars.menuItems["Today"].click()
            waitForArea("Today")
            app.menuBars.menuBarItems["Navigate"].click()
            app.menuBars.menuItems[area].click()
            waitForArea(area)
        }
    }

    func testSearchKeyboardNavigationAndEscapePreserveQuery() throws {
        app.terminate()
        let todos = fixtureRoot.appendingPathComponent("workspace/Todos")
        try FileManager.default.createDirectory(at: todos, withIntermediateDirectories: true)
        try "# Todos\n\n## Queue\n\n- [ ] KeyboardSearchMarker one\n- [ ] KeyboardSearchMarker two\n"
            .write(to: todos.appendingPathComponent("todo.md"), atomically: true, encoding: .utf8)
        relaunch()
        app.buttons["sidebar-today"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        // Typing without clicking proves Command-F handed keyboard focus to Search.
        search.typeText("KeyboardSearchMarker")
        let results = app.tables["Search results"]
        XCTAssertTrue(results.waitForExistence(timeout: 20))
        expectation(for: NSPredicate { _, _ in results.tableRows.count == 2 }, evaluatedWith: results)
        waitForExpectations(timeout: 20)
        search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(results.tableRows.element(boundBy: 1).isSelected)
        app.typeKey(.escape, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: results)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(search.value as? String, "KeyboardSearchMarker")
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "KeyboardSearchMarker")
    }

    func testExternalMeetingEditRefreshesVisibleBrowserAndDetail() throws {
        try seedMeeting()
        openFixtureMeeting()
        let updated = try meetingText().replacingOccurrences(of: "UI fixture meeting", with: "Externally renamed fixture")
        try updated.write(to: meetingURL, atomically: true, encoding: .utf8)
        let row = app.tables["Meetings"].staticTexts["Externally renamed fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "value == %@", "Externally renamed fixture"), evaluatedWith: app.staticTexts["meeting-detail"])
        waitForExpectations(timeout: 15)
        XCTAssertEqual(try meetingText(), updated, "Refreshing must not rewrite canonical content")
    }

    func testExternalTodoEditRefreshesVisibleTasks() throws {
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.staticTexts["No Queue Todo Items"].waitForExistence(timeout: 10))
        let todo = fixtureRoot.appendingPathComponent("workspace/Todos/todo.md")
        try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = "# Todos\n\n## Queue\n\n- [ ] Externally added UI test Todo\n"
        try contents.write(to: todo, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Externally added UI test Todo"].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: todo, encoding: .utf8), contents)
    }

    func testAcceptProposalCreatesExactlyOneTodoWithItsSource() throws {
        app.terminate()
        let workspace = fixtureRoot.appendingPathComponent("workspace")
        let meeting = workspace.appendingPathComponent("Meetings/validation-launch")
        let todo = workspace.appendingPathComponent("Todos/todo.md")
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Validation Launch\n\n## My action items\n\n- Send the launch recap.\n".write(to: meeting.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let before = "# Todos\n\n## Queue\n"
        try before.write(to: todo, atomically: true, encoding: .utf8)
        // Prepare the real scoped operational store before launch. This works in
        // the shipping configuration without enabling a debug-only app fixture.
        let database = fixtureRoot.appendingPathComponent("support/operational.sqlite")
        let inbox = try TasksInbox(databaseURL: database).scoped(to: workspace)
        XCTAssertTrue(try inbox.queueProposal(id: "validation:accept",
            title: "Send the launch recap #ai-proposed",
            sourceRef: "[[Meetings/validation-launch/summary#My action items|source]]"))
        relaunch()
        app.buttons["sidebar-today"].click()
        let accept = app.buttons["proposal-accept-validation:accept"]
        XCTAssertTrue(accept.waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: todo, encoding: .utf8), before, "Viewing proposals must not create Todos")
        let title = app.textFields["proposal-title-validation:accept"]
        title.click()
        title.typeKey("a", modifierFlags: .command)
        title.typeText("Accepted once through native UI")
        accept.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: accept)
        waitForExpectations(timeout: 15)
        let saved = try String(contentsOf: todo, encoding: .utf8)
        XCTAssertEqual(saved.components(separatedBy: "Accepted once through native UI").count - 1, 1)
        XCTAssertTrue(saved.contains("[[Meetings/validation-launch/summary#My action items|source]]"))
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.staticTexts["Accepted once through native UI"].waitForExistence(timeout: 10))
        app.buttons["sidebar-today"].click()
        XCTAssertFalse(accept.exists)
        XCTAssertEqual(try String(contentsOf: todo, encoding: .utf8), saved)
    }

    private func waitForArea(_ area: String) {
        expectation(for: NSPredicate(format: "value == %@", area), evaluatedWith: app.staticTexts["Current area"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.buttons["sidebar-\(area.lowercased())"].value as? String, "Selected")
    }

}
