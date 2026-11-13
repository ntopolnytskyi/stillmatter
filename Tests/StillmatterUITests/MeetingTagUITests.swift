import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testSharedTagsKeyboardGlobalManagementAndTodoPersistence() throws {
        try seedMeeting(notes: "- [ ] Note task #work", myActionItem: "Generated task")
        openFixtureMeeting(); app.radioButtons["Action Items"].click()
        let notesURL = meetingURL.deletingLastPathComponent().appendingPathComponent("my-notes.md")
        func noteID() throws -> String {
            let text = try String(contentsOf: notesURL, encoding: .utf8)
            let start = try XCTUnwrap(text.range(of: "<!-- sm-item:"))
            let end = try XCTUnwrap(text.range(of: " -->", range: start.upperBound..<text.endIndex))
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
            return try XCTUnwrap(value["id"] as? String)
        }
        let window = app.windows["Stillmatter"]
        let original = window.frame
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -4, dy: -4))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 880 - original.width, dy: 680 - original.height)))
        expectation(for: NSPredicate { _, _ in abs(window.frame.width - 880) < 3 }, evaluatedWith: window)
        waitForExpectations(timeout: 10)
        let id = try noteID()
        let edit = app.buttons["meeting-item-edit-tags-" + id]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.click()
        let name = app.textFields["tag-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText("bad tag")
        app.buttons["tag-create"].click()
        let feedback = app.staticTexts["tag-feedback"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "not saved"), evaluatedWith: feedback)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(name.value as? String, "bad tag")
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("team")
        name.typeKey(.return, modifierFlags: .command)
        expectation(for: NSPredicate(format: "value == %@", "Tags saved."), evaluatedWith: feedback)
        waitForExpectations(timeout: 10)
        app.popUpButtons["tag-catalog"].click(); app.menuItems["team"].click()
        app.buttons["tag-add"].click()
        XCTAssertTrue(app.buttons["tag-remove-team"].waitForExistence(timeout: 10))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("group")
        app.buttons["tag-rename"].click()
        XCTAssertTrue(app.buttons["tag-remove-group"].waitForExistence(timeout: 10))
        app.buttons["Done"].click()
        // Dismissal restores the logical source control after the item view refreshes.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.buttons["Done"].click()
        app.buttons["sidebar-tasks"].click()
        let todoTags = app.buttons["task-tags-" + id]
        XCTAssertTrue(todoTags.waitForExistence(timeout: 10)); todoTags.click()
        XCTAssertTrue(app.buttons["tag-remove-group"].waitForExistence(timeout: 5))
        app.buttons["tag-delete"].click() // selected group is first in the sorted catalog
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["tag-remove-group"])
        waitForExpectations(timeout: 10)
        app.buttons["tag-remove-work"].click()
        XCTAssertTrue(app.staticTexts["No tags on this item."].waitForExistence(timeout: 10))
        app.popUpButtons["tag-catalog"].click(); app.menuItems["work"].click()
        app.buttons["tag-add"].click()
        XCTAssertTrue(app.buttons["tag-remove-work"].waitForExistence(timeout: 10))
        app.buttons["Done"].click()
        relaunch(); openFixtureMeeting(); app.radioButtons["Action Items"].click()
        app.buttons["meeting-item-edit-tags-" + id].click()
        XCTAssertTrue(app.buttons["tag-remove-work"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["tag-remove-group"].exists)
        app.buttons["Done"].click()
        let text = try String(contentsOf: notesURL, encoding: .utf8)
        XCTAssertTrue(text.contains("Note task #work")); XCTAssertFalse(text.contains("#ai-gen")); XCTAssertFalse(text.contains("#need-approve"))
        let todo = try String(contentsOf: fixtureRoot.appendingPathComponent("workspace/Todos/todo.md"), encoding: .utf8)
        XCTAssertEqual(todo.components(separatedBy: "[[item:" + id).count - 1, 1)
    }
}
