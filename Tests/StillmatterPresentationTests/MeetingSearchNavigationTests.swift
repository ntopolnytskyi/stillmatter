import XCTest
@testable import StillmatterCore
@testable import StillmatterPresentation

final class MeetingSearchNavigationTests: XCTestCase {
    func testRouteWaitsForCommittedBrowserAndSelectsOnlyOnce() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject()
        navigation.begin(sourcePath: "Meetings/call/my-notes.md", owner: owner)
        XCTAssertNil(navigation.selection(rows: [], isLoaded: false, filtersMatch: true, owner: owner))
        XCTAssertNil(navigation.selection(rows: [], isLoaded: true, filtersMatch: false, owner: owner))
        XCTAssertNil(navigation.message)
        let selection = try XCTUnwrap(navigation.selection(rows: [row()], isLoaded: true, filtersMatch: true, owner: owner))
        XCTAssertEqual(selection.meetingID, "call")
        XCTAssertTrue(navigation.isCurrent(selection, owner: owner))
        XCTAssertNil(navigation.selection(rows: [row()], isLoaded: true, filtersMatch: true, owner: owner))
    }

    func testNewRouteAndWorkspaceReplacementRejectQueuedSelection() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject(), replacement = NSObject()
        navigation.begin(sourcePath: "Meetings/call/summary.md", owner: owner)
        let old = try selection(navigation, owner: owner)
        navigation.begin(sourcePath: "Meetings/call/my-notes.md", owner: owner)
        XCTAssertFalse(navigation.isCurrent(old, owner: owner))
        let current = try selection(navigation, owner: owner)
        XCTAssertFalse(navigation.isCurrent(current, owner: replacement))
        XCTAssertFalse(navigation.isPending)
        XCTAssertNil(navigation.destination(for: detail(), owner: replacement))
    }

    func testWorkspaceChangeBetweenSelectionAndDetailDropsRoute() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject(), replacement = NSObject()
        begin(navigation, filename: "my-notes.md", owner: owner)
        _ = try selection(navigation, owner: owner)
        XCTAssertNil(navigation.destination(for: detail(), owner: replacement))
        XCTAssertFalse(navigation.isPending)
        XCTAssertNil(navigation.message)
    }

    func testMissingSourceCannotResumeAndNewRequestClearsFailure() {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject()
        begin(navigation, filename: "summary.md", owner: owner)
        XCTAssertNil(navigation.selection(rows: [], isLoaded: true, filtersMatch: true, owner: owner))
        XCTAssertTrue(navigation.message?.contains("no longer available") == true)
        XCTAssertFalse(navigation.isPending)
        XCTAssertNil(navigation.selection(rows: [row()], isLoaded: true, filtersMatch: true, owner: owner))
        begin(navigation, filename: "my-notes.md", owner: owner)
        XCTAssertNil(navigation.message)
    }

    func testTabsWaitForOwningDetailAndConsumeRouteOnce() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject()
        let cases: [(String, MeetingDetailPage)] = [("my-notes.md", .notes), ("notes.md", .notes),
            ("action-items.md", .actionItems), ("open-items.md", .openItems), ("summary.md", .summary),
            ("meeting.md", .summary), ("transcript.json", .transcript), ("transcript.txt", .transcript),
            ("transcript.vtt", .transcript)]
        for (filename, page) in cases {
            begin(navigation, filename: filename, owner: owner)
            XCTAssertNil(navigation.destination(for: detail(), owner: owner), "Browser phase must finish first")
            _ = try selection(navigation, owner: owner)
            XCTAssertNil(navigation.destination(for: detail(id: "other"), owner: owner))
            XCTAssertEqual(navigation.destination(for: detail(), owner: owner)?.page, page)
            XCTAssertNil(navigation.destination(for: detail(), owner: owner))
            XCTAssertFalse(navigation.isPending)
        }
    }

    func testTranscriptDestinationRevalidatesTextAndFindsCorrectOverlappingSegment() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject()
        let segments = [segment("wrong", text: "Other speech", start: 10, end: 20),
                        segment("target", text: " Target speech \n", start: 12, end: 14, seek: 8)]
        let source = detail(transcript: segments)
        begin(navigation, filename: "transcript.txt", owner: owner, body: "Target speech", seconds: 12)
        _ = try selection(navigation, owner: owner)
        let destination = try XCTUnwrap(navigation.destination(for: source, owner: owner))
        XCTAssertEqual(destination.page, .transcript)
        XCTAssertEqual(destination.segment?.id, "target")
        XCTAssertEqual(destination.segment?.seekSeconds, 8)
        XCTAssertEqual(destination.seconds, 12)
        XCTAssertFalse(destination.clearTimeline)
        XCTAssertNil(navigation.message)

        for (text, seconds) in [("Changed speech", 12.0), ("Target speech", 14.0)] {
            begin(navigation, filename: "transcript.json", owner: owner, body: text, seconds: seconds)
            _ = try selection(navigation, owner: owner)
            let changed = try XCTUnwrap(navigation.destination(for: source, owner: owner))
            XCTAssertNil(changed.segment)
            XCTAssertTrue(changed.clearTimeline)
            XCTAssertTrue(navigation.message?.contains("utterance changed") == true)
        }
    }

    func testCancelAndSourceOnlyNavigationNeverChangeTabOrSeek() throws {
        let navigation = MeetingSearchNavigation()
        let owner = NSObject()
        begin(navigation, filename: "my-notes.md", owner: owner)
        let queued = try selection(navigation, owner: owner)
        navigation.cancel()
        XCTAssertFalse(navigation.isCurrent(queued, owner: owner))
        XCTAssertNil(navigation.destination(for: detail(), owner: owner))
        navigation.begin(sourcePath: "Meetings/call/my-notes.md", owner: owner)
        _ = try selection(navigation, owner: owner)
        XCTAssertNil(navigation.destination(for: detail(), owner: owner))
        XCTAssertFalse(navigation.isPending)
    }

    private func begin(_ navigation: MeetingSearchNavigation, filename: String, owner: NSObject,
                       body: String = "Match", seconds: Double? = nil) {
        let path = "Meetings/call/" + filename
        navigation.begin(sourcePath: path, result: SearchResult(kind: .markdown, sourcePath: path,
            title: "Match", body: body, transcriptStartSeconds: seconds), owner: owner)
    }

    private func selection(_ navigation: MeetingSearchNavigation, owner: NSObject) throws -> MeetingSearchNavigation.Selection {
        try XCTUnwrap(navigation.selection(rows: [row()], isLoaded: true, filtersMatch: true, owner: owner))
    }

    private func row(_ id: String = "call") -> MeetingBrowserRow {
        MeetingBrowserRow(id: id, title: id, startedAt: nil, meetingRelativePath: "Meetings/\(id)/meeting.md",
                          captureState: .stopped, processingState: .ready)
    }

    private func detail(id: String = "call", transcript: [MeetingTranscriptSegment] = []) -> MeetingBrowserDetail {
        MeetingBrowserDetail(row: row(id), doorwayText: "", transcript: transcript)
    }

    private func segment(_ id: String, text: String, start: Double, end: Double, seek: Double? = nil) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(id: id, startSeconds: start, endSeconds: end, track: "microphone",
                                 speaker: "Me", text: text, seekSeconds: seek)
    }
}
