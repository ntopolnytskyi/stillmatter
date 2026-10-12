import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class MeetingReadModelTests: XCTestCase {
    func testInitialBrowserScanIsCachedUntilItsFiltersAreInvalidated() {
        let source = FakeMeetingReadSource(rows: [row("a")])
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: source, executor: executor)
        defer { model.stop() }
        executor.runNext() // Construct the workspace-owned source.

        var first: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { first = $0 }
        executor.runNext()
        XCTAssertEqual(try? first?.get().visibleRows.map(\.id), ["a"])
        XCTAssertEqual(source.browserReadCount, 1)

        var cached: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { cached = $0 }
        executor.runNext()
        XCTAssertEqual(try? cached?.get().visibleRows.map(\.id), ["a"])
        XCTAssertEqual(source.browserReadCount, 1)

        model.readBrowser(filters: MeetingBrowserFilters(query: "meeting")) { _ in }
        executor.runNext()
        XCTAssertEqual(source.browserProjectionReadCount, 1, "New filters reuse the workspace projection")
        XCTAssertEqual(source.browserReadCount, 2)

        source.rows = [row("a", title: "Updated")]
        model.invalidate(.workspaceFilesChanged(paths: ["Meetings/a/summary.md"]))
        executor.runAll()
        var refreshed: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { refreshed = $0 }
        executor.runAll()
        XCTAssertEqual(try? refreshed?.get().visibleRows.first?.title, "Updated")
        XCTAssertEqual(source.browserProjectionReadCount, 2)
        XCTAssertEqual(source.browserReadCount, 3)
    }

    func testLatestSelectedDetailWinsWhenEarlierReadCompletesLater() {
        let source = FakeMeetingReadSource(rows: [row("a"), row("b")])
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: source, executor: executor)
        defer { model.stop() }
        executor.runNext()
        var browser: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { browser = $0 }
        executor.runNext()
        XCTAssertNotNil(browser)

        var delivered: [String] = []
        model.readDetail(for: reference("a")) { result in
            if case let .success(detail) = result { delivered.append(detail.row.id) }
        }
        model.readDetail(for: reference("b")) { result in
            if case let .success(detail) = result { delivered.append(detail.row.id) }
        }
        executor.run(at: 1) // B is delivered before A at the consuming seam.
        executor.runNext()
        XCTAssertEqual(delivered, ["b"])
        XCTAssertEqual(source.detailReadCount, 1, "A was stale before its source read began")
    }

    func testWorkspaceSwitchRejectsLateReadsFromPreviousWorkspace() {
        let sourceA = FakeMeetingReadSource(rows: [row("a")])
        let sourceB = FakeMeetingReadSource(rows: [row("b")])
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: sourceA, executor: executor)
        defer { model.stop() }
        executor.runNext()
        model.readBrowser(filters: MeetingBrowserFilters()) { _ in }
        executor.runNext()

        var oldWorkspaceDelivered = false
        model.readDetail(for: reference("a")) { _ in oldWorkspaceDelivered = true }
        model.switchWorkspace(to: "workspace-b") { sourceB }
        var newWorkspace: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { newWorkspace = $0 }
        executor.run(at: 1) // Configure B.
        executor.run(at: 1) // Read B.
        executor.runNext()  // The old A request arrives late.

        XCTAssertFalse(oldWorkspaceDelivered)
        XCTAssertEqual(try? newWorkspace?.get().visibleRows.map(\.id), ["b"])
        XCTAssertEqual(sourceA.detailReadCount, 0)
    }

    func testExternalEditInvalidatesWithoutSearchIndexAndUnrelatedProjectDoesNot() throws {
        let fixture = try MeetingFixtureFactory.make(.readyMeeting)
        defer { fixture.remove() }
        let executor = ControlledReadExecutor()
        let source = MeetingManagementReadSource {
            MeetingManagementService(vault: fixture.vault, searchIndex: nil)
        }
        let model = MeetingReadModel(workspaceID: "fixture", sourceFactory: { source },
                                     scheduleRead: executor.enqueue, deliver: { $0() })
        defer { model.stop() }
        var changes: [MeetingReadChangeEvent] = []
        let observation = model.observeChanges { changes.append($0) }
        defer { observation.cancel() }
        executor.runNext()

        var initial: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { initial = $0 }
        executor.runNext()
        XCTAssertEqual(try? initial?.get().visibleRows.first?.title, "Ready meeting")

        model.invalidate(.workspaceFilesChanged(paths: ["Projects/2026/10/19/unrelated.md"]))
        executor.runAll()
        var cached: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { cached = $0 }
        executor.runNext()
        XCTAssertEqual(try? cached?.get().visibleRows.first?.title, "Ready meeting")
        XCTAssertTrue(changes.isEmpty, "Project files must not invalidate Meeting details")

        let meetingPath = "Meetings/ready/meeting.md"
        let old = try fixture.vault.readMarkdown(relativePath: meetingPath)
        let edited = String(data: old.data, encoding: .utf8)!.replacingOccurrences(of: "Ready meeting", with: "Edited externally")
        _ = try fixture.vault.writeMarkdown(Data(edited.utf8), relativePath: meetingPath, expectedVersion: old.version)
        model.invalidate(.workspaceFilesChanged(paths: [meetingPath]))
        executor.runAll()
        let notesPath = "Meetings/ready/meeting.md"
        let latest = try fixture.vault.readMarkdown(relativePath: notesPath)
        let updatedNotes = String(data: latest.data, encoding: .utf8)!.replacingOccurrences(of: "Fixture note.", with: "External notes.")
        _ = try fixture.vault.writeMarkdown(Data(updatedNotes.utf8), relativePath: notesPath, expectedVersion: latest.version)
        model.invalidate(.workspaceFilesChanged(paths: [notesPath]))
        executor.runAll()

        let summaryPath = "Meetings/ready/summary.md"
        let oldSummary = try fixture.vault.readMarkdown(relativePath: summaryPath)
        let editedSummary = String(data: oldSummary.data, encoding: .utf8)!.replacingOccurrences(of: "A ready fixture.", with: "Externally updated summary.")
        _ = try fixture.vault.writeMarkdown(Data(editedSummary.utf8), relativePath: summaryPath, expectedVersion: oldSummary.version)
        model.invalidate(.workspaceFilesChanged(paths: [summaryPath]))
        executor.runAll()
        XCTAssertEqual(changes.last?.affectedMeetingIDs, Set(["ready"]))
        XCTAssertEqual(changes.last?.requiresRescan, false)

        var refreshedDetail: Result<MeetingBrowserDetail, MeetingReadError>?
        model.readDetail(for: MeetingReference(id: "ready", meetingRelativePath: notesPath)) { refreshedDetail = $0 }
        executor.runAll()
        XCTAssertEqual(try? refreshedDetail?.get().humanNotes, "External notes.")
        XCTAssertEqual(try? refreshedDetail?.get().summary?.summary, "Externally updated summary.\n")

        var refreshed: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { refreshed = $0 }
        executor.runAll()
        XCTAssertEqual(try? refreshed?.get().visibleRows.first?.title, "Edited externally")
    }

    func testSourceFailureIsNotAnEmptySnapshotAndRetryCanSucceed() {
        let source = FakeMeetingReadSource(rows: [])
        source.browserError = ReadFixtureError.failed
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: source, executor: executor)
        defer { model.stop() }
        executor.runNext()

        var failed: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { failed = $0 }
        executor.runNext()
        guard case let .failure(.sourceFailure(error)) = failed else {
            return XCTFail("Expected the original source failure, not an empty browser")
        }
        XCTAssertTrue(error is ReadFixtureError)

        source.browserError = nil
        var recovered: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { recovered = $0 }
        executor.runNext()
        XCTAssertEqual(try? recovered?.get().visibleRows, [])
        XCTAssertEqual(source.browserProjectionReadCount, 2)
    }

    func testCancelledObservationAndStoppedModelDoNotDeliverCallbacks() {
        let source = FakeMeetingReadSource(rows: [row("a")])
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: source, executor: executor)
        var changes = 0
        let observation = model.observeChanges { _ in changes += 1 }
        observation.cancel()
        model.invalidate(.appMutation(paths: ["Meetings/a/meeting.md"]))
        executor.runAll()
        XCTAssertEqual(changes, 0)

        var deliveredAfterStop = false
        model.readBrowser(filters: MeetingBrowserFilters()) { _ in deliveredAfterStop = true }
        model.stop()
        executor.runAll()
        XCTAssertFalse(deliveredAfterStop)
        XCTAssertEqual(source.browserReadCount, 0)
    }

    func testSaveInvalidationWithDirectoryAndFileDeliversOnceAndRefreshes() {
        let source = FakeMeetingReadSource(rows: [row("a"), row("b")])
        let reads = ControlledReadExecutor()
        let deliveries = ControlledReadExecutor()
        let model = MeetingReadModel(workspaceID: "fixture", sourceFactory: { source },
                                     scheduleRead: reads.enqueue, deliver: deliveries.enqueue)
        reads.runAll()
        model.readBrowser(filters: MeetingBrowserFilters()) { _ in }
        reads.runAll()
        deliveries.runAll()
        var changes: [MeetingReadChangeEvent] = []
        let observation = model.observeChanges { changes.append($0) }
        model.invalidate(.workspaceFilesChanged(paths: ["Meetings/a", "Meetings/a/meeting.md"]))
        reads.runAll()
        deliveries.runAll()
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.affectedMeetingIDs, Set(["a"]))
        XCTAssertEqual(changes.first?.requiresRescan, false)
        source.rows = [row("a", title: "Saved"), row("b")]
        var refreshed: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { refreshed = $0 }
        reads.runAll()
        deliveries.runAll()
        XCTAssertEqual(try? refreshed?.get().visibleRows.first?.title, "Saved")
        observation.cancel()
        model.invalidate(.appMutation(paths: ["Meetings/a/meeting.md"]))
        reads.runAll()
        deliveries.runAll()
        XCTAssertEqual(changes.count, 1, "Cancelled observer must not receive late invalidation")
        model.stop()
    }

    func testRapidInvalidationsDoNotLoseAffectedMeetingsWhileCallbacksWaitForMain() {
        let source = FakeMeetingReadSource(rows: [row("a"), row("b")])
        let reads = ControlledReadExecutor()
        let deliveries = ControlledReadExecutor()
        let model = MeetingReadModel(workspaceID: "workspace-a", sourceFactory: { source },
                                     scheduleRead: reads.enqueue, deliver: deliveries.enqueue)
        defer { model.stop() }
        reads.runNext()
        model.readBrowser(filters: MeetingBrowserFilters()) { _ in }
        reads.runNext()
        deliveries.runAll()

        var events: [MeetingReadChangeEvent] = []
        let observation = model.observeChanges { events.append($0) }
        defer { observation.cancel() }
        model.invalidate(.workspaceFilesChanged(paths: ["Meetings/a/summary.md"]))
        model.invalidate(.workspaceFilesChanged(paths: ["Meetings/b/summary.md"]))
        deliveries.runAll()

        XCTAssertEqual(events.map(\.affectedMeetingIDs), [Set(["a"]), Set(["b"])])
        XCTAssertEqual(events.map(\.revision), [1, 2])
    }

    func testMonitoringFailureIsSurfacedAndExplicitRescanRefreshesTheBrowser() {
        let source = FakeMeetingReadSource(rows: [row("a")])
        let executor = ControlledReadExecutor()
        let model = makeModel("workspace-a", source: source, executor: executor)
        defer { model.stop() }
        executor.runNext()
        var initial: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { initial = $0 }
        executor.runNext()
        XCTAssertEqual(try? initial?.get().visibleRows.map(\.id), ["a"])

        var changes: [MeetingReadChangeEvent] = []
        let observation = model.observeChanges { changes.append($0) }
        defer { observation.cancel() }
        model.invalidate(.monitoringFailed("fixture monitor failure"))
        XCTAssertEqual(changes.last?.change, .monitoringFailed("fixture monitor failure"))
        XCTAssertEqual(changes.last?.requiresRescan, true)

        source.rows = [row("b")]
        model.forceRescan()
        XCTAssertEqual(changes.last?.change, .rescanRequired(reason: "Explicit refresh requested"))
        var refreshed: Result<MeetingBrowserSnapshot, MeetingReadError>?
        model.readBrowser(filters: MeetingBrowserFilters()) { refreshed = $0 }
        executor.runAll()
        XCTAssertEqual(try? refreshed?.get().visibleRows.map(\.id), ["b"])
        XCTAssertEqual(source.browserProjectionReadCount, 2)
    }

    func testWorkspaceChangeBatchCoalescesPathsAndDirectoryRenameDeleteOrOverflowRequireRescan() {
        var batch = MeetingWorkspaceChangeBatch()
        batch.record(relativePath: "Meetings/a/summary.md")
        batch.record(relativePath: "Meetings/a/summary.md")
        batch.record(relativePath: "Projects/a.md")
        XCTAssertEqual(batch.changedPaths, ["Meetings/a/summary.md"])
        XCTAssertFalse(batch.requiresRescan)

        batch.record(relativePath: "Meetings/a", isDirectory: true)
        XCTAssertTrue(batch.requiresRescan)
        XCTAssertEqual(batch.change, .rescanRequired(reason: "Filesystem structure changed"))

        var overflow = MeetingWorkspaceChangeBatch()
        overflow.record(relativePath: "Meetings/a/meeting.md", mustRescan: true)
        XCTAssertEqual(overflow.change, .rescanRequired(reason: "Filesystem event history was dropped"))
    }

    private func makeModel(_ workspaceID: String, source: FakeMeetingReadSource,
                           executor: ControlledReadExecutor) -> MeetingReadModel {
        MeetingReadModel(workspaceID: workspaceID, sourceFactory: { source },
                         scheduleRead: executor.enqueue, deliver: { $0() })
    }

    private func reference(_ id: String) -> MeetingReference {
        MeetingReference(id: id, meetingRelativePath: "Meetings/\(id)/meeting.md")
    }

    private func row(_ id: String, title: String? = nil) -> MeetingBrowserRow {
        MeetingBrowserRow(id: id, title: title ?? "Meeting \(id)", startedAt: nil,
                          meetingRelativePath: "Meetings/\(id)/meeting.md",
                          captureState: .stopped, processingState: .ready)
    }
}

