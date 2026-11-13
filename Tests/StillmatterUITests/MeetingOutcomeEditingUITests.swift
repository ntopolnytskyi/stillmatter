import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testDecisionsAndOpenItemsEditingConflictSourcesAndRelaunch() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting()
        XCTAssertFalse(app.radioButtons["Decisions"].exists)
        let directory = meetingURL.deletingLastPathComponent()
        func itemID(_ name: String, containing text: String) throws -> String {
            for line in try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n") where line.contains(text) {
                guard let start = line.range(of: "<!-- sm-item:"), let end = line.range(of: " -->", range: start.upperBound..<line.endIndex) else { continue }
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
                return try XCTUnwrap(json["id"] as? String)
            }
            throw NSError(domain: "Missing outcome", code: 1)
        }
        func feedback(_ prefix: String, contains value: String) {
            expectation(for: NSPredicate(format: "value CONTAINS %@", value), evaluatedWith: app.staticTexts[prefix + "-feedback"])
            waitForExpectations(timeout: 10)
        }
        let decision = "meeting-decisions", open = "meeting-open-items"
        let add = app.buttons[decision + "-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.click()
        let text = app.textFields[decision + "-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        app.buttons[decision + "-save"].click(); feedback(decision, contains: "Save failed")
        text.click(); text.typeText("New source-linked choice")
        let source = app.popUpButtons[decision + "-source"]
        source.click(); app.menuItems["0.0s · Synthetic searchable moment 0"].click()
        text.click(); text.typeKey(.return, modifierFlags: .command)
        feedback(decision, contains: "Changes saved")
        let id = try itemID("decisions.md", containing: "New source-linked choice")
        let sourceButton = app.buttons["meeting-outcome-source-" + id + "-0"]
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 5)); sourceButton.click()
        XCTAssertEqual(app.radioButtons["Transcript"].value as? Int, 1)
        app.radioButtons["Summary"].click()
        app.buttons[decision + "-edit-" + id].click()
        text.click(); text.typeKey("a", modifierFlags: .command); text.typeText("My local draft")
        let url = directory.appendingPathComponent("decisions.md")
        try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "New source-linked choice", with: "External choice").write(to: url, atomically: true, encoding: .utf8)
        app.buttons[decision + "-save"].click(); feedback(decision, contains: "Save failed")
        XCTAssertEqual(text.value as? String, "My local draft")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("External choice"))
        text.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(text.exists)
        app.radioButtons["Open Items"].click()
        app.buttons[open + "-add"].click()
        let question = app.textFields[open + "-text"]
        XCTAssertTrue(question.waitForExistence(timeout: 5)); question.typeText("Deployment blocker")
        app.textFields[open + "-owner"].click(); app.textFields[open + "-owner"].typeText("Alice")
        app.popUpButtons[open + "-type"].click(); app.menuItems["Issue"].click()
        app.buttons[open + "-save"].click(); feedback(open, contains: "Changes saved")
        let issue = try itemID("open-items.md", containing: "Deployment blocker")
        app.buttons[open + "-resolve-" + issue].click(); feedback(open, contains: "Changes saved")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons[open + "-resolve-" + issue])
        waitForExpectations(timeout: 10)
        relaunch(); openFixtureMeeting(); app.radioButtons["Open Items"].click()
        let row = app.staticTexts[open + "-row-" + issue]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); XCTAssertTrue((row.value as? String)?.contains("Resolved") == true)
        app.buttons[open + "-edit-" + issue].click()
        XCTAssertEqual(app.textFields[open + "-owner"].value as? String, "Alice")
        XCTAssertFalse(app.checkBoxes[open + "-resolved"].isEnabled)
        app.buttons[open + "-cancel"].click()
        app.buttons[open + "-delete-" + issue].click(); app.buttons["Delete"].click(); feedback(open, contains: "Changes saved")
        app.radioButtons["Summary"].click()
        app.buttons[decision + "-delete-" + id].click(); app.buttons["Delete"].click(); feedback(decision, contains: "Changes saved")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(id))
        XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("open-items.md"), encoding: .utf8).contains(issue))
    }
}
