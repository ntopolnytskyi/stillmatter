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

    func testSearchResultNavigatesToOwningMeetingAreaAndSelectsMeeting() throws {
        app.terminate()
        let originalDirectory = meetingURL.deletingLastPathComponent()
        let targetDirectory = fixtureRoot.appendingPathComponent("workspace/Meetings/target-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: originalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try "---\ntitle: UI fixture meeting\ncapture_session_id: ui-fixture\n---\n# UI fixture meeting\n\n## Notes\n\nOriginal notes.\n"
            .write(to: meetingURL, atomically: true, encoding: .utf8)
        try "## Summary\n\nOriginal summary.\n"
            .write(to: originalDirectory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "---\ntitle: Target UI meeting\ncapture_session_id: target-fixture\n---\n# Target UI meeting\n"
            .write(to: targetDirectory.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        try "## Summary\n\nTicket07TargetSummaryMarker.\n"
            .write(to: targetDirectory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        relaunch()
        app.buttons["sidebar-meetings"].click()
        let meetings = app.tables["Meetings"]
        XCTAssertTrue(meetings.staticTexts["UI fixture meeting"].waitForExistence(timeout: 10))
        XCTAssertTrue(meetings.staticTexts["Target UI meeting"].waitForExistence(timeout: 10))
        meetings.staticTexts["UI fixture meeting"].click()
        XCTAssertEqual(app.staticTexts["meeting-detail"].value as? String, "UI fixture meeting")
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Ticket07TargetSummaryMarker")
        let results = app.tables["Search results"]
        XCTAssertTrue(results.waitForExistence(timeout: 15))
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 10))
        search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForArea("Meetings")
        XCTAssertTrue(app.staticTexts["meeting-detail"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["meeting-detail"].value as? String, "Target UI meeting")
        XCTAssertTrue(meetings.staticTexts["Target UI meeting"].exists)
        XCTAssertEqual(search.value as? String, "Ticket07TargetSummaryMarker", "Opening a result keeps the global query available")
    }

    func testTodoSearchResultOpensTasksAndResultTypeKeepsQuery() throws {
        app.terminate()
        let todo = fixtureRoot.appendingPathComponent("workspace/Todos/todo.md")
        try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Todos\n\n## Queue\n\n- [ ] Ticket07TodoSearchMarker\n"
            .write(to: todo, atomically: true, encoding: .utf8)
        relaunch()
        app.buttons["sidebar-today"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.typeText("Ticket07TodoSearchMarker")
        let results = app.tables["Search results"]
        XCTAssertTrue(results.waitForExistence(timeout: 15))
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 10))
        let resultType = app.popUpButtons["global-search-type"]
        XCTAssertTrue(resultType.waitForExistence(timeout: 10))
        resultType.click()
        app.menuItems["Todo Item"].click()
        XCTAssertEqual(search.value as? String, "Ticket07TodoSearchMarker")
        XCTAssertTrue(results.waitForExistence(timeout: 15))
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 10))
        search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        waitForArea("Tasks")
        XCTAssertTrue(app.staticTexts["Ticket07TodoSearchMarker"].waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Ticket07TodoSearchMarker")
    }

    func testMinimumWindowShowsGlobalSearchAndBackRestoresMeetingSelection() throws {
        try seedMeeting()
        let window = app.windows["Stillmatter"]
        func resizeWindow(width: CGFloat, height: CGFloat) {
            let frame = window.frame
            let lowerTrailingCorner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -4, dy: -4))
            let offset = CGVector(dx: width - frame.width, dy: height - frame.height)
            lowerTrailingCorner.press(forDuration: 0.1, thenDragTo: lowerTrailingCorner.withOffset(offset))
            expectation(for: NSPredicate { _, _ in
                abs(window.frame.width - width) < 3 && abs(window.frame.height - height) < 3
            }, evaluatedWith: window)
            waitForExpectations(timeout: 10)
        }

        resizeWindow(width: 1200, height: 760)
        let search = app.searchFields["Search"]
        XCTAssertTrue(search.exists)
        XCTAssertTrue(window.frame.intersects(search.frame), "Global Search must remain on-screen at wide size")
        app.buttons["sidebar-meetings"].click()
        let meetings = app.tables["Meetings"]
        let row = meetings.tableRows.containing(.staticText, identifier: "UI fixture meeting").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.staticTexts["meeting-detail"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(row.frame.width, 0, "The Listing column must remain usable at wide size")
        XCTAssertTrue(window.frame.intersects(app.staticTexts["meeting-detail"].frame),
                      "The Detail Workspace must remain visible at wide size")

        resizeWindow(width: 720, height: 520)
        XCTAssertTrue(search.exists)
        XCTAssertTrue(window.frame.intersects(search.frame), "Global Search must stay on-screen at the minimum window size")
        let back = app.buttons["narrow-back"]
        let compactRow = meetings.tableRows.containing(.staticText, identifier: "UI fixture meeting").firstMatch
        if !back.waitForExistence(timeout: 2) {
            XCTAssertTrue(compactRow.waitForExistence(timeout: 10))
            compactRow.click()
        }
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.click()
        XCTAssertTrue(compactRow.waitForExistence(timeout: 10))
        XCTAssertTrue(compactRow.isSelected, "Back must restore the retained Meeting selection")
    }

    func testMeetingListingFiltersRemainSeparateFromGlobalSearchAndSurviveNavigation() throws {
        try seedMeeting()
        let before = try meetingText()
        app.buttons["sidebar-meetings"].click()
        XCTAssertTrue(app.tables["Meetings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["meeting-detail"].exists)
        XCTAssertTrue(app.buttons["sidebar-settings"].exists)
        let filter = app.searchFields["meetings-list-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertTrue(app.tables["Meetings"].staticTexts["UI fixture meeting"].firstMatch.waitForExistence(timeout: 10))
        filter.click()
        filter.typeText("fixture")
        XCTAssertEqual(filter.value as? String, "fixture")
        app.typeKey("f", modifierFlags: .command)
        let global = app.searchFields["Search"]
        XCTAssertTrue(global.waitForExistence(timeout: 10))
        XCTAssertEqual(global.value as? String, "")
        global.typeText("nonexistent-search-07")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15))
        global.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(filter.waitForExistence(timeout: 10))
        XCTAssertEqual(filter.value as? String, "fixture")
        XCTAssertEqual(global.value as? String, "nonexistent-search-07")
        XCTAssertTrue(app.buttons["meetings-show-filters"].exists)
        XCTAssertTrue(app.buttons["meetings-clear-filters"].exists == false)
        app.buttons["sidebar-today"].click()
        app.buttons["sidebar-meetings"].click()
        XCTAssertEqual(filter.value as? String, "fixture")
        XCTAssertEqual(try meetingText(), before)
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
