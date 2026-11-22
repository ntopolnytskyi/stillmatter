import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class MeetingReviewNavigationTests: XCTestCase {
    func testRouteWaitsForCommittedBrowserAndSelectedDetail() throws {
        let navigation = MeetingReviewNavigation(), owner = NSObject()
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { XCTFail("Valid route") }
        XCTAssertNil(navigation.selection(rows: [], state: .loading, filtersMatch: true, owner: owner))
        XCTAssertNil(navigation.selection(rows: [], state: .loaded, filtersMatch: false, owner: owner))
        XCTAssertEqual(navigation.disposition(for: detail(), owner: owner), .wait)
        let selection = try XCTUnwrap(navigation.selection(rows: [row()], state: .loaded, filtersMatch: true, owner: owner))
        XCTAssertNil(navigation.selection(rows: [row()], state: .loaded, filtersMatch: true, owner: owner))
        XCTAssertEqual(navigation.disposition(for: detail(), owner: owner), .wait, "A queued selection has not executed")
        XCTAssertTrue(navigation.beginSelection(selection, rows: [row()], owner: owner))
        XCTAssertEqual(navigation.disposition(for: detail("other"), owner: owner), .wait)
        XCTAssertEqual(navigation.disposition(for: detail(), owner: owner), .openActionItems)
        XCTAssertEqual(navigation.disposition(for: detail(), owner: owner), .display)
        XCTAssertFalse(navigation.isPending)
    }

    func testReplacementCancellationAndWorkspaceChangeSuppressQueuedSelection() throws {
        let navigation = MeetingReviewNavigation(), owner = NSObject(), replacement = NSObject()
        var failures = 0
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        let old = try selection(navigation, owner: owner)
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        XCTAssertFalse(navigation.beginSelection(old, rows: [row()], owner: owner))
        let current = try selection(navigation, owner: owner)
        XCTAssertFalse(navigation.beginSelection(current, rows: [row()], owner: replacement))
        XCTAssertEqual(navigation.disposition(for: detail(), owner: replacement), .display)
        XCTAssertFalse(navigation.isPending)
        XCTAssertEqual(failures, 0)
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        let canceled = try selection(navigation, owner: owner)
        navigation.cancel()
        XCTAssertFalse(navigation.beginSelection(canceled, rows: [row()], owner: owner))
        XCTAssertEqual(failures, 0, "User cancellation is not an unavailable target")
    }

    func testDeletedAndArchivedTargetsFailExactlyOnceBeforeSelection() throws {
        let navigation = MeetingReviewNavigation(), owner = NSObject()
        var failures = 0
        for rows in [[MeetingBrowserRow](), [row(archived: true)]] {
            navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
            XCTAssertNil(navigation.selection(rows: rows, state: .loaded, filtersMatch: true, owner: owner))
        }
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        let queued = try selection(navigation, owner: owner)
        XCTAssertFalse(navigation.beginSelection(queued, rows: [], owner: owner))
        navigation.browserStateChanged(.failed("read failed"), owner: owner)
        XCTAssertEqual(failures, 3)
    }

    func testOnlySelectedDetailFailuresEndRouteAndWorkspaceFailureCannotLeak() throws {
        let navigation = MeetingReviewNavigation(), owner = NSObject(), replacement = NSObject()
        var failures = 0
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        navigation.detailStateChanged(.failed("unrelated detail"), owner: owner)
        XCTAssertTrue(navigation.isPending)
        let selected = try selection(navigation, owner: owner)
        XCTAssertTrue(navigation.beginSelection(selected, rows: [row()], owner: owner))
        navigation.detailStateChanged(.failed("target failed"), owner: owner)
        XCTAssertEqual(failures, 1)
        navigation.begin(meetingPath: row().meetingRelativePath, owner: owner) { failures += 1 }
        navigation.browserStateChanged(.unavailable("new workspace"), owner: replacement)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(navigation.isPending)
    }

    private func selection(_ navigation: MeetingReviewNavigation, owner: NSObject) throws -> MeetingReviewNavigation.Selection {
        try XCTUnwrap(navigation.selection(rows: [row()], state: .loaded, filtersMatch: true, owner: owner))
    }
    private func row(_ id: String = "target", archived: Bool = false) -> MeetingBrowserRow {
        MeetingBrowserRow(id: id, title: id, startedAt: nil, meetingRelativePath: "Meetings/\(id)/meeting.md",
                         captureState: .stopped, processingState: .ready, isArchived: archived)
    }
    private func detail(_ id: String = "target") -> MeetingBrowserDetail {
        MeetingBrowserDetail(row: row(id), doorwayText: "")
    }
}
