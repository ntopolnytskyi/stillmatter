import XCTest
@testable import StillmatterCore

final class TeamsRecordingPolicyTests: XCTestCase {
    private func snapshot(_ active: Bool) -> TeamsDetectionSnapshot {
        TeamsDetectionService().observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams"),
            hangupControl: .observed(active, detail: "hangup-button"),
            microphoneActivity: .observed(false, detail: "muted")
        ))
    }

    func testAutomaticStartsOnceForConfirmedMutedCallAndStopsOnlyOwnedCaptureAtEnd() {
        let policy = TeamsRecordingPolicy()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .start)
        policy.recordStartSucceeded()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(snapshot(false), mode: .automatic, captureState: .recording), .stop)
        XCTAssertEqual(policy.observe(snapshot(false), mode: .automatic, captureState: .idle), .none)
    }

    func testAskRequiresConsentOncePerCallAndIgnoresLateAnswer() {
        let policy = TeamsRecordingPolicy()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .ask)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .none)
        XCTAssertEqual(policy.answerAsk(accepted: false, captureState: .idle), .none)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .none)
        _ = policy.observe(snapshot(false), mode: .ask, captureState: .idle)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .ask)
        _ = policy.observe(snapshot(false), mode: .ask, captureState: .idle)
        XCTAssertEqual(policy.answerAsk(accepted: true, captureState: .idle), .none)
    }

    func testManualOverridePreventsAutoRestartOrAutoStopUntilNextCall() {
        let policy = TeamsRecordingPolicy()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .manual, captureState: .idle), .none)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .start)
        policy.recordStartSucceeded()
        policy.manualOverride()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .none)
        XCTAssertEqual(policy.observe(snapshot(false), mode: .automatic, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .start)
        policy.recordStartFailed()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .none)
    }

    func testAcceptedAskStartsOnceAndOnlyStopsItsOwnRecordingAfterConfirmedEnd() {
        let detector = TeamsDetectionService(requiredEndSamples: 3)
        let policy = TeamsRecordingPolicy()
        let active = TeamsDetectionObservation.activeMeetingForTesting
        let ended = TeamsDetectionObservation(
            process: .observed(true, detail: "Teams"),
            hangupControl: .observed(false, detail: "hang-up control absent"),
            microphoneActivity: .observed(false, detail: "idle")
        )

        XCTAssertEqual(policy.observe(detector.observe(active), mode: .ask, captureState: .idle), .ask)
        XCTAssertEqual(policy.answerAsk(accepted: true, captureState: .idle), .start)
        policy.recordStartSucceeded()
        XCTAssertEqual(policy.answerAsk(accepted: true, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(active), mode: .ask, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(ended), mode: .ask, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(ended), mode: .ask, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(ended), mode: .ask, captureState: .recording), .stop)
        XCTAssertEqual(policy.observe(detector.observe(ended), mode: .ask, captureState: .idle), .none)
        XCTAssertEqual(policy.observe(detector.observe(active), mode: .ask, captureState: .idle), .ask)
    }

    func testManualCaptureWhileAskIsOpenCancelsConsentAndIsNotStoppedByDetection() {
        let policy = TeamsRecordingPolicy()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .ask)
        policy.manualOverride()
        XCTAssertEqual(policy.answerAsk(accepted: true, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(snapshot(false), mode: .ask, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .ask, captureState: .idle), .ask)
    }

    func testNextCallCanRetryAfterPreviousPreflightFailure() {
        let policy = TeamsRecordingPolicy()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .idle), .start)
        policy.recordStartFailed()
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .failed), .none)
        _ = policy.observe(snapshot(false), mode: .automatic, captureState: .failed)
        XCTAssertEqual(policy.observe(snapshot(true), mode: .automatic, captureState: .failed), .start)
    }

    func testInconclusiveOrWeakEvidenceCannotTriggerCaptureOrEndLatchedCall() {
        let detector = TeamsDetectionService()
        let policy = TeamsRecordingPolicy()
        let weak = detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams"),
            hangupControl: .unavailable(reason: "AX permission missing"),
            microphoneActivity: .observed(true, detail: "input active")
        ))
        XCTAssertEqual(policy.observe(weak, mode: .automatic, captureState: .idle), .none)
        XCTAssertEqual(policy.observe(detector.observe(.activeMeetingForTesting), mode: .automatic, captureState: .idle), .start)
        policy.recordStartSucceeded()
        XCTAssertEqual(policy.observe(detector.observe(TeamsDetectionObservation(
            process: .observed(true, detail: "Teams"),
            hangupControl: .unavailable(reason: "AX permission missing"),
            microphoneActivity: .observed(true, detail: "input active")
        )), mode: .automatic, captureState: .recording), .none)
        let absent = TeamsDetectionObservation(
            process: .observed(true, detail: "Teams"),
            hangupControl: .observed(false, detail: "no control"),
            microphoneActivity: .observed(false, detail: "idle")
        )
        XCTAssertEqual(policy.observe(detector.observe(absent), mode: .automatic, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(absent), mode: .automatic, captureState: .recording), .none)
        XCTAssertEqual(policy.observe(detector.observe(absent), mode: .automatic, captureState: .recording), .stop)
    }
}
