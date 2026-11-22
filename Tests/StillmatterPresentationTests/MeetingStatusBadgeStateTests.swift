import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class MeetingStatusBadgeStateTests: XCTestCase {
    func testRunningStagesUseStableStageIdentityRatherThanJobOrStageTitles() {
        XCTAssertEqual(badge(stage: TranscriptionJob.stageID).title, "Transcribing")
        XCTAssertEqual(badge(stage: MeetingSummaryJob.stageID).title, "Summarizing")
        XCTAssertEqual(badge(stage: "unknown").title, "Processing")
    }

    func testQueuedStagesDoNotClaimWorkHasStartedOrShowProgress() {
        XCTAssertEqual(badge(stage: TranscriptionJob.stageID, status: .queued, progress: 0.5).title, "Transcription queued")
        XCTAssertEqual(badge(stage: MeetingSummaryJob.stageID, status: .queued).title, "Summarization queued")
        XCTAssertEqual(badge(stage: nil, status: .queued).title, "Queued")
    }

    func testFailuresIdentifyTheFailedStageAndDoNotShowStaleProgress() {
        for (stage, expected) in [(TranscriptionJob.stageID, "Transcription failed"),
                                  (MeetingSummaryJob.stageID, "Summarization failed"),
                                  ("unknown", "Processing failed")] {
            let state = badge(stage: stage, status: .failed, progress: 0.8)
            XCTAssertEqual(state.title, expected)
            XCTAssertEqual(state.meaning, .failure)
        }
    }

    func testMeasuredStageProgressIsOptionalAndStaysOnTheSameLine() {
        XCTAssertEqual(badge(stage: TranscriptionJob.stageID, progress: 0).title, "Transcribing · 0%")
        XCTAssertEqual(badge(stage: TranscriptionJob.stageID, progress: 0.425).title, "Transcribing · 43%")
        XCTAssertEqual(badge(stage: MeetingSummaryJob.stageID, progress: 1).title, "Summarizing · 100%")
        for invalid in [Double.nan, .infinity, -0.1, 1.1] {
            XCTAssertEqual(badge(stage: TranscriptionJob.stageID, progress: invalid).title, "Transcribing")
        }
    }

    func testArchivedStatusOverridesStaleProcessingAndFailure() {
        for status in [JobStatus.running, .failed] {
            let state = badge(stage: TranscriptionJob.stageID, status: status, progress: 0.5, archived: true)
            XCTAssertEqual(state.title, "Archived")
            XCTAssertEqual(state.meaning, .informational)
        }
    }

    func testNonProcessingMeetingStatesRetainTheirMeanings() {
        let expectations: [(MeetingProcessingState, String, MeetingStatusBadgeState.Meaning)] = [
            (.live, "Live", .attention), (.needsAttention, "Needs attention", .attention),
            (.ready, "Ready", .ready), (.unavailable, "Unavailable", .informational)
        ]
        for (processing, title, meaning) in expectations {
            let row = MeetingBrowserRow(id: "test", title: "Meeting", startedAt: nil,
                meetingRelativePath: "Meetings/test/meeting.md", captureState: .stopped,
                processingState: processing)
            XCTAssertEqual(MeetingStatusBadgeState(row: row).title, title)
            XCTAssertEqual(MeetingStatusBadgeState(row: row).meaning, meaning)
        }
    }

    private func badge(stage: String?, status: JobStatus = .running,
                       progress: Double? = nil, archived: Bool = false) -> MeetingStatusBadgeState {
        let job = MeetingJobPresentation(jobID: "job", title: "Unrelated job title", status: status,
            stage: "Unrelated stage title", error: nil, stageID: stage, progressFraction: progress)
        return MeetingStatusBadgeState(row: MeetingBrowserRow(id: "test", title: "Meeting", startedAt: nil,
            meetingRelativePath: "Meetings/test/meeting.md", captureState: .stopped,
            processingState: .processing, job: job, isArchived: archived))
    }
}
