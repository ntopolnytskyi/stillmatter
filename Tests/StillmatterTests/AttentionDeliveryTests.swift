import XCTest
@testable import StillmatterCore

final class AttentionDeliveryTests: XCTestCase {
    func testNonCriticalRequiredPromptWaitsForRecordingToEnd() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let target = AttentionTarget.weeklyReport("2026-W38")
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: true)
        coordinator.offer(AttentionRequest(target: target, title: "Weekly Report", kind: .required))
        XCTAssertTrue(deliveries.isEmpty)

        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.popup(target)])
    }

    func testBackgroundAttentionNotifiesOnceAndRequiredPromptOpensOnFocus() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: false)
        let request = AttentionRequest(target: .weeklyReport("2026-W38"), title: "Weekly Report", kind: .required)
        coordinator.offer(request)
        coordinator.offer(request)
        XCTAssertEqual(deliveries, [.notification(request)])
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.notification(request), .popup(request.target)])
    }

    func testDeferredAttentionFlushesAsNotificationWhenBackgrounded() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .inboxItem("failed"), title: "Job failed", kind: .attention)
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: false)
        coordinator.offer(request)
        XCTAssertTrue(deliveries.isEmpty)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: false)
        XCTAssertEqual(deliveries, [.notification(request)])
        coordinator.offer(request)
        XCTAssertEqual(deliveries, [.notification(request)])
    }

    func testBackgroundAttentionStillHasFocusedRouteIfAppReturns() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .inboxItem("failed"), title: "Job failed", kind: .attention)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: false)
        coordinator.offer(request)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.notification(request), .inline(request)])
    }

    func testFocusedNoticeInterruptedByMeetingIsReissuedAfterward() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .inboxItem("failed"), title: "Job failed", kind: .attention)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        coordinator.offer(request)
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: true)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.inline(request), .inline(request)])
    }

    func testDeferredFocusedAttentionFlushesOnMeetingEnd() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .inboxItem("failed"), title: "Job failed", kind: .attention)
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: true)
        coordinator.offer(request)
        XCTAssertTrue(deliveries.isEmpty)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.inline(request)])
    }

    func testFocusedAttentionShowsNonBlockingNoticeOnce() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .inboxItem("overdue"), title: "Todo overdue", kind: .attention)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        coordinator.offer(request)
        coordinator.offer(request)
        XCTAssertEqual(deliveries, [.inline(request)])
    }

    func testRequiredReviewIsPresentedAgainAfterInterruptionButNotOnEachRefresh() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        let request = AttentionRequest(target: .titleReview("meeting"), title: "Review meeting title", kind: .required)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        coordinator.offer(request)
        coordinator.offer(request)
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: true)
        coordinator.setEnvironment(isMeetingOrRecordingActive: false, isAppFocused: true)
        XCTAssertEqual(deliveries, [.popup(request.target), .popup(request.target)])
        coordinator.clear(request.target)
        coordinator.offer(request)
        XCTAssertEqual(deliveries.count, 3)
    }

    func testCriticalRecordingIssueBypassesSuppression() {
        var deliveries: [AttentionDelivery] = []
        let coordinator = AttentionDeliveryCoordinator { deliveries.append($0) }
        coordinator.setEnvironment(isMeetingOrRecordingActive: true, isAppFocused: false)
        let request = AttentionRequest(target: .captureFailure("failure"), title: "Recording failed", kind: .recordingCritical)
        coordinator.offer(request)
        XCTAssertEqual(deliveries, [.notification(request)])
    }

    func testNotificationTargetRoundTripsWithoutParsingUserVisibleTitle() throws {
        let target = AttentionTarget.inboxItem("job:transcription/123")
        XCTAssertEqual(try JSONDecoder().decode(AttentionTarget.self, from: JSONEncoder().encode(target)), target)
    }
}
