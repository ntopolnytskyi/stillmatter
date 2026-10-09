import XCTest
@testable import StillmatterCore

final class CaptureSessionRuntimeTests: XCTestCase {
    func testConfigurationIsStableAndOnlyCapturePathsTriggerReplacement() throws {
        let fixture = try RuntimeFixture()
        var built: [MeetingCaptureService] = []
        var snapshots: [CaptureState] = []
        let runtime = CaptureSessionRuntime(build: { _ in
            let service = fixture.makeService()
            built.append(service)
            return service
        }, onSnapshot: { snapshots.append($0.state) })
        var settings = AppSettings(stillmatterRootURL: fixture.workspaceRoot)
        XCTAssertTrue(runtime.configure(settings))
        XCTAssertEqual(built.count, 1)
        XCTAssertTrue(snapshots.isEmpty, "Initial observer callback is suppressed until installation")
        XCTAssertFalse(runtime.configure(settings))
        settings.launchAtLoginEnabled = true
        XCTAssertFalse(runtime.configure(settings), "Unrelated settings must not rebuild capture")
        settings.recordingMediaURL = fixture.root.appendingPathComponent("Media")
        XCTAssertTrue(runtime.configure(settings))
        XCTAssertEqual(built.count, 2)
        XCTAssertTrue(runtime.service === built[1])

        // The old session must never forward a late event after replacement.
        _ = try built[0].startManual()
        XCTAssertTrue(snapshots.isEmpty)
        _ = try built[1].startManual()
        XCTAssertEqual(snapshots.last, .recording)
    }

    func testActiveSessionProtectsConfigurationUntilIdle() throws {
        let fixture = try RuntimeFixture()
        var builds = 0
        let runtime = CaptureSessionRuntime(build: { _ in
            builds += 1
            return fixture.makeService()
        }, onSnapshot: { _ in })
        let original = AppSettings(stillmatterRootURL: fixture.workspaceRoot)
        XCTAssertTrue(runtime.configure(original))
        let service = try XCTUnwrap(runtime.service)
        _ = try service.startManual()
        var changed = original
        changed.recordingMediaURL = fixture.root.appendingPathComponent("NewMedia")
        XCTAssertFalse(runtime.configure(changed))
        var movedRoot = changed
        movedRoot.stillmatterRootURL = fixture.root.appendingPathComponent("OtherVault")
        XCTAssertFalse(runtime.configure(movedRoot))
        XCTAssertFalse(runtime.configure(AppSettings()))
        XCTAssertTrue(runtime.service === service)
        XCTAssertEqual(builds, 1)

        _ = try service.stopManual()
        XCTAssertEqual(service.snapshot.state, .idle)
        XCTAssertTrue(runtime.configure(changed))
        XCTAssertEqual(builds, 2)
        XCTAssertFalse(runtime.service === service)
        XCTAssertTrue(runtime.configure(AppSettings()))
        XCTAssertNil(runtime.service)
        XCTAssertTrue(runtime.configure(AppSettings()), "Unconfigured startup still refreshes presentation")
    }
}

private final class RuntimeFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterRuntimeTests-\(UUID().uuidString)")
    var workspaceRoot: URL { root.appendingPathComponent("Vault") }

    init() throws {
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeService() -> MeetingCaptureService {
        MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: root),
            preflight: { .readyForTesting }
        )
    }
}
