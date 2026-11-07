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

    func testPendingPriorFinalizationKeepsRuntimeWorkspaceStableAfterCaptureIsIdle() throws {
        let fixture = try RuntimeFixture()
        let mic = HeldRuntimeRecorder()
        let runtime = CaptureSessionRuntime(build: { _ in fixture.makeService(micRecorder: mic) }, onSnapshot: { _ in })
        var settings = AppSettings(stillmatterRootURL: fixture.workspaceRoot)
        XCTAssertTrue(runtime.configure(settings))
        let service = try XCTUnwrap(runtime.service)
        _ = try service.startManual(titleHint: "First")
        let completed = expectation(description: "A finishes")
        service.stopManualAsync { result in
            if case let .failure(error) = result { XCTFail("A finalization failed: \(error)") }
            completed.fulfill()
        }
        let started = expectation(description: "A finalization held")
        DispatchQueue.global().async {
            mic.exportStarted.wait()
            DispatchQueue.main.async { started.fulfill() }
        }
        wait(for: [started], timeout: 5)
        XCTAssertEqual(service.snapshot.state, .idle)
        settings.recordingMediaURL = fixture.root.appendingPathComponent("OtherMedia")
        XCTAssertFalse(runtime.configure(settings))
        mic.resumeExport.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertTrue(runtime.configure(settings))
    }

    func testFailedPriorFinalizationAllowsReconfigurationOnlyAfterSourceIsStopped() throws {
        let fixture = try RuntimeFixture()
        let mic = HeldRuntimeRecorder()
        mic.failExport = true
        let runtime = CaptureSessionRuntime(build: { _ in fixture.makeService(micRecorder: mic) }, onSnapshot: { _ in })
        var settings = AppSettings(stillmatterRootURL: fixture.workspaceRoot)
        XCTAssertTrue(runtime.configure(settings))
        let service = try XCTUnwrap(runtime.service)
        let first = try service.startManual(titleHint: "Session A")
        let completed = expectation(description: "A finalization reports failure")
        service.stopManualAsync { result in
            guard case .failure = result else { XCTFail("A should report an export failure"); completed.fulfill(); return }
            completed.fulfill()
        }
        let started = expectation(description: "A export is held")
        DispatchQueue.global().async {
            mic.exportStarted.wait()
            DispatchQueue.main.async { started.fulfill() }
        }
        wait(for: [started], timeout: 5)
        settings.recordingMediaURL = fixture.root.appendingPathComponent("OtherMedia")
        XCTAssertFalse(runtime.configure(settings), "A still owns background finalization")

        mic.resumeExport.signal()
        wait(for: [completed], timeout: 5)
        XCTAssertEqual(service.snapshot.state, .idle)
        XCTAssertEqual(service.snapshot.priorCaptureFinalizations.map(\.sessionID), [first.id])
        XCTAssertTrue(runtime.configure(settings), "A's stopped source no longer blocks the next capture configuration")
        let next = try XCTUnwrap(runtime.service)
        XCTAssertFalse(next === service)
        let second = try next.startManual(titleHint: "Session B")
        XCTAssertNotEqual(second.meetingRelativePath, first.meetingRelativePath)
        XCTAssertEqual(next.snapshot.state, .recording)
        XCTAssertEqual(service.snapshot.priorCaptureFinalizations.map(\.sessionID), [first.id])
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

    func makeService(micRecorder: MicTrackRecordingManaging? = nil) -> MeetingCaptureService {
        MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: root),
            micRecorder: micRecorder, preflight: { .readyForTesting }
        )
    }
}

private final class HeldRuntimeRecorder: MicTrackRecordingManaging {
    private(set) var activeMetadata: MicTrackRecordingMetadata?
    let exportStarted = DispatchSemaphore(value: 0)
    let resumeExport = DispatchSemaphore(value: 0)
    var failExport = false

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        let metadata = MicTrackRecordingMetadata(captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath, recoveryFilePath: "/test/\(sessionID)/mic.caf",
            finalFilePath: "/test/\(sessionID)/mic.m4a", metadataFilePath: "/test/\(sessionID)/mic.json",
            startedAt: startedAt)
        activeMetadata = metadata
        return metadata
    }

    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata { try releaseForFinalization(endedAt: endedAt) }

    func releaseForFinalization(endedAt: Date) throws -> MicTrackRecordingMetadata {
        var sealed = activeMetadata!
        sealed.status = .finalizing
        sealed.endedAt = endedAt
        activeMetadata = nil
        return sealed
    }

    func finalizeReleased(_ released: MicTrackRecordingMetadata) throws -> MicTrackRecordingMetadata {
        exportStarted.signal()
        resumeExport.wait()
        if failExport { throw CocoaError(.fileWriteUnknown) }
        var completed = released
        completed.status = .completed
        return completed
    }
}