private final class ControlledReadExecutor {
    private var operations: [() -> Void] = []

    func enqueue(_ operation: @escaping () -> Void) { operations.append(operation) }

    func runNext() {
        guard !operations.isEmpty else { XCTFail("No read operation was queued"); return }
        operations.removeFirst()()
    }

    func run(at index: Int) {
        guard operations.indices.contains(index) else { XCTFail("No read operation at index \(index)"); return }
        operations.remove(at: index)()
    }

    func runAll() {
        while !operations.isEmpty { runNext() }
    }
}

private final class FakeMeetingReadSource: MeetingReadSource {
    var rows: [MeetingBrowserRow]
    var browserError: Error?
    var detailError: Error?
    private(set) var browserProjectionReadCount = 0
    private(set) var browserReadCount = 0
    private(set) var detailReadCount = 0

    init(rows: [MeetingBrowserRow]) { self.rows = rows }

    func browserProjection() throws -> [MeetingBrowserRow] {
        browserProjectionReadCount += 1
        if let browserError { throw browserError }
        return rows
    }

    func browserRows(filters: MeetingBrowserFilters, from projection: [MeetingBrowserRow]) throws -> MeetingBrowserReadResult {
        browserReadCount += 1
        if let browserError { throw browserError }
        return MeetingBrowserReadResult(visibleRows: projection, availableRows: projection)
    }

    func detail(for reference: MeetingReference, browserRow: MeetingBrowserRow) throws -> MeetingBrowserDetail {
        detailReadCount += 1
        if let detailError { throw detailError }
        return MeetingBrowserDetail(row: browserRow, doorwayText: "Detail for \(reference.id)")
    }
}

private enum ReadFixtureError: Error { case failed }
