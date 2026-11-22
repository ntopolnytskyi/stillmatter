import XCTest
@testable import StillmatterCore

final class MeetingManagementEligibilityTests: XCTestCase {
    func testManagementDecisionsPreserveActionSpecificRequirements() {
        typealias Scenario = (name: String, capture: MeetingCaptureDisplayState, archived: Bool,
                              job: JobStatus?, version: Bool, processing: MeetingProcessingState, expected: [Bool])
        let scenarios: [Scenario] = [
            ("ready", .stopped, false, nil, true, .ready, [true, true, true, true, true]),
            ("archived can still be removed", .stopped, true, nil, true, .ready, [false, false, true, false, false]),
            ("live", .live, false, nil, true, .live, [false, false, false, false, false]),
            ("unavailable capture", .unavailable, false, nil, true, .ready, [false, false, false, false, false]),
            ("queued", .stopped, false, .queued, true, .ready, [false, false, false, false, false]),
            ("running", .stopped, false, .running, true, .ready, [false, false, false, false, false]),
            ("failed job is inactive", .stopped, false, .failed, true, .needsAttention, [true, true, true, true, false]),
            ("completed", .stopped, false, .succeeded, true, .ready, [true, true, true, true, true]),
            ("rename requires a doorway version", .stopped, false, nil, false, .ready, [false, true, true, true, true]),
            ("legacy processing blocks Archive", .stopped, false, nil, true, .processing, [true, true, true, true, false])
        ]
        for scenario in scenarios {
            let row = MeetingBrowserRow(id: "fixture", title: "Fixture", startedAt: nil,
                meetingRelativePath: "Meetings/fixture/meeting.md", captureState: scenario.capture,
                processingState: scenario.processing, isArchived: scenario.archived)
            let detail = MeetingBrowserDetail(row: row, doorwayText: "", doorwayVersion: scenario.version
                ? WorkspaceFileVersion(contentHash: "fixture", modificationDate: Date(timeIntervalSince1970: 0), byteCount: 0) : nil,
                jobs: scenario.job.map { [job($0)] } ?? [])
            XCTAssertEqual([detail.canRename, detail.canAssociateCalendar, detail.canRemove,
                            detail.reprocessUnavailableReason == nil, detail.archiveUnavailableReason == nil],
                           scenario.expected, scenario.name)
        }
    }

    func testAnOlderActiveJobBlocksManagementEvenWhenThePrimaryJobFinished() {
        let finished = job(.succeeded)
        let row = MeetingBrowserRow(id: "fixture", title: "Fixture", startedAt: nil,
            meetingRelativePath: "Meetings/fixture/meeting.md", captureState: .stopped,
            processingState: .ready, job: finished)
        let detail = MeetingBrowserDetail(row: row, doorwayText: "", job: finished,
            jobs: [finished, job(.running, id: "older")])
        XCTAssertFalse(detail.canAssociateCalendar)
        XCTAssertFalse(detail.canRemove)
        XCTAssertEqual(detail.reprocessUnavailableReason, "Wait for this Meeting’s active work to finish.")
        XCTAssertEqual(detail.archiveUnavailableReason, "Finish processing before archiving this Meeting.")
    }

    private func job(_ status: JobStatus, id: String = "current") -> MeetingJobPresentation {
        MeetingJobPresentation(jobID: id, title: "Fixture", status: status, stage: nil, error: nil)
    }
}
