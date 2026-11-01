import AppKit
import XCTest

final class WorkflowControlsUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["STILLMATTER_WORKFLOW_UI_TEST_ROOT"] = root.path
        app.launch()
        XCTAssertTrue(app.windows["Workflow Native Tests"].waitForExistence(timeout: 15))
    }
    override func tearDownWithError() throws {
        app?.terminate()
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func testFailedStageExplainsErrorWhileCaptureRemainsAvailable() throws {
        let a = app.tables["Meetings"].staticTexts["Workflow A"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10)); a.click()
        app.buttons["workflow-fail-stage"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Synthetic controlled stage failed")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recording-start"].isEnabled)
        XCTAssertFalse(app.staticTexts["Stale generated content must remain hidden"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Transcribe B")).firstMatch.waitForExistence(timeout: 10),
                      "The queue must advance after A exhausts its bounded stage attempts")
    }

    func testActualStageAdvancesWhileCaptureRemainsAvailableAndPersistsAcrossRelaunch() throws {
        let a = app.tables["Meetings"].staticTexts["Workflow A"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10)); a.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Transcribe A")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Stale generated content must remain hidden"].exists)
        XCTAssertFalse(app.staticTexts["Hidden while processing"].exists)
        app.buttons["workflow-advance-stage"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize meeting and extract cited outcomes")).firstMatch.waitForExistence(timeout: 10))
        let start = app.buttons["recording-start"], stop = app.buttons["recording-stop"]
        XCTAssertTrue(start.isEnabled, "Capture must remain available while a Meeting stage is pending")
        XCTAssertFalse(stop.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize meeting and extract cited outcomes")).firstMatch.exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.windows["Workflow Native Tests"].waitForExistence(timeout: 15))
        let reopened = app.tables["Meetings"].staticTexts["Workflow A"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 10)); reopened.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize meeting and extract cited outcomes")).firstMatch.waitForExistence(timeout: 10))
        // The harness's keyboard step command drives the same real stage callback.
        app.typeKey("n", modifierFlags: [.command])
        let b = app.tables["Meetings"].staticTexts["Workflow B"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 10)); b.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Transcribe B")).firstMatch.waitForExistence(timeout: 10))
    }
}
