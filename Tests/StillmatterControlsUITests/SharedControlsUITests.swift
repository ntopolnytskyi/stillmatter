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

    func testLiveNotesConflictPreservesDraftAndReloadsExternalFile() throws {
        launch()
        app.buttons["recording-start"].click()
        let editor = app.textViews["recording-my-notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Initial")
        editor.typeKey("s", modifierFlags: .command)
        let status = app.staticTexts["recording-my-notes-status"]
        expectation(for: NSPredicate(format: "value == %@", "✓ Saved"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        let path = try XCTUnwrap(notePaths().first)
        editor.typeText(" local draft")
        try "External edit".write(to: path, atomically: true, encoding: .utf8)
        app.buttons["recording-save-notes"].click()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Conflict"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(try String(contentsOf: path), "External edit")
        XCTAssertTrue((editor.value as? String ?? "").contains("local draft"))
        let useDraft = app.buttons["recording-use-notes-draft"]
        XCTAssertTrue(useDraft.isEnabled)
        useDraft.click()
        XCTAssertEqual(try String(contentsOf: path), "Initial local draft")
        let preserved = root.appendingPathComponent("support/MeetingArtifacts/LiveNotes/Preserved")
        let copies = try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try String(contentsOf: copies[0]), "External edit")
        editor.click()
        editor.typeText(" second draft")
        try "External second".write(to: path, atomically: true, encoding: .utf8)
        editor.typeKey(.escape, modifierFlags: [])
        let discard = app.buttons["recording-confirm-destructive"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["recording-confirm-cancel"].click()
        XCTAssertTrue((editor.value as? String ?? "").contains("second draft"))
        editor.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.click()
        XCTAssertEqual(editor.value as? String, "External second")
        XCTAssertEqual(try String(contentsOf: path), "External second")
        app.buttons["recording-stop"].click()
    }

    func testLiveNotesSurviveNavigationAndSyntheticAppInterruption() throws {
        launch()
        app.buttons["recording-start"].click()
        let editor = app.textViews["recording-my-notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Typed during capture")
        app.buttons["controls-nav-settings"].click()
        app.buttons["controls-nav-recording"].click()
        XCTAssertEqual(editor.value as? String, "Typed during capture")
        editor.click()
        editor.typeText(" before interruption")
        app.terminate()
        launch()
        let recovered = expectation(for: NSPredicate { _, _ in
            (try? self.noteText()) == "Typed during capture before interruption"
        }, evaluatedWith: app)
        wait(for: [recovered], timeout: 10)
        XCTAssertFalse(app.textViews["recording-my-notes-editor"].isHittable)
    }

    func testStopAnywayKeepsConflictForRecoveryAfterRelaunch() throws {
        launch()
        app.buttons["recording-start"].click()
        let editor = app.textViews["recording-my-notes-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("Original")
        editor.typeKey("s", modifierFlags: .command)
        expectation(for: NSPredicate(format: "value == %@", "✓ Saved"), evaluatedWith: app.staticTexts["recording-my-notes-status"])
        waitForExpectations(timeout: 10)
        let notes = try XCTUnwrap(notePaths().first)
        editor.typeText(" draft")
        try "External".write(to: notes, atomically: true, encoding: .utf8)
        editor.typeText(" after external")
        app.buttons["recording-save-notes"].click()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Conflict"), evaluatedWith: app.staticTexts["recording-my-notes-status"])
        waitForExpectations(timeout: 10)
        app.buttons["recording-stop"].click()
        let stopAnyway = app.buttons["recording-stop-anyway"]
        XCTAssertTrue(stopAnyway.waitForExistence(timeout: 5))
        stopAnyway.click()
        let confirmation = app.buttons["recording-confirm-destructive"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["recording-confirm-cancel"].click()
        XCTAssertTrue(app.buttons["recording-stop"].exists)
        stopAnyway.click()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.click()
        XCTAssertTrue(app.buttons["recording-start"].waitForExistence(timeout: 10))
        XCTAssertEqual(try String(contentsOf: notes), "External")

        app.terminate()
        launch()
        let recoveredEditor = app.textViews["recording-my-notes-editor"]
        XCTAssertTrue(recoveredEditor.waitForExistence(timeout: 10))
        XCTAssertEqual(recoveredEditor.value as? String, "Original draft after external")
        app.buttons["recording-use-notes-draft"].click()
        XCTAssertEqual(try String(contentsOf: notes), "Original draft after external")
        let preserved = root.appendingPathComponent("support/MeetingArtifacts/LiveNotes/Preserved")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: preserved, includingPropertiesForKeys: nil).count, 1)
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
        let note = app.textViews["recording-my-notes-editor"]
        note.click()
        note.typeText("Session A note")
        app.buttons["recording-save-notes"].click()
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
        app.buttons["recording-save-notes"].click()
        app.buttons["recording-test-release-prior-finalization"].click()
        expectation(for: NSPredicate { _, _ in
            !(priorStatus.value as? String ?? "").contains("prior Meeting's audio is finalizing separately")
        }, evaluatedWith: priorStatus)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["recording-stop"].isEnabled, "A's late completion cannot replace B's controls")
        app.buttons["recording-stop"].click()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

        let notes = try noteTexts()
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

    private func noteText() throws -> String { try XCTUnwrap(noteTexts().first) }

    private func noteTexts() throws -> [String] {
        try notePaths().map { try String(contentsOf: $0) }
    }

    private func notePaths() throws -> [URL] {
        let workspace = root.appendingPathComponent("workspace")
        return try FileManager.default.subpathsOfDirectory(atPath: workspace.path)
            .filter { $0.hasSuffix("my-notes.md") }.map { workspace.appendingPathComponent($0) }
    }

    private func effectiveSettings() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("effective-settings.json"))) as? [String: Any])
    }
}
