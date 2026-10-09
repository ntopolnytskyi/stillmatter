import XCTest
@testable import StillmatterCore

final class TeamsDetectionTests: XCTestCase {
    func testTeamsProcessAndHangupControlDetectMeetingWhileMicrophoneCorroborates() {
        let detector = TeamsDetectionService(requiredStartSamples: 1, requiredEndSamples: 3)

        let snapshot = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Microsoft Teams (com.microsoft.teams2) is running"),
            hangupControl: .observed(true, detail: "Teams exposes hangup-button"),
            microphoneActivity: .observed(true, detail: "Default input device is running")
        ))

        XCTAssertEqual(snapshot.signals.map(\.kind), TeamsDetectionSignalKind.allCases)
        XCTAssertEqual(snapshot.signals.map(\.contribution), [20, 60, 20])
        XCTAssertEqual(snapshot.confidence, 100)
        XCTAssertEqual(snapshot.positiveSampleCount, 1)
        XCTAssertEqual(snapshot.negativeSampleCount, 0)
        XCTAssertTrue(snapshot.isMeetingDetected)
        XCTAssertEqual(snapshot.captureDecision, .observeOnly)
    }

    func testMicrophoneIsNotRequiredForMutedOrListenOnlyMeeting() {
        let detector = TeamsDetectionService(requiredStartSamples: 1)

        let snapshot = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .observed(true, detail: "Teams exposes hangup-button"),
            microphoneActivity: .observed(false, detail: "Default input device is idle")
        ))

        XCTAssertEqual(snapshot.confidence, 80)
        XCTAssertTrue(snapshot.isMeetingDetected)
    }

    func testProcessAndMicrophoneCannotDetectMeetingWithoutHangupControl() {
        let detector = TeamsDetectionService(requiredStartSamples: 1)

        let snapshot = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .observed(false, detail: "No hangup-button found"),
            microphoneActivity: .observed(true, detail: "Default input device is running")
        ))

        XCTAssertEqual(snapshot.confidence, 40)
        XCTAssertFalse(snapshot.isMeetingDetected)
    }

    func testDetectedMeetingEndsAfterConsecutiveConclusiveMissingControlSamples() {
        let detector = TeamsDetectionService(requiredStartSamples: 1, requiredEndSamples: 3)
        let active = TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .observed(true, detail: "Teams exposes hangup-button"),
            microphoneActivity: .observed(false, detail: "Input idle")
        )
        let ended = TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .observed(false, detail: "No hangup-button found"),
            microphoneActivity: .observed(false, detail: "Input idle")
        )

        XCTAssertTrue(detector.observe(active).isMeetingDetected)
        XCTAssertTrue(detector.observe(ended).isMeetingDetected)
        XCTAssertEqual(detector.observe(ended).negativeSampleCount, 2)
        let snapshot = detector.observe(ended)
        XCTAssertEqual(snapshot.negativeSampleCount, 3)
        XCTAssertFalse(snapshot.isMeetingDetected)
    }

    func testUnavailableAccessibilityAndTeamsRestartDoNotEndDetectedMeeting() {
        let detector = TeamsDetectionService(requiredStartSamples: 1, requiredEndSamples: 2)
        _ = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .observed(true, detail: "Teams exposes hangup-button"),
            microphoneActivity: .observed(true, detail: "Input active")
        ))

        let unavailable = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams is running"),
            hangupControl: .unavailable(reason: "Accessibility permission is missing"),
            microphoneActivity: .observed(true, detail: "Input active")
        ))
        XCTAssertTrue(unavailable.isMeetingDetected)
        XCTAssertEqual(unavailable.negativeSampleCount, 0)

        let restarting = detector.observe(TeamsDetectionObservation(
            process: .observed(false, detail: "Teams is not running"),
            hangupControl: .unavailable(reason: "No Teams process is available to inspect"),
            microphoneActivity: .observed(false, detail: "Input idle")
        ))
        XCTAssertTrue(restarting.isMeetingDetected)
        XCTAssertEqual(restarting.negativeSampleCount, 0)
    }

    func testStrongDetectionRemainsObservationOnlyAndDoesNotStartCapture() {
        let detector = TeamsDetectionService(requiredStartSamples: 1)
        let snapshot = detector.observe(.activeMeetingForTesting)

        XCTAssertTrue(snapshot.isMeetingDetected)
        XCTAssertEqual(snapshot.captureDecision, .observeOnly)
        XCTAssertTrue(snapshot.diagnosticSummary.contains("Meeting detected"))
    }
}
