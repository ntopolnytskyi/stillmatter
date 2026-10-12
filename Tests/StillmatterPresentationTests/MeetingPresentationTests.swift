import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class MeetingPresentationTests: XCTestCase {
    func testSelectionReconcilesAcrossRapidChangesAndFilters() {
        var state = MeetingBrowserPresentationState()
        XCTAssertEqual(state.reconcile(visibleMeetingIDs: ["a", "b"]), "a")
        state.select("b", alsoSelected: ["a", "b"])
        XCTAssertEqual(state.reconcile(visibleMeetingIDs: ["b", "c"], selectedMeetingIDs: ["a", "b"]), "b")
        XCTAssertEqual(state.selectedMeetingIDs, ["b"])
        XCTAssertEqual(state.reconcile(visibleMeetingIDs: ["c"]), "c")
        XCTAssertNil(state.reconcile(visibleMeetingIDs: []))
        XCTAssertNil(state.selectedMeetingID)
    }

    func testMetricsExposeReadCountsTimingsAndViewUpdatesWithoutLogging() throws {
        var ticks = [10.0, 10.25, 11.0, 11.5]
        var observed: MeetingPresentationMetricsSnapshot?
        let metrics = MeetingPresentationMetrics(now: { ticks.removeFirst() }, onChange: { observed = $0 })
        XCTAssertEqual(metrics.measureMeetingRead { "loaded" }, "loaded")
        metrics.recordMeetingRead(duration: 0.5)
        metrics.recordViewUpdate()
        let expected = MeetingPresentationMetricsSnapshot(
            meetingReadCount: 2, browserReloadCount: 0,
            totalMeetingReadDuration: 0.75, viewUpdateCount: 1
        )
        XCTAssertEqual(metrics.snapshot, expected)
        XCTAssertEqual(observed, expected)
        XCTAssertThrowsError(try metrics.measureMeetingRead { throw FixtureError.expected })
        XCTAssertEqual(metrics.snapshot.meetingReadCount, 3)
    }

    func testReadLoaderMeasuresRealBrowserAndDetailReads() throws {
        let fixture = try MeetingFixtureFactory.make(.readyMeeting)
        defer { fixture.remove() }
        var tick = 20.0
        let metrics = MeetingPresentationMetrics(now: {
            defer { tick += 0.125 }
            return tick
        })
        let loader = MeetingBrowserReadLoader(metrics: metrics)
        let service = MeetingManagementService(vault: fixture.vault)

        let rows = try loader.browserRows(from: service, filters: MeetingBrowserFilters())
        let row = try XCTUnwrap(rows.visible.first)
        let detail = try loader.detail(for: row, from: service)

        XCTAssertEqual(detail.row.id, row.id)
        XCTAssertEqual(metrics.snapshot.meetingReadCount, 2)
        XCTAssertEqual(metrics.snapshot.browserReloadCount, 1)
        XCTAssertEqual(metrics.snapshot.totalMeetingReadDuration, 0.25, accuracy: 0.000_001)
    }

    func testFixtureFactoryCoversNamedBaselineStatesWithFixedTimeAndTemporaryRoots() throws {
        XCTAssertEqual(MeetingFixtureCase.allCases.count, 13)
        for fixtureCase in MeetingFixtureCase.allCases {
            let fixture = try MeetingFixtureFactory.make(fixtureCase)
            defer { fixture.remove() }
            XCTAssertEqual(fixture.createdAt, MeetingFixtureFactory.fixedDate)
            XCTAssertEqual(fixture.workspaceConfigured, fixtureCase != .noWorkspace)
            XCTAssertTrue(fixture.root.path.contains("StillmatterPresentationFixtures"))
            XCTAssertEqual(try fixture.vault.textPaths().count, fixtureCase.expectedFileCount)
        }
        let first = try MeetingFixtureFactory.make(.readyMeeting)
        defer { first.remove() }
        let second = try MeetingFixtureFactory.make(.readyMeeting)
        defer { second.remove() }
        XCTAssertEqual(try first.vault.readMarkdown(relativePath: "Meetings/ready/meeting.md").data,
                       try second.vault.readMarkdown(relativePath: "Meetings/ready/meeting.md").data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.root.appendingPathComponent("recordings").path))
    }
}

private enum FixtureError: Error { case expected }
