import Foundation
import XCTest

final class SharedControlsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-controls-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_ROOT"] = root.path
    }

    override func tearDownWithError() throws {
        if testRun?.failureCount ?? 0 > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.lifetime = .keepAlways
            add(tree)
        }
        app.terminate()
        UserDefaults.standard.removePersistentDomain(forName: "works.stillmatter.controls.\(root.lastPathComponent)")
        try FileManager.default.removeItem(at: root)
    }

    func testReturnStartsCaptureLiveNoteUsesFocusAndStopFinalizesWithoutDevices() throws {
        launch()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        let stop = app.buttons["recording-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertFalse(app.popUpButtons["recording-language"].isEnabled)
        let note = app.textViews["recording-my-notes-editor"]
        note.click()
        note.typeText("Native shared-control note")
        expectation(for: NSPredicate(format: "value == %@", "✓ Saved"), evaluatedWith: app.staticTexts["recording-my-notes-status"])
        waitForExpectations(timeout: 10)
        let saved = try noteText()
        XCTAssertTrue(saved.contains("Native shared-control note"))
        stop.click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recording-stop"].exists)
        XCTAssertEqual(try noteText().components(separatedBy: "Native shared-control note").count - 1, 1)
        app.buttons["controls-nav-settings"].click()
        app.buttons["controls-nav-recording"].click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.windows["Shared Controls Test"].waitForExistence(timeout: 15), app.debugDescription)
    }

    private func noteText() throws -> String { try XCTUnwrap(noteTexts().first) }

    private func noteTexts() throws -> [String] {
        try notePaths().map { try String(contentsOf: $0) }
    }

    private func notePaths() throws -> [URL] {
        let workspace = root.appendingPathComponent("workspace")
        return try FileManager.default.subpathsOfDirectory(atPath: workspace.path)
            .filter { $0.hasSuffix("my-notes.md") }.map { workspace.appendingPathComponent($0) }
    }

}
