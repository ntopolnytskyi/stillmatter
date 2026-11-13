import AppKit
import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testTranscriptLinkedItemsTailCitationUserNoteConflictAndRelaunch() throws {
        try seedMeeting(transcript: true)
        openFixtureMeeting()
        app.radioButtons["Transcript"].click()
        let search = app.searchFields["meeting-transcript-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.click(); search.typeText("moment 119")
        let phrase = app.staticTexts["transcript-text-s119"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 5), app.debugDescription)
        func action(_ title: String) {
            let menu = app.menuButtons["transcript-actions-s119"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.click()
            app.menuItems[title].click()
        }
        let directory = meetingURL.deletingLastPathComponent()
        func saveText(_ text: String) {
            let editor = app.textViews["meeting-text-editor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.click()
            editor.typeKey("a", modifierFlags: .command); editor.typeText(text)
            editor.typeKey(.return, modifierFlags: .command)
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
            waitForExpectations(timeout: 10)
        }
        action("Copy text")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Synthetic searchable moment 119")
        action("Copy with timestamp")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Me 03:58:00 Synthetic searchable moment 119")
        action("Copy speaker")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Me")
        action("Add Action Item…"); saveText("Send final report")
        let actionsURL = directory.appendingPathComponent("action-items.md")
        XCTAssertTrue(try String(contentsOf: actionsURL, encoding: .utf8).contains("Send final report"))
        action("Add Decision…"); saveText("Ship on Friday")
        action("Add note…")
        let editor = app.textViews["meeting-text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.click()
        editor.typeKey("a", modifierFlags: .command); editor.typeText("My explicit note")
        let notesURL = directory.appendingPathComponent("my-notes.md")
        try String(contentsOf: notesURL, encoding: .utf8).appending("\nExternal note").write(to: notesURL, atomically: true, encoding: .utf8)
        editor.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["meeting-text-error"].waitForExistence(timeout: 10))
        XCTAssertEqual(editor.value as? String, "My explicit note")
        XCTAssertTrue(try String(contentsOf: notesURL, encoding: .utf8).contains("External note"))
        editor.typeKey(.escape, modifierFlags: [])
        action("Add note…"); saveText("My explicit note")
        XCTAssertTrue(try String(contentsOf: notesURL, encoding: .utf8).contains("My explicit note"))
        XCTAssertTrue(try String(contentsOf: notesURL, encoding: .utf8).contains("sm-source:"))
        app.radioButtons["Summary"].click()
        let decisionsURL = directory.appendingPathComponent("decisions.md")
        let data = try String(contentsOf: decisionsURL, encoding: .utf8)
        let line = try XCTUnwrap(data.components(separatedBy: "\n").first { $0.contains("Ship on Friday") })
        let start = try XCTUnwrap(line.range(of: "<!-- sm-item:"))
        let end = try XCTUnwrap(line.range(of: " -->", range: start.upperBound..<line.endIndex))
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line[start.upperBound..<end.lowerBound].utf8)) as? [String: Any])
        let id = try XCTUnwrap(metadata["id"] as? String)
        let source = app.buttons["meeting-outcome-source-" + id + "-0"]
        XCTAssertTrue(source.waitForExistence(timeout: 5)); source.click()
        XCTAssertEqual(app.radioButtons["Transcript"].value as? Int, 1)
        XCTAssertTrue(phrase.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "")
        XCTAssertFalse(app.buttons["transcript-time-s119"].isEnabled)
        XCTAssertTrue(app.staticTexts["meeting-playback-legend"].exists)
        relaunch(); openFixtureMeeting()
        XCTAssertTrue(app.staticTexts["meeting-decisions-row-" + id].waitForExistence(timeout: 10))
        XCTAssertTrue(try String(contentsOf: notesURL, encoding: .utf8).contains("My explicit note"))
        // A retained outcome must not fabricate a usable source after Transcript removal.
        app.terminate()
        for name in ["transcript.json", "transcript.txt", "transcript.md"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        relaunch(); openFixtureMeeting()
        XCTAssertTrue(source.waitForExistence(timeout: 10)); XCTAssertFalse(source.isEnabled)
        XCTAssertEqual(source.title, "Source no longer retained")
    }
}
