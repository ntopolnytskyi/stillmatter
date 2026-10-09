import XCTest
@testable import StillmatterCore

final class WeeklyReportPromptCoordinatorTests: XCTestCase {
    func testMeetingDefersPromptUntilMeetingEnds() {
        let draft = WeeklyReportDraft(
            id: "2026-W38",
            relativePath: "Briefs/Weekly/2026-W38.md",
            text: "Draft text"
        )
        let coordinator = WeeklyReportPromptCoordinator()

        coordinator.offer(draft, isMeetingOrRecordingActive: true)
        XCTAssertEqual(coordinator.state, .deferred(draft))

        coordinator.meetingOrRecordingActivityDidChange(isActive: false)
        XCTAssertEqual(coordinator.state, .presented(draft))
    }

    func testRemindNextTimeAndAcceptUseEditedReportText() throws {
        let draft = WeeklyReportDraft(
            id: "2026-W38",
            relativePath: "Briefs/Weekly/2026-W38.md",
            text: "Draft text"
        )
        var accepted: WeeklyReportAcceptanceRequest?
        let coordinator = WeeklyReportPromptCoordinator(onAccept: { accepted = $0 })

        coordinator.offer(draft, isMeetingOrRecordingActive: false)
        XCTAssertEqual(coordinator.state, .presented(draft))
        coordinator.remindNextTime()
        XCTAssertEqual(coordinator.state, .idle)

        coordinator.nextPromptOpportunity(isMeetingOrRecordingActive: false)
        XCTAssertEqual(coordinator.state, .presented(draft))
        try coordinator.accept(editedText: "Edited report")

        XCTAssertEqual(
            accepted,
            WeeklyReportAcceptanceRequest(draft: draft, editedText: "Edited report")
        )
        XCTAssertEqual(coordinator.state, .idle)

        coordinator.offer(draft, isMeetingOrRecordingActive: false)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testFailedAcceptKeepsEditablePromptPresentedForRetry() {
        enum SaveError: Error { case failed }
        let draft = WeeklyReportDraft(
            id: "2026-W38",
            relativePath: "Briefs/Weekly/2026-W38.md",
            text: "Draft text"
        )
        let coordinator = WeeklyReportPromptCoordinator(onAccept: { _ in throw SaveError.failed })
        coordinator.offer(draft, isMeetingOrRecordingActive: false)

        XCTAssertThrowsError(try coordinator.accept(editedText: "Unsaved edit"))
        XCTAssertEqual(coordinator.state, .presented(draft))
    }
}
