import Foundation
import XCTest

extension StillmatterFlowsUITests {
    func testSearchArchiveOptInOpensRetainedNotesAndResetsAfterRelaunch() throws {
        try seedMeeting(transcript: true)
        app.terminate()
        let directory = meetingURL.deletingLastPathComponent()
        let notes = "# My Notes\n\nArchiveSearchNeedle retained notes.\n"
        try notes.write(to: directory.appendingPathComponent("my-notes.md"), atomically: true, encoding: .utf8)
        try "{\"archived\":true}".write(to: directory.appendingPathComponent("archive.json"), atomically: true, encoding: .utf8)
        relaunch()
        app.buttons["sidebar-meetings"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        search.typeText("ArchiveSearchNeedle")
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15))
        let archived = app.checkBoxes["global-search-archived"]
        XCTAssertTrue(archived.exists)
        XCTAssertEqual(archived.value as? Int, 0)
        app.menuBars.menuBarItems["Navigate"].click()
        app.menuItems["Include Archived in Search"].click()
        XCTAssertEqual(archived.value as? Int, 1)
        archived.click()
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 10))
        archived.click()
        let results = app.tables["Search results"]
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["search-semantic-status"].exists)
        search.click(); search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["meeting-detail"].waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "value == %@", "UI fixture meeting"), evaluatedWith: app.staticTexts["meeting-detail"])
        waitForExpectations(timeout: 10)
        let notesTab = app.radioButtons["My Notes"]
        XCTAssertTrue(notesTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(notesTab.value as? Int, 1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "ArchiveSearchNeedle retained notes")).firstMatch.exists)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("my-notes.md")), notes)
        relaunch()
        XCTAssertEqual(app.checkBoxes["global-search-archived"].value as? Int, 0, "Archives require an explicit opt-in each session")
    }

    func testSearchExternalEditAndRemovalRefreshVisibleResultsWithoutChangingQuery() throws {
        try seedMeeting()
        let summary = meetingURL.deletingLastPathComponent().appendingPathComponent("summary.md")
        try "# Summary\n\nFreshSearchNeedle original.\n".write(to: summary, atomically: true, encoding: .utf8)
        app.buttons["sidebar-meetings"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        search.typeText("FreshSearchNeedle")
        let results = app.tables["Search results"]
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 15))
        try "# Summary\n\nReplacement content.\n".write(to: summary, atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15))
        XCTAssertEqual(search.value as? String, "FreshSearchNeedle")
        try "# Summary\n\nFreshSearchNeedle regenerated.\n".write(to: summary, atomically: true, encoding: .utf8)
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 15))
        try FileManager.default.removeItem(at: summary)
        XCTAssertTrue(app.staticTexts["No results"].waitForExistence(timeout: 15))
        let status = app.staticTexts["search-semantic-status"]
        XCTAssertTrue((status.value as? String)?.contains("Keyword results only") == true)
        XCTAssertEqual(search.value as? String, "FreshSearchNeedle")
    }

    func testSearchTranscriptResultLocatesLateSourceAndKeepsGlobalQuery() throws {
        try seedMeeting(transcript: true)
        app.buttons["sidebar-meetings"].click()
        app.typeKey("f", modifierFlags: .command)
        let search = app.searchFields["Search"]
        search.typeText("Synthetic searchable moment 119")
        let results = app.tables["Search results"]
        XCTAssertTrue(results.tableRows.firstMatch.waitForExistence(timeout: 15))
        search.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let transcriptTab = app.radioButtons["Transcript"]
        XCTAssertTrue(transcriptTab.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(transcriptTab.value as? Int, 1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "Synthetic searchable moment 119")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(search.value as? String, "Synthetic searchable moment 119")
    }
}
