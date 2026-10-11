import Foundation
import XCTest

/// UI seams verified against the isolated native app: icon-rail navigation and Ask AI scope.
final class StillmatterFlowsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-ui-\(UUID().uuidString)", isDirectory: true)
        let workspace = fixtureRoot.appendingPathComponent("workspace", isDirectory: true)
        let support = fixtureRoot.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        // Address the disposable bundle by URL, never Launch Services' installed app lookup.
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let testApp = repository.appendingPathComponent(".build/ui-tests/StillmatterUITests.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: testApp.path), "Build the isolated app with scripts/test-ui-flows.sh")
        app = XCUIApplication(url: testApp)
        app.launchEnvironment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] = workspace.path
        app.launchEnvironment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] = support.path
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixtureRoot { try FileManager.default.removeItem(at: fixtureRoot) }
    }

    func testEmptyQueueIsVisibleFromTasks() {
        app.buttons["sidebar-tasks"].click()
        XCTAssertTrue(app.staticTexts["No Queue Todo Items"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Tasks")
    }

    func testAskScopeIsOptInAndCanBeReverted() {
        app.buttons["sidebar-ask-ai"].click()
        let checkbox = app.checkBoxes["contextual-ask-broader-vault"]
        XCTAssertTrue(checkbox.waitForExistence(timeout: 10))
        XCTAssertEqual(checkbox.value as? String, "Selected context only")
        checkbox.click()
        XCTAssertEqual(checkbox.value as? String, "Broader vault included")
        checkbox.click()
        XCTAssertEqual(checkbox.value as? String, "Selected context only")
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Ask AI")
    }

    func testAboutIconRequiresDoubleClickAndShowsVersionAndCreator() {
        let about = app.buttons["sidebar-about"]
        XCTAssertTrue(about.waitForExistence(timeout: 10))
        about.click()
        XCTAssertFalse(app.dialogs.staticTexts["Version 0.1.0 (1)"].exists)
        about.doubleClick()
        let panel = app.dialogs.containing(.staticText, identifier: "Version 0.1.0 (1)").firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        XCTAssertTrue(panel.staticTexts.matching(NSPredicate(format: "value CONTAINS[c] %@", "Nazar Topolnytskyi")).firstMatch.exists)
    }

    func testSettingsIsReachableWithoutChangingSettings() {
        app.buttons["sidebar-settings"].click()
        XCTAssertTrue(app.buttons["Test Mic"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["Current area"].value as? String, "Settings")
    }
}
