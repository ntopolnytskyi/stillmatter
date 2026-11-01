import AppKit
import XCTest
import StillmatterCore

final class WorkflowControlsUITests: XCTestCase {
    private var root: URL!
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workflow-ui-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_ROOT"] = root.path
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "workflow"
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
        XCTAssertTrue(app.buttons["Start Capture"].isEnabled)
        XCTAssertFalse(app.staticTexts["Stale generated content must remain hidden"].exists)
        app.terminate()
        let store = try JobStore(databaseURL: root.appendingPathComponent("support/jobs.sqlite"))
        XCTAssertEqual(try store.job(id: "A")?.status, .failed)
        XCTAssertEqual(try store.job(id: "A")?.stages.first?.attemptCount, 2)
    }

    func testActualStageAdvancesWhileRecordingStartsAndPersistsAcrossRelaunch() throws {
        let a = app.tables["Meetings"].staticTexts["Workflow A"].firstMatch
        XCTAssertTrue(a.waitForExistence(timeout: 10)); a.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Transcribe A")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Stale generated content must remain hidden"].exists)
        XCTAssertFalse(app.staticTexts["Hidden while processing"].exists)
        app.buttons["workflow-advance-stage"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize meeting and extract cited outcomes")).firstMatch.waitForExistence(timeout: 10))
        let start = app.buttons["Start Capture"], stop = app.buttons["Stop Capture"]
        XCTAssertTrue(start.isEnabled); XCTAssertFalse(stop.isEnabled)
        start.click()
        XCTAssertTrue(app.staticTexts["capture-state"].waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isEnabled); XCTAssertFalse(start.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Summarize meeting and extract cited outcomes")).firstMatch.exists)
        stop.click()
        XCTAssertTrue(start.isEnabled)
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
        app.terminate()
        let store = try JobStore(databaseURL: root.appendingPathComponent("support/jobs.sqlite"))
        XCTAssertEqual(try store.job(id: "A")?.status, .succeeded)
        XCTAssertEqual(try store.job(id: "A")?.stages.first?.attemptCount, 1)
        XCTAssertEqual(try store.job(id: "A")?.stages.last?.attemptCount, 2)
    }
}
