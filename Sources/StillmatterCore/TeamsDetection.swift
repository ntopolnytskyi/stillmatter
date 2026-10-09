import Foundation

public enum TeamsDetectionSignalKind: String, Codable, CaseIterable, Equatable {
    case process
    case hangupControl
    case microphoneActivity

    public var displayName: String {
        switch self {
        case .process: return "Native Teams process"
        case .hangupControl: return "Teams hang-up control"
        case .microphoneActivity: return "Microphone activity"
        }
    }

    public var maximumContribution: Int {
        switch self {
        case .process: return 20
        case .hangupControl: return 60
        case .microphoneActivity: return 20
        }
    }
}

public enum TeamsDetectionSignalAvailability: String, Codable, Equatable {
    case available
    case unavailable
}

public enum TeamsDetectionSignalSample: Equatable {
    case observed(Bool, detail: String)
    case unavailable(reason: String)

    fileprivate var observedValue: Bool? {
        guard case let .observed(value, _) = self else { return nil }
        return value
    }
}

public struct TeamsDetectionObservation: Equatable {
    public let process: TeamsDetectionSignalSample
    public let hangupControl: TeamsDetectionSignalSample
    public let microphoneActivity: TeamsDetectionSignalSample

    public init(
        process: TeamsDetectionSignalSample,
        hangupControl: TeamsDetectionSignalSample,
        microphoneActivity: TeamsDetectionSignalSample
    ) {
        self.process = process
        self.hangupControl = hangupControl
        self.microphoneActivity = microphoneActivity
    }

    public static let activeMeetingForTesting = TeamsDetectionObservation(
        process: .observed(true, detail: "Teams is running"),
        hangupControl: .observed(true, detail: "Teams exposes hangup-button"),
        microphoneActivity: .observed(true, detail: "Input device is running")
    )

    fileprivate func sample(for kind: TeamsDetectionSignalKind) -> TeamsDetectionSignalSample {
        switch kind {
        case .process: return process
        case .hangupControl: return hangupControl
        case .microphoneActivity: return microphoneActivity
        }
    }
}

public struct TeamsDetectionSignal: Equatable {
    public let kind: TeamsDetectionSignalKind
    public let availability: TeamsDetectionSignalAvailability
    public let isActive: Bool
    public let contribution: Int
    public let detail: String
}

public enum TeamsDetectionCaptureDecision: String, Equatable {
    case observeOnly
}

public struct TeamsDetectionSnapshot: Equatable {
    public let signals: [TeamsDetectionSignal]
    public let confidence: Int
    public let candidateThreshold: Int
    public let positiveSampleCount: Int
    public let requiredStartSamples: Int
    public let negativeSampleCount: Int
    public let requiredEndSamples: Int
    public let isMeetingDetected: Bool
    public let captureDecision: TeamsDetectionCaptureDecision

    public var unavailableSignalCount: Int {
        signals.filter { $0.availability == .unavailable }.count
    }

    public func signal(_ kind: TeamsDetectionSignalKind) -> TeamsDetectionSignal? {
        signals.first { $0.kind == kind }
    }

    public var diagnosticSummary: String {
        let status: String
        if isMeetingDetected {
            status = negativeSampleCount > 0
                ? "Meeting detected; waiting to confirm end"
                : "Meeting detected"
        } else if positiveSampleCount > 0 {
            status = "Meeting candidate; waiting to confirm start"
        } else {
            status = "No meeting detected"
        }
        return "\(status) — confidence \(confidence)/100, start \(positiveSampleCount)/\(requiredStartSamples), end \(negativeSampleCount)/\(requiredEndSamples)."
    }
}

/// Resolves direct native Teams observations into a latched, observation-only meeting state.
/// A Teams process plus its Accessibility `hangup-button` is conclusive positive evidence.
/// Missing permissions, scan failures, and process restarts are unknown rather than evidence
/// that a previously detected meeting ended.
public final class TeamsDetectionService {
    public let requiredStartSamples: Int
    public let requiredEndSamples: Int
    public let candidateThreshold = 80
    private var positiveSampleCount = 0
    private var negativeSampleCount = 0
    private var isMeetingDetected = false

    public init(requiredStartSamples: Int = 1, requiredEndSamples: Int = 3) {
        precondition(requiredStartSamples > 0)
        precondition(requiredEndSamples > 0)
        self.requiredStartSamples = requiredStartSamples
        self.requiredEndSamples = requiredEndSamples
    }

    @discardableResult
    public func observe(_ observation: TeamsDetectionObservation) -> TeamsDetectionSnapshot {
        let signals = TeamsDetectionSignalKind.allCases.map { kind -> TeamsDetectionSignal in
            switch observation.sample(for: kind) {
            case let .observed(active, detail):
                return TeamsDetectionSignal(
                    kind: kind,
                    availability: .available,
                    isActive: active,
                    contribution: active ? kind.maximumContribution : 0,
                    detail: detail
                )
            case let .unavailable(reason):
                return TeamsDetectionSignal(
                    kind: kind,
                    availability: .unavailable,
                    isActive: false,
                    contribution: 0,
                    detail: reason
                )
            }
        }
        let confidence = signals.reduce(0) { $0 + $1.contribution }
        let processRunning = observation.process.observedValue == true
        let hangupPresent = observation.hangupControl.observedValue == true
        let hangupConclusiveAbsent = observation.hangupControl.observedValue == false

        if processRunning && hangupPresent {
            positiveSampleCount = min(requiredStartSamples, positiveSampleCount + 1)
            negativeSampleCount = 0
            if positiveSampleCount >= requiredStartSamples {
                isMeetingDetected = true
            }
        } else if processRunning && hangupConclusiveAbsent {
            positiveSampleCount = 0
            if isMeetingDetected {
                negativeSampleCount = min(requiredEndSamples, negativeSampleCount + 1)
                if negativeSampleCount >= requiredEndSamples {
                    isMeetingDetected = false
                }
            } else {
                negativeSampleCount = 0
            }
        } else {
            positiveSampleCount = 0
            negativeSampleCount = 0
        }

        return TeamsDetectionSnapshot(
            signals: signals,
            confidence: confidence,
            candidateThreshold: candidateThreshold,
            positiveSampleCount: positiveSampleCount,
            requiredStartSamples: requiredStartSamples,
            negativeSampleCount: negativeSampleCount,
            requiredEndSamples: requiredEndSamples,
            isMeetingDetected: isMeetingDetected,
            captureDecision: .observeOnly
        )
    }
}
