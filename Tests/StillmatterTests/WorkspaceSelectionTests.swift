import Foundation
import XCTest
@testable import StillmatterCore

final class WorkspaceSelectionTests: XCTestCase {
    func testRuntimeValidatesBeforeSwitchAndRejectsOldGenerationAfterSwitchOrStop() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceSelection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Old")
        let next = base.appendingPathComponent("Next")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let runtime = WorkspaceRuntime()
        var settings = AppSettings(stillmatterRootURL: old)
        XCTAssertTrue(runtime.activate(settings))
        let generation = runtime.generation
        let identity = try XCTUnwrap(runtime.identity)
        XCTAssertThrowsError(try runtime.validate(.init(root: next, media: nil)))
        XCTAssertTrue(runtime.isCurrent(identity: identity, generation: generation))
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        try runtime.validate(.init(root: next, media: nil))
        settings.stillmatterRootURL = next
        XCTAssertTrue(runtime.activate(settings))
        XCTAssertFalse(runtime.isCurrent(identity: identity, generation: generation))
        XCTAssertFalse(runtime.activate(settings))
        runtime.stop()
        XCTAssertFalse(runtime.isCurrent(identity: runtime.identity, generation: runtime.generation))
        XCTAssertFalse(runtime.activate(AppSettings(stillmatterRootURL: old)))
    }

    func testEffectiveSelectionIsPreparedBeforePublicationAndFailedPreparationRetainsPending() throws {
        let name = "WorkspacePreparationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(userDefaults: defaults)
        let old = URL(fileURLWithPath: "/temporary/old")
        let next = URL(fileURLWithPath: "/temporary/next")
        store.settings.stillmatterRootURL = old
        var prepared = false
        store.onWorkspaceWillChange = { requested in
            XCTAssertEqual(store.settings.stillmatterRootURL, old)
            XCTAssertEqual(requested.stillmatterRootURL, next)
            prepared = true
        }
        let observer = store.observeScoped { settings in
            if settings.stillmatterRootURL == next { XCTAssertTrue(prepared) }
        }
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertTrue(store.applyPendingWorkspace { _ in })
        XCTAssertEqual(store.settings.stillmatterRootURL, next)
        store.removeObserver(observer)
        store.onWorkspaceWillChange = { _ in throw CocoaError(.fileNoSuchFile) }
        store.settings.stillmatterRootURL = old
        XCTAssertEqual(store.settings.stillmatterRootURL, next)
        XCTAssertEqual(store.pendingWorkspace?.root, old)
        XCTAssertNotNil(store.pendingWorkspaceError)
    }

    func testFailedPreparationDuringPendingHandoffDoesNotClaimSuccessOrPersistDestination() throws {
        let name = "WorkspacePreparationFailure-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(userDefaults: defaults)
        let old = URL(fileURLWithPath: "/temporary/old")
        let next = URL(fileURLWithPath: "/temporary/next")
        store.settings.stillmatterRootURL = old
        store.onWorkspaceWillChange = { _ in throw CocoaError(.fileNoSuchFile) }
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertFalse(store.applyPendingWorkspace { _ in })
        XCTAssertEqual(store.settings.stillmatterRootURL, old)
        XCTAssertEqual(store.pendingWorkspace?.root, next)
        XCTAssertNotNil(store.pendingWorkspaceError)
        XCTAssertEqual(SettingsStore(userDefaults: defaults).settings.stillmatterRootURL, old)
    }

    func testCapturePinsEffectiveWorkspaceUntilOldJobHandoffIsPersisted() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceCapture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Old")
        let next = base.appendingPathComponent("Next")
        let support = base.appendingPathComponent("Support")
        for path in [old, next, support] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkspaceCapture-\(UUID())"))
        let store = SettingsStore(userDefaults: defaults)
        store.settings.stillmatterRootURL = old
        let jobs = try JobStore(databaseURL: support.appendingPathComponent("operational.sqlite"))
        let vault = WorkspaceVault(workspaceRootURL: old, appSupportRootURL: support)
        let capture = MeetingCaptureService(vault: vault, jobStore: jobs, preflight: { .readyForTesting })
        var stateAtIdle: SettingsStore.WorkspaceSelection?
        capture.observe { snapshot in
            store.workspaceChangeHeld = [.starting, .recording, .stopping, .finalizing, .failed, .recovered].contains(snapshot.state)
            if snapshot.state == .idle && snapshot.meetingRelativePath != nil {
                stateAtIdle = store.workspaceSelection
                let pendingJob = try? jobs.jobs().first { $0.manifest.metadata["capture_session_id"] != nil }
                XCTAssertEqual(pendingJob?.manifest.workspaceOwner, old.standardizedFileURL.resolvingSymlinksInPath().path)
            }
        }
        _ = try capture.startManual()
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertEqual(store.settings.stillmatterRootURL, old)
        XCTAssertFalse(store.applyPendingWorkspace { _ in XCTFail("Must stay pinned during recording") })
        _ = try capture.stopManual()
        XCTAssertEqual(stateAtIdle?.root, old, "No observer may see the new workspace before the Job handoff")
        XCTAssertTrue(store.applyPendingWorkspace { selection in try WorkspaceRuntime().validate(selection) })
        XCTAssertEqual(store.settings.stillmatterRootURL, next)
        XCTAssertEqual(try jobs.jobs().first?.manifest.workspaceOwner, old.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testPendingSelectionIsMemoryOnlyAndOtherSettingsRemainEffective() throws {
        let name = "WorkspaceSelectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(userDefaults: defaults)
        let old = URL(fileURLWithPath: "/temporary/old")
        let next = URL(fileURLWithPath: "/temporary/new")
        store.settings.stillmatterRootURL = old
        store.workspaceChangeHeld = true
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertEqual(store.settings.stillmatterRootURL, old)
        XCTAssertEqual(store.pendingWorkspace?.root, next)
        store.settings.launchAtLoginEnabled = true
        XCTAssertEqual(store.pendingWorkspace?.root, next)
        XCTAssertTrue(store.settings.launchAtLoginEnabled)
        XCTAssertEqual(SettingsStore(userDefaults: defaults).settings.stillmatterRootURL, old)
        XCTAssertNil(SettingsStore(userDefaults: defaults).pendingWorkspace)

        store.cancelPendingWorkspace()
        XCTAssertNil(store.pendingWorkspace)
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertEqual(store.pendingWorkspace?.root, next)
        store.workspaceChangeHeld = false
        XCTAssertTrue(store.applyPendingWorkspace { _ in })
        XCTAssertNil(store.pendingWorkspace)
        XCTAssertEqual(store.settings.stillmatterRootURL, next)
    }

    func testFailedValidationRetainsEffectiveAndPendingAndCanReplaceOrRetry() throws {
        let name = "WorkspaceSelectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(userDefaults: defaults)
        let old = URL(fileURLWithPath: "/temporary/old")
        let bad = URL(fileURLWithPath: "/temporary/missing")
        let next = URL(fileURLWithPath: "/temporary/new")
        store.settings.stillmatterRootURL = old
        store.workspaceChangeHeld = true
        store.requestWorkspace(.init(root: bad, media: nil))
        XCTAssertFalse(store.applyPendingWorkspace { _ in XCTFail("Must not validate during capture") })
        store.workspaceChangeHeld = false
        XCTAssertFalse(store.applyPendingWorkspace { _ in throw CocoaError(.fileNoSuchFile) })
        XCTAssertEqual(store.settings.stillmatterRootURL, old)
        XCTAssertEqual(store.pendingWorkspace?.root, bad)
        XCTAssertNotNil(store.pendingWorkspaceError)
        store.workspaceChangeHeld = true
        store.requestWorkspace(.init(root: next, media: nil))
        XCTAssertNil(store.pendingWorkspaceError)
        store.workspaceChangeHeld = false
        XCTAssertTrue(store.applyPendingWorkspace { selection in XCTAssertEqual(selection.root, next) })
        XCTAssertEqual(store.settings.stillmatterRootURL, next)
    }
}
