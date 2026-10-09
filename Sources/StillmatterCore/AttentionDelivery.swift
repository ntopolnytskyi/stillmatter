import Foundation

/// Durable navigation identity; titles are display-only and never used to route actions.
public enum AttentionTarget: Hashable, Codable {
    case weeklyReport(String)
    case titleReview(String)
    case inboxItem(String)
    case captureFailure(String)
}

public struct AttentionRequest: Equatable {
    public enum Kind: Equatable {
        case required
        case attention
        case recordingCritical
    }

    public let target: AttentionTarget
    public let title: String
    public let kind: Kind

    public init(target: AttentionTarget, title: String, kind: Kind) {
        self.target = target
        self.title = title
        self.kind = kind
    }
}

public enum AttentionDelivery: Equatable {
    case popup(AttentionTarget)
    case inline(AttentionRequest)
    case notification(AttentionRequest)
}

/// Routes attention by capture and focus state. Targets prevent repeated delivery;
/// required reviews remain pending until explicitly cleared.
public final class AttentionDeliveryCoordinator {
    private let deliver: (AttentionDelivery) -> Void
    private var pending: [AttentionTarget: AttentionRequest] = [:]
    private var order: [AttentionTarget] = []
    private var notified: Set<AttentionTarget> = []
    private var presented: Set<AttentionTarget> = []
    private var isMeetingOrRecordingActive = false
    private var isAppFocused = false

    public init(deliver: @escaping (AttentionDelivery) -> Void) {
        self.deliver = deliver
    }

    public func setEnvironment(isMeetingOrRecordingActive: Bool, isAppFocused: Bool) {
        if isMeetingOrRecordingActive && !self.isMeetingOrRecordingActive {
            presented.removeAll()
        }
        self.isMeetingOrRecordingActive = isMeetingOrRecordingActive
        self.isAppFocused = isAppFocused
        flush()
    }

    public func offer(_ request: AttentionRequest) {
        guard pending[request.target] == nil else { return }
        if request.kind != .required && (notified.contains(request.target) || presented.contains(request.target)) { return }
        pending[request.target] = request
        order.append(request.target)
        flush()
    }

    public func clear(_ target: AttentionTarget) {
        pending.removeValue(forKey: target)
        order.removeAll { $0 == target }
        notified.remove(target)
        presented.remove(target)
    }

    private func flush() {
        for target in order {
            guard let request = pending[target],
                  !isMeetingOrRecordingActive || request.kind == .recordingCritical else { continue }
            if isAppFocused {
                if presented.insert(target).inserted {
                    deliver(request.kind == .required ? .popup(target) : .inline(request))
                }
            } else if notified.insert(target).inserted {
                deliver(.notification(request))
            }
        }
    }
}
