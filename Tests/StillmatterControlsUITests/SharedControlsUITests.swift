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

    func testManualSourceShowsActualScopeAndPersistsMeetWithoutChangingMicrophone() throws {
        launch()
        let source = app.popUpButtons["recording-source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        let scope = app.staticTexts["recording-audio-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("Teams application audio only"), scope.debugDescription)
        source.click()
        app.menuItems["Zoom"].click()
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("ALL SYSTEM AUDIO"), scope.debugDescription)
        source.click()
        app.menuItems["Google Meet"].click()
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("not Zoom-only or Meet-tab-only"), scope.debugDescription)
        app.buttons["recording-start"].click()
        XCTAssertFalse(source.isEnabled)
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("Recording ALL SYSTEM AUDIO"), scope.debugDescription)
        let markdown = try meetingText()
        XCTAssertTrue(markdown.contains("meeting_source: meet"))
        XCTAssertTrue(markdown.contains("audio_scope: allSystemAudio"))
        app.buttons["recording-stop"].click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
    }

    func testRuntimeSourceLossShowsPersistentMicrophoneOnlyWarningAndRetainsScope() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "source-loss"
        launch()
        let start = app.buttons["recording-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        let stop = app.buttons["recording-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        let scope = app.staticTexts["recording-audio-scope"]
        app.buttons["recording-test-source-loss"].click()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "microphone capture continues"), evaluatedWith: scope)
        waitForExpectations(timeout: 10)
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("Teams application audio only"), scope.debugDescription)
        XCTAssertTrue((scope.value as? String ?? scope.label).contains("synthetic source disconnected"), scope.debugDescription)
        XCTAssertTrue(stop.isEnabled, "Source loss leaves Stop available for the active microphone track")
        stop.click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue(try meetingText().contains("audio_scope: teamsApplication"))
    }

    func testNextCaptureStartsBeforePriorSessionFinalizationAndKeepsNotesOwned() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "overlap"
        launch()
        let start = app.buttons["recording-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        let note = app.textFields["recording-note"]
        note.click()
        note.typeText("Session A note")
        note.typeKey(.return, modifierFlags: [])
        let stop = app.buttons["recording-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.click()

        XCTAssertTrue(start.waitForExistence(timeout: 10), "Record must re-enable as soon as A's source stops")
        XCTAssertTrue(app.staticTexts["capture-state"].label.contains("Ready for the next capture"))
        let idleDetail = app.staticTexts["capture-state-detail"]
        XCTAssertTrue(idleDetail.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((idleDetail.value as? String ?? "").contains("prior audio source has stopped"), idleDetail.debugDescription)

        start.click()
        XCTAssertTrue(app.buttons["recording-stop"].waitForExistence(timeout: 10))
        let priorStatus = app.staticTexts["capture-state-detail"]
        XCTAssertTrue((priorStatus.value as? String ?? "").contains("prior Meeting's audio is finalizing separately"), "A's status remains visible while B records")
        note.click()
        note.typeText("Session B note")
        note.typeKey(.return, modifierFlags: [])
        app.buttons["recording-test-release-prior-finalization"].click()
        expectation(for: NSPredicate { _, _ in
            !(priorStatus.value as? String ?? "").contains("prior Meeting's audio is finalizing separately")
        }, evaluatedWith: priorStatus)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["recording-stop"].isEnabled, "A's late completion cannot replace B's controls")
        app.buttons["recording-stop"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        let notes = try meetingTexts()
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.contains("Session A note") && !$0.contains("Session B note") })
        XCTAssertTrue(notes.contains { $0.contains("Session B note") && !$0.contains("Session A note") })
    }

    func testPriorFinalizationFailureStaysVisibleWhileNextCaptureCanStart() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "overlap-failure"
        launch()
        let start = app.buttons["recording-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        app.buttons["recording-stop"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertTrue((app.staticTexts["capture-state-detail"].value as? String ?? "").contains("prior audio source has stopped"))

        start.click()
        XCTAssertTrue(app.buttons["recording-stop"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.staticTexts["capture-state-detail"].value as? String ?? "").contains("prior Meeting's audio is finalizing separately"))

        let artifactsDisclosure = app.checkBoxes["recording-artifacts"]
        for _ in 0..<4 where !artifactsDisclosure.exists {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(artifactsDisclosure.exists, app.debugDescription)
        artifactsDisclosure.click()
        app.buttons["recording-test-release-prior-finalization"].click()
        let priorRow = app.staticTexts["recording-prior-finalization-failure"]
        let stateDetail = app.staticTexts["capture-state-detail"]
        expectation(for: NSPredicate(format: "value CONTAINS %@", "prior Meeting's audio finalization failed"), evaluatedWith: stateDetail)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(priorRow.exists, app.debugDescription)
        XCTAssertEqual(priorRow.label, "Prior Meeting — Finalization failed")
        XCTAssertTrue(app.buttons["recording-stop"].isEnabled)
        XCTAssertFalse(app.staticTexts["capture-error"].exists, "A's late failure must not be reported as B's capture failure")
    }

    func testPriorFinalizationFailureDoesNotReplaceCurrentCaptureReleaseFailure() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "overlap-failure-current-session-failure"
        launch()
        let start = app.buttons["recording-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        app.buttons["recording-stop"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        start.click()
        app.buttons["recording-stop"].click()
        let state = app.staticTexts["capture-state"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "Capture failed"), evaluatedWith: state)
        waitForExpectations(timeout: 10)
        let captureError = app.staticTexts["capture-error"]
        let currentCaptureFailure = captureError.value as? String ?? ""
        XCTAssertFalse(currentCaptureFailure.isEmpty)

        let artifactsDisclosure = app.checkBoxes["recording-artifacts"]
        for _ in 0..<4 where !artifactsDisclosure.exists {
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(artifactsDisclosure.exists, app.debugDescription)
        artifactsDisclosure.click()
        app.buttons["recording-test-release-prior-finalization"].click()
        let priorRow = app.staticTexts["recording-prior-finalization-failure"]
        XCTAssertTrue(priorRow.waitForExistence(timeout: 10))
        XCTAssertEqual(captureError.value as? String, currentCaptureFailure)
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

    func testTeamsAutomationShowsAccessibilitySetupAndRunsItsPermissionAction() throws {
        app.launchEnvironment["STILLMATTER_CONTROLS_UI_TEST_SCENARIO"] = "teams-permission"
        launch()
        app.buttons["controls-nav-settings"].click()
        let status = app.staticTexts["settings-status-teamsAccessibility"]
        let request = app.buttons["settings-diagnostic-teamsAccessibility"]
        XCTAssertTrue(request.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue((status.value as? String ?? status.label).contains("Missing"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "automatic Teams recording")).firstMatch.exists)
        app.popUpButtons["settings-teams-recording"].click()
        app.menuItems["Record automatically"].click()
        XCTAssertEqual(try effectiveSettings()["teamsRecordingMode"] as? String, "automatic")
        request.click()
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue((status.value as? String ?? status.label).contains("Granted"))
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
        try XCTUnwrap(meetingTexts().first)
    }

    private func meetingTexts() throws -> [String] {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("workspace").path)
        return try files.filter { $0.hasSuffix("meeting.md") }.map {
            try String(contentsOf: root.appendingPathComponent("workspace").appendingPathComponent($0))
        }
    }

    private func effectiveSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("effective-settings.json"))) as? [String: Any])
    }
}
