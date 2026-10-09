import Foundation

/// An unconfigured installation asks before recording. Manual never reacts to detection.
public enum TeamsRecordingMode: String, Codable, CaseIterable {
    case ask
    case automatic
    case manual

    public var displayName: String {
        switch self {
        case .ask: return "Ask before recording"
        case .automatic: return "Record automatically"
        case .manual: return "Manual only"
        }
    }
}

public enum TeamsRecordingAction: Equatable {
    case none
    case ask
    case start
    case stop
}

/// Reconciles latched Teams evidence with capture ownership. Only recordings started by this
/// policy can be stopped by detection; manual intervention suppresses further automation until
/// the call has conclusively ended. Unknown scans never end a latched call.
public final class TeamsRecordingPolicy {
    private var callObserved = false
    private var handledCall = false
    private var ownsCapture = false
    private var pendingAsk = false

    public init() {}

    public func observe(
        _ detection: TeamsDetectionSnapshot,
        mode: TeamsRecordingMode,
        captureState: CaptureState
    ) -> TeamsRecordingAction {
        if !detection.isMeetingDetected {
            // A policy-owned recording must be stopped before relinquishing ownership.
            if ownsCapture && captureState == .recording {
                ownsCapture = false
                return .stop
            }
            callObserved = false
            handledCall = false
            ownsCapture = false
            pendingAsk = false
            return .none
        }
        callObserved = true
        guard !handledCall, !pendingAsk,
              [.idle, .failed, .recovered].contains(captureState),
              detection.confidence >= detection.candidateThreshold,
              detection.signal(.process)?.isActive == true,
              detection.signal(.hangupControl)?.isActive == true else { return .none }
        switch mode {
        case .manual: return .none
        case .ask:
            pendingAsk = true
            return .ask
        case .automatic:
            handledCall = true
            return .start
        }
    }

    /// A consent response is valid only for the still-active call and never starts capture twice.
    public func answerAsk(accepted: Bool, captureState: CaptureState) -> TeamsRecordingAction {
        guard pendingAsk else { return .none }
        pendingAsk = false
        handledCall = true
        return accepted && callObserved && [.idle, .failed, .recovered].contains(captureState) ? .start : .none
    }

    public func recordStartSucceeded() { ownsCapture = true }

    /// Both manual start and manual stop take precedence over detection for the rest of this call.
    public func manualOverride() {
        handledCall = true
        pendingAsk = false
        ownsCapture = false
    }

    public func recordStartFailed() {
        handledCall = true
        ownsCapture = false
    }
}
