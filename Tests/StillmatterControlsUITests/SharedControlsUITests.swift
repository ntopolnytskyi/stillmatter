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
        let note = app.textFields["recording-note"]
        note.click()
        note.typeText("Native shared-control note")
        note.typeKey(.return, modifierFlags: [])
        expectation(for: NSPredicate(format: "value == %@", ""), evaluatedWith: note)
        waitForExpectations(timeout: 10)
        let saved = try meetingText()
        XCTAssertTrue(saved.contains("Native shared-control note"))
        stop.click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recording-stop"].exists)
        XCTAssertEqual(try meetingText().components(separatedBy: "Native shared-control note").count - 1, 1)
        app.buttons["controls-nav-settings"].click()
        app.buttons["controls-nav-recording"].click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
    }

    func testSettingsFieldPopupAndTogglePersistAfterRelaunch() throws {
        launch()
        app.buttons["controls-nav-settings"].click()
        let field = app.textFields["settings-search-exclusions"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Private/**, NativeControl/**")
        field.typeKey(.return, modifierFlags: [])
        let popup = app.popUpButtons["settings-teams-recording"]
        popup.click()
        app.menuItems["Manual only"].click()
        let toggle = app.checkBoxes["settings-launch-at-login"]
        let before = try XCTUnwrap(toggle.value as? NSNumber).boolValue
        toggle.click()
        XCTAssertEqual(try XCTUnwrap(toggle.value as? NSNumber).boolValue, !before)
        let changed = try effectiveSettings()
        XCTAssertEqual(changed["searchExcludedPatterns"] as? [String], ["Private/**", "NativeControl/**"])
        app.terminate()
        launch()
        app.buttons["controls-nav-settings"].click()
        XCTAssertEqual(app.textFields["settings-search-exclusions"].value as? String, "Private/**, NativeControl/**")
        XCTAssertEqual(app.popUpButtons["settings-teams-recording"].value as? String, "Manual only")
        XCTAssertEqual(try effectiveSettings()["launchAtLoginEnabled"] as? Bool, changed["launchAtLoginEnabled"] as? Bool)
    }

    func testUnavailableCaptureIgnoresReturnAndLeavesWorkspaceUntouched() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "unconfigured"
        launch()
        XCTAssertTrue(app.staticTexts["Capture unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["recording-start"].exists)
        XCTAssertFalse(app.popUpButtons["recording-language"].isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Capture unavailable"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace/Meetings").path))
    }

    func testFocusedRetryReportsValidationFailureWithoutChangingSavedSettings() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "invalid-setting"
        launch()
        let retry = app.buttons["settings-retry-workspace"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        let before = NSDictionary(dictionary: try effectiveSettings())
        // The fixture gives Retry initial keyboard focus. Space must activate the
        // real button and preserve that focus after validation fails.
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Controlled validation failure 1")).firstMatch.waitForExistence(timeout: 10))
        app.typeKey(.space, modifierFlags: [])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Controlled validation failure 2")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(NSDictionary(dictionary: try effectiveSettings()), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rejected-destination").path))
        app.buttons["settings-cancel-workspace"].click()
        XCTAssertFalse(retry.exists)
        XCTAssertEqual(NSDictionary(dictionary: try effectiveSettings()), before)
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(app.windows["Shared Controls Test"].waitForExistence(timeout: 15), app.debugDescription)
    }

    private func meetingText() throws -> String {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("workspace").path)
        let path = try XCTUnwrap(files.first(where: { $0.hasSuffix("meeting.md") }))
        return try String(contentsOf: root.appendingPathComponent("workspace").appendingPathComponent(path))
    }

    private func effectiveSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("effective-settings.json"))) as? [String: Any])
    }
}
