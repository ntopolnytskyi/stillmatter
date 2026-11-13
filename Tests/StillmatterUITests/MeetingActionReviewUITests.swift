import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testMeetingActionApprovalOwnerEditingBatchesAndRelaunch() throws {
        try seedMeeting(transcript: true, notes: "- [ ] Note task", myActionItem: "My generated task", otherActionItem: "Other task")
        openFixtureMeeting(); app.radioButtons["Action Items"].click()
        let mineBatch = app.buttons["meeting-actions-accept-mine"]
        XCTAssertTrue(mineBatch.waitForExistence(timeout: 10))
        let actionsURL = meetingURL.deletingLastPathComponent().appendingPathComponent("action-items.md")
        func itemID(_ legacy: String) throws -> String {
            let lines = try String(contentsOf: actionsURL, encoding: .utf8).components(separatedBy: "\n")
            for line in lines {
                guard let start = line.range(of: "<!-- sm-item:"), let end = line.range(of: " -->", range: start.upperBound..<line.endIndex) else { continue }
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
                if object["legacyID"] as? String == legacy { return try XCTUnwrap(object["id"] as? String) }
            }
            throw NSError(domain: "Missing fixture item", code: 1)
        }
        let unknown = try itemID("unknown")
        let mine = try itemID("action-fixture")
        XCTAssertFalse(app.buttons["meeting-item-accept-" + unknown].isEnabled)
        XCTAssertFalse(app.buttons["meeting-actions-accept-others"].isEnabled)
        let owner = app.textFields["meeting-item-owner-" + unknown]
        owner.click(); owner.typeText("Alice")
        let due = app.textFields["meeting-item-due-" + unknown]
        due.click(); due.typeText("2026-02-30")
        app.buttons["meeting-item-save-" + unknown].click()
        let feedback = app.staticTexts["meeting-actions-feedback"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Save failed"), evaluatedWith: feedback)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(owner.value as? String, "Alice")
        due.click(); due.typeKey("a", modifierFlags: .command); due.typeText("2026-12-03")
        app.buttons["meeting-item-save-" + unknown].click()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["meeting-actions-accept-others"])
        waitForExpectations(timeout: 10)
        app.buttons["meeting-actions-accept-others"].click()
        mineBatch.click()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: mineBatch)
        waitForExpectations(timeout: 10)
        let status = app.popUpButtons["meeting-item-status-" + mine]
        status.click(); app.menuItems["Postponed"].click()
        app.buttons["meeting-item-save-" + mine].click()
        expectation(for: NSPredicate(format: "value == %@", "Postponed"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        status.click(); app.menuItems["Open"].click(); app.buttons["meeting-item-save-" + mine].click()
        expectation(for: NSPredicate(format: "value == %@", "Open"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        status.click(); app.menuItems["Completed"].click(); app.buttons["meeting-item-save-" + mine].click()
        expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Reopen"].exists)
        relaunch(); openFixtureMeeting(); app.radioButtons["Action Items"].click()
        XCTAssertEqual(app.popUpButtons["meeting-item-status-" + mine].value as? String, "Completed")
        XCTAssertEqual(app.textFields["meeting-item-owner-" + unknown].value as? String, "Alice")
        let todoURL = fixtureRoot.appendingPathComponent("workspace/Todos/todo.md")
        let todo = try String(contentsOf: todoURL, encoding: .utf8)
        XCTAssertEqual(todo.components(separatedBy: "[[item:" + mine).count - 1, 1)
        XCTAssertFalse(todo.contains(unknown))
    }
}
